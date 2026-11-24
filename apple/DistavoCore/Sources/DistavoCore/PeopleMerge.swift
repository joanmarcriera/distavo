// PeopleMerge.swift — one person ended up as two people pages; make them one, and undo it (2026-11-23).
//
// "Petra N." and "Petra Novak" are the same person. Merging "Petra N." INTO "Petra Novak":
//   - "Petra N." and that page's own aliases become `aliases:` of Petra Novak's page, so every meeting of
//     either spelling is listed there at the next `PeoplePages.update` (which the caller runs);
//   - what the owner wrote on the other page (its role, organisation, LinkedIn address and free notes) is
//     copied onto the kept page as one section, "## From the page of Petra N. (merged)";
//   - the other page is set aside, byte for byte, as `_merged-Petra N.md` (every `_*.md` in the people folder
//     is Distavo's and never a person).
// Notes, transcripts and sidecars are not touched: they keep the name they have, and the alias joins them.
//
// `separate` is the undo, for when the two turn out to be different people: the aliases the merge added and
// the copied section (only while it is still exactly as copied) leave the kept page, and the set-aside page
// goes back under its own name. Nothing the owner wrote since is removed. A `role:` / `organisation:` of the kept
// page that was empty at the merge and now holds the other page's value (an update while merged filled it from
// the other person's meetings) is emptied again; a value the owner typed since, or one the page had before, stays.
//
// The copied section is derived from the other page's bytes alone, so the undo finds it without being told.
// Which page was kept, which spellings the merge ADDED (an alias the kept page already had stays after an undo)
// and the file's own name are written beside the set-aside page as `_merged-<Name>.json`; without that file the
// undo falls back to the page that holds the copied section and to the other page's own spellings.
// Pure apart from `merge`, `separate` and `setAside`.

import Foundation

public enum PeopleMerge {
    public static let setAsidePrefix = "_merged-"

    public enum Failure: Error, Equatable, LocalizedError {
        case samePerson
        case noPage(String)
        case notSetAside(String)
        case pageExists(String)
        case claimed(name: String, by: String)
        case twoFiles(name: String, file: String)
        case undoFirst(name: String, then: String)

        public var errorDescription: String? {
            switch self {
            case .samePerson: return "Those are the same page."
            case .noPage(let name): return "There is no people page for \(name). If it was just merged, it is already part of another page; otherwise use Update People Pages first."
            case .notSetAside(let name): return "No merged page of \(name) was set aside."
            case .claimed(let name, let by): return "\(name) is already another spelling on the page of \(by). Remove it from that page's aliases first."
            case .twoFiles(let name, let file): return "Two files in the people folder say they are \(name): \(file) is the second. Delete or rename one of them first."
            case .undoFirst(let name, let then): return "\(then) was merged into \(name), and \(name) was merged into another page afterwards. Undo the merge of \(name) first."
            case .pageExists(let name): return "A page for \(name) exists again. Rename or delete it, then undo the merge."
            }
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// The page that stays (for `separate`: the page the other was merged into, "" when none lists it now).
        public var kept: String
        public var other: String
        /// Spellings added to (merge) or taken from (separate) the kept page's `aliases:`.
        public var aliases: [String]
        /// Whether the other page had something of the owner's that was copied (merge) or taken out again (separate).
        public var notes: Bool
        /// After an undo: the kept page still has a "From the page of …" section of this person, because it was
        /// edited since the merge (or copied by an earlier build in another form). It is the owner's to remove.
        public var textLeft = false
    }

    public struct SetAside: Equatable, Sendable {
        public var name: String
        /// The page it was merged into, when that page is still there; nil when none can be told.
        public var into: String?
        public var file: URL
    }

    /// What a merge did that the pages alone cannot tell (`_merged-<Name>.json`).
    struct Record: Codable, Equatable {
        var version = 1
        var name: String
        var into: String
        /// The spellings the merge added to the kept page.
        var aliases: [String]
        /// The other page's file name before it was set aside.
        var file: String
        /// The kept page had no `aliases:` line before the merge (the undo takes the line away again).
        var addedLine: Bool?
        /// The kept page's `role:` / `organisation:` lines that were empty at the merge, as written (field -> line).
        /// An update while merged fills them from the other person's meetings; the undo empties them again. Nil in
        /// a record written before this key existed: the undo then leaves the fields as they are.
        var emptyFields: [String: String]?
        /// What an update put into those fields while the pages were merged (field -> value), noted by
        /// `noteFilled`: the undo empties a field that still holds exactly that.
        var filled: [String: String]?
        /// The kept page's meetings block at the merge. The undo puts it back: an update then rewrites it when
        /// the person still has meetings, and a page whose person has none left (its block is their history)
        /// does not keep the other person's meetings.
        var block: [String]?

        static func url(for setAside: URL) -> URL { setAside.deletingPathExtension().appendingPathExtension("json") }
        static func load(for setAside: URL) -> Record? {
            (try? Data(contentsOf: url(for: setAside))).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        }
    }

    // MARK: Page text (pure)

    private static func isStart(_ l: String) -> Bool { l.hasPrefix("<!-- distavo:meetings:start") }
    private static func isEnd(_ l: String) -> Bool { l.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")) == PeoplePages.blockEnd }

    /// The lines of the complete meetings block (a start marker, then an end marker, no start in between; the
    /// last such pair, as `PeoplePages.refreshed` picks it).
    private static func block(in lines: [String]) -> ClosedRange<Int>? {
        for s in lines.indices.reversed() where isStart(lines[s]) {
            let after = lines.index(after: s)
            guard let e = lines[after...].firstIndex(where: isEnd) else { continue }
            if !lines[after..<e].contains(where: isStart) { return s...e }
        }
        return nil
    }

    /// The section copied onto the kept page: what the owner's page of `name` says that Distavo did not write.
    /// Empty when the page has nothing of the owner's. No line endings; the last line is blank.
    static func carried(from page: String, name: String) -> [String] {
        // Line by line without any carriage return (Windows endings, or a stray one inside a line): the section
        // takes the line endings of the page it is copied onto.
        var lines = page.components(separatedBy: "\n").map { PeoplePages.bare($0).replacingOccurrences(of: "\r", with: "") }
        let fields = PeoplePages.frontmatter(of: page)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        if let b = block(in: lines) { lines.removeSubrange(b) }
        lines.removeAll { isStart($0) || isEnd($0) }
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].hasPrefix("# "),
           lines[first].dropFirst(2).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
            lines.remove(at: first)
        }
        while let l = lines.first, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        var facts = [("Role", "role"), ("Organisation", "organisation"), ("LinkedIn", "linkedin")].compactMap { label, key -> String? in
            let value = flat(fields[key] ?? "")
            return value.isEmpty ? nil : "\(label): \(value)"
        }
        // Whatever else the owner keeps in the frontmatter (email, phone, tags…), as written.
        let own: Set<String> = ["type", "name", "aliases", "role", "organisation", "linkedin"]
        let blocks = blockScalars(inFrontmatterOf: page)
        facts += fields.keys.filter { !own.contains($0) && !$0.hasPrefix("_") && !$0.isEmpty }.sorted().compactMap { key in
            let value = blocks[key] ?? flat(fields[key] ?? "")
            return value.isEmpty ? nil : "\(flat(key)): \(value)"
        }
        guard !facts.isEmpty || !lines.isEmpty else { return [] }
        var out = ["## From the page of \(PeoplePages.oneLine(name)) (merged)"]
        if !facts.isEmpty { out.append(facts.joined(separator: " · ")) }
        if !lines.isEmpty { out += [""] + lines }
        return out + [""]
    }

    /// One line as the owner wrote it: nothing cut, nothing replaced (a LinkedIn address is longer than 80 characters).
    private static func flat(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// `notes: |` followed by indented lines: the text of those lines, which `PeoplePages.frontmatter` does not read.
    static func blockScalars(inFrontmatterOf page: String) -> [String: String] {
        let lines = page.components(separatedBy: "\n").map { PeoplePages.bare($0).replacingOccurrences(of: "\r", with: "") }
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var out: [String: String] = [:], n = 1
        while n < end {
            let line = lines[n]
            n += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard PeoplePages.isBlockIndicator(value) else { continue }
            var text: [String] = []
            while n < end, lines[n].hasPrefix(" ") || lines[n].hasPrefix("\t") || lines[n].trimmingCharacters(in: .whitespaces).isEmpty {
                let t = lines[n].trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { text.append(t) }
                n += 1
            }
            if !text.isEmpty { out[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] = text.joined(separator: " ") }
        }
        return out
    }

    /// `page` with its frontmatter `aliases:` set to exactly `aliases`. A "- item" list stays a list: the lines
    /// of the spellings that go are removed, new ones are added after the last item, and comments or blank lines
    /// between the items are left where they are. A single-line value is replaced (a comment after it stays); a
    /// page without the line gets one. A page without frontmatter is returned as is.
    static func withAliases(_ page: String, _ aliases: [String], dropEmptyLine: Bool = false) -> String {
        var lines = page.components(separatedBy: "\n")
        let cr = page.contains("\r\n") ? "\r" : ""
        guard PeoplePages.bare(lines[0]) == "---",
              let end = lines.dropFirst().firstIndex(where: { PeoplePages.bare($0) == "---" }) else { return page }
        let line = "aliases: [\(aliases.map(PeoplePages.quote).joined(separator: ", "))]" + cr
        // The last `aliases:` line is the one a page with two of them is read by.
        guard let i = lines[1..<end].lastIndex(where: { $0.hasPrefix("aliases:") }) else {
            if !aliases.isEmpty { lines.insert(line, at: end) }
            return lines.joined(separator: "\n")
        }
        let inline = PeoplePages.bare(lines[i]).dropFirst("aliases:".count).trimmingCharacters(in: .whitespaces)
        if inline.isEmpty || inline.hasPrefix("#") {
            var items: [Int] = [], n = i + 1
            while n < end {
                let t = PeoplePages.bare(lines[n]).trimmingCharacters(in: .whitespaces)
                if PeoplePages.listItem(t) != nil { items.append(n) } else if !t.isEmpty && !t.hasPrefix("#") { break }
                n += 1
            }
            if let lastItem = items.last {
                var have: [String] = [], gone: [Int] = []
                for k in items {
                    let v = PeoplePages.listItem(PeoplePages.bare(lines[k]).trimmingCharacters(in: .whitespaces)) ?? ""
                    if v.isEmpty { continue }
                    if aliases.contains(where: { same($0, v) }) { have.append(v) } else { gone.append(k) }
                }
                let indent = String(lines[lastItem].prefix { $0 == " " || $0 == "\t" })
                let new = aliases.filter { a in !have.contains { same($0, a) } }.map { indent + "- " + PeoplePages.quote($0) + cr }
                lines.insert(contentsOf: new, at: lastItem + 1)
                for k in gone.reversed() { lines.remove(at: k) }
                return lines.joined(separator: "\n")
            }
        }
        if aliases.isEmpty && dropEmptyLine { lines.remove(at: i); return lines.joined(separator: "\n") }
        // "aliases: [a, b]  # as she signs": the comment is the owner's.
        var comment = ""
        let text = PeoplePages.bare(lines[i])
        if let open = text.firstIndex(of: "["), let close = PeoplePages.flowClose(String(text[open...])) {
            let after = String(text[open...])[close...].dropFirst().trimmingCharacters(in: .whitespaces)
            if after.hasPrefix("#") { comment = " " + after }
        }
        else if inline.hasPrefix("#") { comment = " " + inline }
        lines[i] = "aliases: [\(aliases.map(PeoplePages.quote).joined(separator: ", "))]" + comment + cr
        return lines.joined(separator: "\n")
    }

    /// Two spellings of one name, as `PeoplePages` tells people apart everywhere ("Strauß" and "Strauss" are two
    /// people there; `caseInsensitiveCompare` would call them one).
    static func same(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }

    /// Where `section` sits in `lines` as it was copied (compared without line endings); nil when it is not
    /// there any more, or was edited.
    private static func position(of section: [String], in lines: [String]) -> Range<Int>? {
        guard !section.isEmpty, lines.count >= section.count else { return nil }
        let bare = lines.map(PeoplePages.bare)
        for start in 0...(bare.count - section.count) where Array(bare[start..<(start + section.count)]) == section {
            return start..<(start + section.count)
        }
        return nil
    }

    /// The kept page after the merge: the other person's spellings as aliases and their page's own text as a
    /// section above the meetings block. Merging twice changes nothing more.
    static func mergedPage(keep: String, keepName: String, keepAliases: [String],
                           other: String, otherName: String, otherAliases: [String]) -> (text: String, added: [String], notes: Bool) {
        var aliases = keepAliases, added: [String] = []
        for s in [otherName] + otherAliases
        where !same(s, keepName) && !aliases.contains(where: { same($0, s) }) && !s.trimmingCharacters(in: .whitespaces).isEmpty {
            aliases.append(s); added.append(s)
        }
        var lines = (added.isEmpty ? keep : withAliases(keep, aliases)).components(separatedBy: "\n")
        let cr = keep.contains("\r\n") ? "\r" : ""
        let section = carried(from: other, name: otherName)
        guard !section.isEmpty, position(of: section, in: lines) == nil else {
            return (lines.joined(separator: "\n"), added, !section.isEmpty)
        }
        let withEndings = section.map { $0 + cr }
        if let b = block(in: lines) {
            let blankBefore = b.lowerBound == 0 || PeoplePages.bare(lines[b.lowerBound - 1]).trimmingCharacters(in: .whitespaces).isEmpty
            lines.insert(contentsOf: (blankBefore ? [] : [cr]) + withEndings, at: b.lowerBound)
        } else {
            while let l = lines.last, PeoplePages.bare(l).isEmpty { lines.removeLast() }
            lines += [cr] + withEndings
        }
        return (lines.joined(separator: "\n"), added, true)
    }

    /// The kept page after the undo: without the spellings in `theirs` (what the merge added) and without the
    /// copied section (while it is still as copied).
    static func separatedPage(keep: String, keepAliases: [String],
                              other: String, otherName: String, removing theirs: [String],
                              lineWasAdded: Bool = false) -> (text: String, removed: [String], notes: Bool) {
        let removed = keepAliases.filter { a in theirs.contains { same($0, a) } }
        let left = keepAliases.filter { a in !theirs.contains { same($0, a) } }
        var lines = (removed.isEmpty ? keep : withAliases(keep, left, dropEmptyLine: lineWasAdded)).components(separatedBy: "\n")
        var notes = false
        if let r = position(of: carried(from: other, name: otherName), in: lines) {
            lines.removeSubrange(r)
            notes = true
        }
        return (lines.joined(separator: "\n"), removed, notes)
    }

    /// The fields `PeoplePages.refreshed` fills while the owner leaves them empty.
    static let filledFields = ["role", "organisation"]

    /// The frontmatter line of `key` that `PeoplePages.refreshed` rewrites (the first one), by index.
    private static func fieldLine(_ key: String, in lines: [String]) -> Int? {
        guard let first = lines.first, PeoplePages.bare(first) == "---",
              let end = lines.dropFirst().firstIndex(where: { PeoplePages.bare($0) == "---" }) else { return nil }
        return lines[1..<end].firstIndex { $0.hasPrefix("\(key):") }
    }

    /// The `role:` / `organisation:` lines of `page` that are empty, as written (without a carriage return).
    static func emptyFields(of page: String) -> [String: String] {
        let lines = page.components(separatedBy: "\n"), fields = PeoplePages.frontmatter(of: page)
        var out: [String: String] = [:]
        for key in filledFields where (fields[key] ?? "").isEmpty {
            if let i = fieldLine(key, in: lines) { out[key] = PeoplePages.bare(lines[i]) }
        }
        return out
    }

    /// The kept page after the undo with each field that was empty at the merge (`empty`) written as it was,
    /// when its value now is exactly what an update put there while merged (`filled`, from the record). A value
    /// the owner typed since stays, also when it is what the other person's page says (two colleagues).
    static func restoringEmptyFields(_ page: String, _ empty: [String: String], other: String, filled: [String: String] = [:]) -> String {
        var lines = page.components(separatedBy: "\n")
        let cr = page.contains("\r\n") ? "\r" : ""
        let now = PeoplePages.frontmatter(of: page)
        for key in filledFields {
            guard let original = empty[key], let value = now[key], !value.isEmpty,
                  value == filled[key], let i = fieldLine(key, in: lines) else { continue }
            lines[i] = original + cr
        }
        return lines.joined(separator: "\n")
    }

    /// An update filled `role:` / `organisation:` of the page of `name` (`old` -> `new`): every merge into that
    /// page whose record says the field was empty remembers the value, so its undo can take it back.
    static func noteFilled(page name: String, old: String, new: String, notesDir: URL) {
        let before = PeoplePages.frontmatter(of: old), after = PeoplePages.frontmatter(of: new)
        let fills = filledFields.filter { (before[$0] ?? "").isEmpty && !(after[$0] ?? "").isEmpty }
        guard !fills.isEmpty else { return }
        let dir = PeoplePages.folder(notesDir: notesDir)
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension.lowercased() == "md" && file.lastPathComponent.hasPrefix(setAsidePrefix) {
            guard var record = Record.load(for: file), same(record.into, name) else { continue }
            var changed = false
            for key in fills where record.emptyFields?[key] != nil { record.filled = (record.filled ?? [:]).merging([key: after[key]!]) { $1 }; changed = true }
            if changed, let data = try? JSONEncoder().encode(record) { try? data.write(to: Record.url(for: file), options: .atomic) }
        }
    }

    /// The lines of the page's meetings block (without carriage returns); nil when it has no complete block.
    static func blockLines(of page: String) -> [String]? {
        let lines = page.components(separatedBy: "\n")
        return block(in: lines).map { lines[$0].map(PeoplePages.bare) }
    }

    /// `page` with its meetings block replaced by `old` (a page without a complete block is left alone).
    static func withBlock(_ page: String, _ old: [String]) -> String {
        var lines = page.components(separatedBy: "\n")
        guard let range = block(in: lines) else { return page }
        let cr = page.contains("\r\n") ? "\r" : ""
        lines.replaceSubrange(range, with: old.map { $0 + cr })
        return lines.joined(separator: "\n")
    }

    // MARK: Files

    /// Makes `other` another spelling of `keep` (see the header). The caller then runs `PeoplePages.update`.
    @discardableResult
    public static func merge(_ other: String, into keep: String, notesDir: URL) throws -> Outcome {
        let pages = PeoplePages.knownFiles(notesDir: notesDir)
        guard let a = pages.first(where: { same($0.known.name, keep) }) else { throw Failure.noPage(keep) }
        guard let b = pages.first(where: { same($0.known.name, other) }) else { throw Failure.noPage(other) }
        guard a.url != b.url, !same(a.known.name, b.known.name) else { throw Failure.samePerson }
        // A third page that already calls itself by the other name would take that person's meetings.
        if let third = pages.first(where: { p in p.url != a.url && p.url != b.url && p.known.aliases.contains { same($0, b.known.name) } }) {
            throw Failure.claimed(name: b.known.name, by: third.known.name)
        }
        // A second file that says it is the other person (a Finder copy) would become that person's page as soon
        // as the first is set aside, and take the meetings back.
        if let twin = files(named: b.known.name, notesDir: notesDir).first(where: { $0 != b.url }) {
            throw Failure.twoFiles(name: b.known.name, file: twin.lastPathComponent)
        }
        let merged = mergedPage(keep: a.text, keepName: a.known.name, keepAliases: a.known.aliases,
                                other: b.text, otherName: b.known.name, otherAliases: b.known.aliases)
        let dir = b.url.deletingLastPathComponent(), fm = FileManager.default
        let stem = b.url.deletingPathExtension().lastPathComponent
        var target = dir.appendingPathComponent(setAsidePrefix + stem + ".md"), n = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(setAsidePrefix)\(stem) \(n).md"); n += 1
        }
        // The record, then the move, then the kept page; a kept page that cannot be written puts the other page
        // back, so a merge that fails changes nothing. (Killed between the last two steps, the other page is
        // set aside and the kept page untouched: "Undo a Merge" brings it back.)
        let hadLine = PeoplePages.frontmatter(of: a.text)["aliases"] != nil
        // A page that already holds someone else's meetings (an earlier merge into it) has no block of its own
        // to give back: undone in any order, that would put the first person's meetings back on it.
        let alreadyMergedInto = setAside(notesDir: notesDir).contains { same($0.into ?? "", a.known.name) }
        let record = Record(name: b.known.name, into: a.known.name, aliases: merged.added, file: b.url.lastPathComponent,
                            addedLine: !hadLine && !merged.added.isEmpty, emptyFields: emptyFields(of: a.text), block: alreadyMergedInto ? nil : blockLines(of: a.text))
        // A record already there belongs to no page (the target name is free). It is kept only when it is this very
        // merge, stopped half way and run again: it knows which spellings the first run added.
        let earlier = Record.load(for: target).flatMap { same($0.name, record.name) && same($0.into, record.into) ? $0 : nil }
        if earlier == nil || !merged.added.isEmpty {
            try? JSONEncoder().encode(record).write(to: Record.url(for: target), options: .atomic)
        }
        do { try fm.moveItem(at: b.url, to: target) } catch {
            try? fm.removeItem(at: Record.url(for: target))
            throw error
        }
        do { if merged.text != a.text { try merged.text.write(to: a.url, atomically: true, encoding: .utf8) } } catch {
            try? fm.moveItem(at: target, to: b.url)
            try? fm.removeItem(at: Record.url(for: target))
            throw error
        }
        return Outcome(kept: a.known.name, other: b.known.name, aliases: merged.added, notes: merged.notes)
    }

    /// Every person file whose own name is `name`, copies included (`PeoplePages.knownFiles` lists one per name).
    private static func files(named name: String, notesDir: URL) -> [URL] {
        let dir = PeoplePages.folder(notesDir: notesDir)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" && !$0.lastPathComponent.hasPrefix("_") && !NoteVersions.isBackupName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { file in
                guard let text = try? String(contentsOf: file, encoding: .utf8), let k = PeoplePages.knownPage(text, file: file) else { return false }
                return same(k.name, name)
            }
    }

    /// What a set-aside page says, under the name it was merged as (a page without `name:` set aside as
    /// `_merged-X 2.md` is still X).
    private static func known(setAside file: URL, text: String) -> PeoplePages.Known? {
        guard var k = PeoplePages.knownPage(text, file: original(of: file)) else { return nil }
        if (PeoplePages.frontmatter(of: text)["name"] ?? "").isEmpty, let record = Record.load(for: file) { k.name = record.name }
        return k
    }

    /// The pages a merge set aside, by file name.
    public static func setAside(notesDir: URL) -> [SetAside] {
        let dir = PeoplePages.folder(notesDir: notesDir)
        let pages = PeoplePages.knownFiles(notesDir: notesDir)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent.hasPrefix(setAsidePrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8), let k = known(setAside: file, text: text) else { return nil }
            return SetAside(name: k.name, into: Record.load(for: file)?.into ?? keptPage(for: file, text: text, name: k.name, in: pages)?.known.name,
                            file: file)
        }
    }

    /// The page a set-aside page was merged into, when it is a page now: the one its record names; without a
    /// record the page that holds the copied section, else the only page that lists the name as an alias.
    private static func keptPage(for file: URL, text: String, name: String,
                                 in pages: [(known: PeoplePages.Known, url: URL, text: String)]) -> (known: PeoplePages.Known, url: URL, text: String)? {
        if let record = Record.load(for: file) { return pages.first { same($0.known.name, record.into) } }
        let section = carried(from: text, name: name)
        if let holder = pages.first(where: { position(of: section, in: $0.text.components(separatedBy: "\n")) != nil }) { return holder }
        let listing = pages.filter { p in p.known.aliases.contains { same($0, name) } }
        return listing.count == 1 ? listing[0] : nil
    }

    /// The file a set-aside page had before the merge, going by its own name.
    private static func original(of setAside: URL) -> URL {
        setAside.deletingLastPathComponent()
            .appendingPathComponent(String(setAside.lastPathComponent.dropFirst(setAsidePrefix.count)))
    }

    /// Undoes the merge of `name` (the first set-aside page of that name). The caller then runs `PeoplePages.update`.
    @discardableResult
    public static func separate(_ name: String, notesDir: URL) throws -> Outcome {
        guard let aside = setAside(notesDir: notesDir).first(where: { same($0.name, name) }) else { throw Failure.notSetAside(name) }
        return try separate(aside, notesDir: notesDir)
    }

    /// Undoes one merge: the set-aside page comes back under its own name and the page it was merged into lets
    /// go of the spellings the merge added and of the copied section.
    @discardableResult
    public static func separate(_ aside: SetAside, notesDir: URL) throws -> Outcome {
        guard aside.file.lastPathComponent.hasPrefix(setAsidePrefix),
              let otherText = try? String(contentsOf: aside.file, encoding: .utf8),
              let other = known(setAside: aside.file, text: otherText) else { throw Failure.notSetAside(aside.name) }
        let pages = PeoplePages.knownFiles(notesDir: notesDir), fm = FileManager.default
        guard !pages.contains(where: { same($0.known.name, other.name) }) else { throw Failure.pageExists(other.name) }
        let record = Record.load(for: aside.file)
        let named = record.map { aside.file.deletingLastPathComponent().appendingPathComponent(($0.file as NSString).lastPathComponent) }
        let target = named.flatMap { $0.pathExtension.lowercased() == "md" && !$0.lastPathComponent.hasPrefix("_") ? $0 : nil } ?? original(of: aside.file)
        guard !fm.fileExists(atPath: target.path) else { throw Failure.pageExists(other.name) }
        var kept = keptPage(for: aside.file, text: otherText, name: other.name, in: pages)
        // The page it went into was itself merged since: its set-aside copy still carries this person's
        // spellings and text, so that merge is undone first (last merged, first undone).
        if kept == nil, let into = record?.into, setAside(notesDir: notesDir).contains(where: { same($0.name, into) }) {
            throw Failure.undoFirst(name: into, then: other.name)
        }
        // The owner renamed the kept page since: it is the one page that lists the name.
        if kept == nil, record != nil {
            let listing = pages.filter { p in p.known.aliases.contains { same($0, other.name) } }
            if listing.count == 1 { kept = listing[0] }
        }
        // Another page that lists the name would take the meetings of the page that comes back.
        if let claimer = pages.first(where: { p in p.url != kept?.url && p.known.aliases.contains { same($0, other.name) } }) {
            throw Failure.claimed(name: other.name, by: claimer.known.name)
        }
        var out = Outcome(kept: kept?.known.name ?? "", other: other.name, aliases: [], notes: false)
        // The page comes back first; a kept page that cannot be written sets it aside again, so an undo that
        // fails changes nothing.
        try fm.moveItem(at: aside.file, to: target)
        if let a = kept {
            let s = separatedPage(keep: a.text, keepAliases: a.known.aliases, other: otherText, otherName: other.name,
                                  removing: record?.aliases ?? [other.name] + other.aliases, lineWasAdded: record?.addedLine ?? false)
            var text = restoringEmptyFields(s.text, record?.emptyFields ?? [:], other: otherText, filled: record?.filled ?? [:])
            if let old = record?.block { text = withBlock(text, old) }
            do { if text != a.text { try text.write(to: a.url, atomically: true, encoding: .utf8) } } catch {
                try? fm.moveItem(at: target, to: aside.file)
                throw error
            }
            out.aliases = s.removed; out.notes = s.notes
            out.textLeft = s.text.contains("## From the page of \(flat(other.name)) (merged)")
        }
        try? fm.removeItem(at: Record.url(for: aside.file))
        return out
    }

    /// The meetings in which both people spoke under names the owner gave: a sign they are two people, shown
    /// before a merge. Titles, newest first.
    public static func bothSpoke(_ a: String, _ b: String, people: [PeoplePages.Person]) -> [String] {
        guard let pa = people.first(where: { same($0.name, a) }), let pb = people.first(where: { same($0.name, b) }) else { return [] }
        let theirs = Set(pb.meetings.filter { $0.spoke && !$0.byVoice }.map(\.base))
        return pa.meetings.filter { $0.spoke && !$0.byVoice && theirs.contains($0.base) }.map(\.title)
    }
}
