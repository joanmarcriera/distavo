// SettingsDraft.swift — keeps the Settings window's draft in step with changes made outside it.
//
// The Settings window edits a COPY of the config (the draft) and writes the whole copy back on Save and on
// close. The menu changes the live config too ("Pause watching", the interval, "Use local Ollama"). Without
// this, a draft taken before such a change still holds the old value and puts it back the next time the
// window is saved or closed: a pause chosen in the menu was silently undone (found 2026-11-27, after
// `watch_enabled` became a saved setting).
//
// Rule: every setting that changed in the live config since the draft last saw it takes the live value in
// the draft; every other setting keeps what the owner has typed in the window. Pure, no UI.

import Foundation

public enum SettingsDraft {
    /// `draft` after the live config went from `was` to `now` outside the Settings window.
    /// Compared key by key on the saved (JSON) form, so a key added to `Config` later is covered without a
    /// change here; a list is one value. Returns `draft` unchanged when nothing changed or on any coding error.
    public static func following(draft: Config, was: Config, now: Config) -> Config {
        guard was != now, draft != now else { return draft }
        let encoder = JSONEncoder()
        func tree(_ c: Config) -> [String: Any]? {
            (try? encoder.encode(c)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        }
        guard let d = tree(draft), let w = tree(was), let n = tree(now) else { return draft }
        let merged = merge(draft: d, was: w, now: n)
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let out = try? JSONDecoder().decode(Config.self, from: data) else { return draft }
        return out
    }

    private static func merge(draft: [String: Any], was: [String: Any], now: [String: Any]) -> [String: Any] {
        var out = draft
        for key in Set(was.keys).union(now.keys) {
            let w = was[key], n = now[key]
            if let wd = w as? [String: Any], let nd = n as? [String: Any] {
                out[key] = merge(draft: draft[key] as? [String: Any] ?? [:], was: wd, now: nd)
            } else if !same(w, n) {
                out[key] = n   // nil removes the key: the decoder then gives its default
            }
        }
        return out
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x as NSObject, y as NSObject): return x.isEqual(y)
        default: return false
        }
    }
}
