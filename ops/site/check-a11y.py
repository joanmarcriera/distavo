#!/usr/bin/env python3
"""ops/site/check-a11y.py - WCAG 2.2 AA basics for the Distavo static site (read-only, stdlib only).

Usage:   python3 -I ops/site/check-a11y.py [SITE_ROOT]      (default: the directory of this file)
Exit:    0 and last line "A11Y OK (N pages)" when clean; 1 and "A11Y FAIL (K failures)" otherwise.
Checks per page: <html lang>; exactly one h1; no skipped heading level; img alt (empty only with
role=presentation|none); every form control labelled; every link/button has an accessible name; a
skip-to-content link that targets an existing id; (site.css) :focus-visible style, reduced-motion
respected when the CSS animates/smooth-scrolls, and a contrast table (>= 4.5, or >= 3.0 for large
text) for the colour pairs the CSS actually uses, parsed from the custom properties in :root and,
if present, the dark-mode override blocks. SITE_ROOT exists so the tests can point at a fixture.
"""
import os
import re
import sys
from html.parser import HTMLParser

ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
failures = []


def fail(page, msg):
    failures.append(f"{page}: {msg}")


# ----------------------------------------------------------------------------- HTML
VOID = {"img", "input", "br", "hr", "meta", "link", "source", "area", "base", "col", "embed", "wbr"}


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.lang = None
        self.h = []                 # heading levels in order
        self.ids = set()
        self.main_id = None
        self.links = []             # every href in document order (a with href)
        self.imgs = []              # (attrs)
        self.controls = []          # (attrs, inside_label)
        self.labels_for = set()
        self.anchors = []           # [attrs, text, has_named_child]
        self.buttons = []
        self.hrefs = []
        self.stack = []             # open elements of interest: ['a'|'button'|'label', record]
        self.skip_hidden = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "html":
            self.lang = a.get("lang")
        if a.get("id"):
            self.ids.add(a["id"])
        if tag == "main":
            self.main_id = a.get("id")
        if len(tag) == 2 and tag[0] == "h" and tag[1] in "123456":
            self.h.append(int(tag[1]))
        if tag == "label" and a.get("for"):
            self.labels_for.add(a["for"])
        if tag == "img":
            self.imgs.append(a)
            self._named_child(a.get("alt") or a.get("aria-label"))
        if tag in ("input", "select", "textarea"):
            if a.get("type", "text") not in ("hidden", "submit", "button", "image", "reset"):
                self.controls.append((a, any(s[0] == "label" for s in self.stack)))
            elif a.get("type") in ("submit", "button", "reset") and not (a.get("value") or a.get("aria-label")):
                self.buttons.append({"attrs": a, "text": "", "named": False})
        if tag in ("a", "button", "label") and tag not in VOID:
            rec = {"attrs": a, "text": "", "named": bool(a.get("aria-label") or a.get("aria-labelledby") or a.get("title"))}
            if tag == "a" and "href" in a:
                self.anchors.append(rec)
                self.hrefs.append(a["href"])
            elif tag == "button":
                self.buttons.append(rec)
            self.stack.append((tag, rec))
        if tag == "svg" and a.get("aria-label"):
            self._named_child(True)

    def _named_child(self, ok):
        if ok:
            for tag, rec in self.stack:
                rec["named"] = True

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        if data.strip():
            for _tag, rec in self.stack:
                rec["text"] += data


def check_page(rel):
    path = os.path.join(ROOT, rel)
    p = Page()
    p.feed(open(path, encoding="utf-8").read())
    if not p.lang:
        fail(rel, "<html> has no lang")
    if p.h.count(1) != 1:
        fail(rel, f"expected exactly one h1, found {p.h.count(1)}")
    prev = 0
    for lvl in p.h:
        if prev and lvl > prev + 1:
            fail(rel, f"heading level skipped: h{prev} -> h{lvl}")
        prev = lvl
    for a in p.imgs:
        if "alt" not in a:
            fail(rel, f"img without alt: {a.get('src')}")
        elif a["alt"].strip() == "" and a.get("role") not in ("presentation", "none"):
            fail(rel, f"img with empty alt and no role=presentation: {a.get('src')}")
    for a, in_label in p.controls:
        labelled = in_label or a.get("aria-label") or a.get("aria-labelledby") or (a.get("id") in p.labels_for)
        if not labelled:
            fail(rel, f"form control without a label: {a.get('name') or a.get('id')}")
    for rec in p.anchors:
        if not (rec["text"].strip() or rec["named"]):
            fail(rel, f"link without accessible name: {rec['attrs'].get('href')}")
    for rec in p.buttons:
        a = rec["attrs"]
        if not (rec["text"].strip() or rec["named"] or a.get("value")):
            fail(rel, "button without accessible name")
    skips = [h for h in p.hrefs if h.startswith("#") and len(h) > 1]
    # The very first link must be the skip link and it must land on <main>.
    if not p.hrefs or not p.hrefs[0].startswith("#"):
        fail(rel, "first link is not a skip-to-content link")
    elif not p.main_id or p.hrefs[0] != "#" + p.main_id:
        fail(rel, f"skip link {p.hrefs[0] if p.hrefs else ''} does not target the <main id>")
    for h in skips:
        if h[1:] not in p.ids:
            fail(rel, f"in-page link {h} has no target id")


# ----------------------------------------------------------------------------- CSS contrast
def parse_color(s, base=None):
    s = s.strip().lower()
    m = re.fullmatch(r"#([0-9a-f]{3}|[0-9a-f]{6})", s)
    if m:
        h = m.group(1)
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
    m = re.fullmatch(r"rgba?\(([^)]*)\)", s)
    if m:
        parts = [x.strip() for x in m.group(1).split(",")]
        rgb = tuple(float(x) for x in parts[:3])
        alpha = float(parts[3]) if len(parts) > 3 else 1.0
        if alpha < 1.0:
            if base is None:
                raise ValueError("translucent colour needs a base: " + s)
            return tuple(alpha * f + (1 - alpha) * b for f, b in zip(rgb, base))
        return rgb
    raise ValueError("unparsed colour: " + s)


def lum(c):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(x) for x in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


# (label, foreground, background, minimum, source rule). "var(--x)" resolves from the scheme; a
# literal is checked as written. Translucent foregrounds are composited over their background.
PAIRS = [
    ("body text", "var(--ink)", "var(--bg)", 4.5),
    ("body text on cards", "var(--ink)", "var(--surface)", 4.5),
    ("muted text", "var(--muted)", "var(--bg)", 4.5),
    ("muted text on cards", "var(--muted)", "var(--surface)", 4.5),
    ("link/accent text", "var(--blue)", "var(--bg)", 4.5),
    ("link/accent text on cards", "var(--blue)", "var(--surface)", 4.5),
    ("primary button", "#ffffff", "var(--blue)", 4.5),
    ("blue tag", "#ffffff", "var(--blue)", 4.5),
    ("green tag", "#ffffff", "var(--green)", 4.5),
    ("rust tag", "#ffffff", "var(--rust)", 4.5),
    ("hero text", "#ffffff", "var(--navy)", 4.5),
    ("hero lede", "rgba(255, 255, 255, 0.84)", "var(--navy)", 4.5),
    ("hero eyebrow", "rgba(255, 255, 255, 0.82)", "var(--navy)", 4.5),
    ("hero meta", "rgba(255, 255, 255, 0.74)", "var(--navy)", 4.5),
    ("setapp note", "rgba(255, 255, 255, 0.6)", "var(--navy)", 4.5),
    ("appstore badge eyebrow", "rgba(255, 255, 255, 0.86)", "#000000", 4.5),
    ("tool platform pill", "#2447a5", "#e9f1ff", 4.5),
    ("notice strong", "#51371f", "#fff8ec", 4.5),
    ("notice span", "#65482b", "#fff8ec", 4.5),
    ("inline code", "var(--ink)", "#e9eef5", 4.5),
    ("status band text", "rgba(255, 255, 255, 0.78)", "#14231f", 4.5),
    ("status band heading", "#ffffff", "#14231f", 4.5),
    ("muted text on code/pill", "var(--muted)", "#e9eef5", 4.5),
]


# Pages that carry their own <style> (feedback) are checked with the variables they define.
INLINE_PAIRS = [
    ("text", "var(--ink)", "var(--bg)", 4.5),
    ("text on panel", "var(--ink)", "var(--panel)", 4.5),
    ("muted on panel", "var(--muted)", "var(--panel)", 4.5),
    ("muted on page", "var(--muted)", "var(--bg)", 4.5),
    ("button label", "var(--accent-ink)", "var(--accent)", 4.5),
    ("accent text on panel", "var(--accent)", "var(--panel)", 4.5),
    ("success message", "var(--ok)", "var(--bg)", 4.5),
    ("error message", "var(--err)", "var(--bg)", 4.5),
]


def css_vars(block):
    return dict(re.findall(r"(--[\w-]+)\s*:\s*([^;]+);", block))


def check_css(rel=None, css=None, pairs=None):
    pairs = pairs or PAIRS
    if css is None:
        rel = "assets/site.css"
        css = open(os.path.join(ROOT, rel), encoding="utf-8").read()
    if not re.search(r":focus-visible", css):
        fail(rel, "no :focus-visible style")
    animates = re.search(r"\b(animation|transition)\s*:|scroll-behavior\s*:\s*smooth", css)
    if animates and not re.search(r"@media\s*\(\s*prefers-reduced-motion\s*:\s*reduce\s*\)", css):
        fail(rel, "animation/smooth scrolling without a prefers-reduced-motion: reduce block")
    schemes = {}
    root_m = re.search(r":root\s*\{([^}]*)\}", css)
    if not root_m:
        fail(rel, "no :root custom properties to check contrast against")
        return []
    default = css_vars(root_m.group(1))
    schemes["default"] = default
    for m in re.finditer(r"@media\s*\(\s*prefers-color-scheme\s*:\s*(dark|light)\s*\)\s*\{\s*:root[^{]*\{([^}]*)\}", css):
        schemes[m.group(1)] = {**default, **css_vars(m.group(2))}
    rows = []
    for scheme, vars_ in schemes.items():
        def res(expr, base=None):
            m = re.fullmatch(r"var\((--[\w-]+)\)", expr)
            return parse_color(vars_[m.group(1)] if m else expr, base)
        for label, fg, bg, need in pairs:
            try:
                b = res(bg)
                f = res(fg, b)
            except (KeyError, ValueError) as e:
                fail(rel, f"contrast pair '{label}' unresolved ({e})")
                continue
            r = ratio(f, b)
            rows.append((rel.split("/")[-2] if rel.endswith("index.html") and "/" in rel else "site.css", scheme, label, fg, bg, r, need))
            if r < need:
                fail(rel, f"contrast {scheme} '{label}' {fg} on {bg} = {r:.2f} < {need}")
    return rows


# ----------------------------------------------------------------------------- main
def pages():
    out = []
    for dirpath, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d != "assets"]
        for f in files:
            if f.endswith(".html"):
                out.append(os.path.relpath(os.path.join(dirpath, f), ROOT))
    return sorted(out)


def main():
    pgs = pages()
    if not pgs:
        print("A11Y FAIL (no pages found under " + ROOT + ")")
        return 1
    for rel in pgs:
        check_page(rel)
    rows = check_css() if os.path.exists(os.path.join(ROOT, "assets/site.css")) else []
    for rel in pgs:
        inline = "\n".join(re.findall(r"<style[^>]*>(.*?)</style>", open(os.path.join(ROOT, rel), encoding="utf-8").read(), re.S))
        if inline.strip():
            rows += check_css(rel, inline, INLINE_PAIRS)
    print(f"{'source':<9} {'scheme':<8} {'pair':<28} {'ratio':>6} {'min':>4}")
    for src, scheme, label, _fg, _bg, r, need in rows:
        print(f"{src:<9} {scheme:<8} {label:<28} {r:6.2f} {need:4.1f}")
    for f in failures:
        print("FAIL:", f)
    if failures:
        print(f"A11Y FAIL ({len(failures)} failures)")
        return 1
    print(f"A11Y OK ({len(pgs)} pages)")
    return 0


sys.exit(main())
