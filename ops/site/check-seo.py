#!/usr/bin/env python3
"""ops/site/check-seo.py - SEO and weight-budget checks for the Distavo static site (read-only, stdlib only).

Usage:   python3 -I ops/site/check-seo.py [SITE_ROOT]      (default: the directory of this file)
Exit:    0 and last line "SEO OK" (after a sizes table) when clean; 1 and "SEO FAIL (K failures)" otherwise.
Checks:  sitemap.xml parses and lists every indexable page, with xhtml:link alternates (en/ca/es/x-default)
         on the landing pages; robots.txt allows all and names the sitemap; per page: unique <title> <= 60,
         meta description <= 160, canonical equal to the page's own URL, og:title + og:description, JSON-LD
         SoftwareApplication on landing pages (valid JSON, name, operatingSystem, applicationCategory; an
         "offers" block only when its price is written on the page); no external requests (stylesheet,
         script, img, source, iframe, CSS url()); weight budget: each HTML <= 60 KB, assets/ <= 250 KB.
Pages with <meta name="robots" content="noindex"> are exempt from the sitemap rule and must not be in it.
"""
import json
import os
import re
import sys
from html.parser import HTMLParser
from xml.dom import minidom

ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
BASE = "https://distavo.com"
LANDING = {"index.html": "/", "ca/index.html": "/ca/", "es/index.html": "/es/"}
HTML_MAX, ASSETS_MAX, TITLE_MAX, DESC_MAX = 60 * 1024, 250 * 1024, 60, 160
failures = []


def fail(where, msg):
    failures.append(f"{where}: {msg}")


class Head(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title = ""
        self.in_title = False
        self.meta = {}
        self.canonical = None
        self.ld = []
        self._in_ld = False
        self.external = []
        self.text = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "title":
            self.in_title = True
        elif tag == "meta":
            key = a.get("name") or a.get("property")
            if key:
                self.meta[key] = a.get("content", "")
        elif tag == "link" and a.get("rel") == "canonical":
            self.canonical = a.get("href")
        elif tag == "script" and a.get("type") == "application/ld+json":
            self._in_ld = True
            self.ld.append("")
        if tag in ("script", "style"):
            self._skip += 1
        # external requests: anything the browser fetches by itself; plain <a> links are fine
        ref = a.get("src") if tag in ("script", "img", "source", "iframe", "video", "audio") else (
            a.get("href") if tag == "link" and a.get("rel") in ("stylesheet", "preload", "prefetch", "modulepreload") else None)
        if ref and re.match(r"(https?:)?//", ref):
            self.external.append(f"<{tag}> {ref}")

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False
        if tag == "script":
            self._in_ld = False
        if tag in ("script", "style") and self._skip:
            self._skip -= 1

    def handle_data(self, data):
        if self.in_title:
            self.title += data
        if self._in_ld:
            self.ld[-1] += data
        if not self._skip:
            self.text.append(data)


def html_pages():
    out = []
    for dirpath, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d != "assets"]
        out += [os.path.relpath(os.path.join(dirpath, f), ROOT) for f in files if f.endswith(".html")]
    return sorted(out)


def page_url(rel):
    d = os.path.dirname(rel)
    return BASE + "/" + (d + "/" if d else "")


def check_sitemap(indexable):
    path = os.path.join(ROOT, "sitemap.xml")
    if not os.path.exists(path):
        fail("sitemap.xml", "missing")
        return
    try:
        dom = minidom.parse(path)
    except Exception as e:  # any parse failure is a failure of the file
        fail("sitemap.xml", f"does not parse: {e}")
        return
    urls = {}
    for u in dom.getElementsByTagName("url"):
        loc = u.getElementsByTagName("loc")[0].firstChild.data.strip()
        alts = {l.getAttribute("hreflang"): l.getAttribute("href") for l in u.getElementsByTagName("xhtml:link")}
        urls[loc] = alts
    for rel in indexable:
        url = page_url(rel)
        if url not in urls:
            fail("sitemap.xml", f"missing {url}")
        elif rel in LANDING:
            want = {"en": BASE + "/", "ca": BASE + "/ca/", "es": BASE + "/es/", "x-default": BASE + "/"}
            if urls[url] != want:
                fail("sitemap.xml", f"{url} alternates are {urls[url]}, wanted {want}")
    for loc in urls:
        if not loc.startswith(BASE + "/"):
            fail("sitemap.xml", f"{loc} is not under {BASE}")
        if loc not in {page_url(r) for r in indexable}:
            fail("sitemap.xml", f"{loc} is not an indexable page of this site")


def check_robots():
    path = os.path.join(ROOT, "robots.txt")
    if not os.path.exists(path):
        fail("robots.txt", "missing")
        return
    txt = open(path, encoding="utf-8").read()
    if not re.search(r"(?mi)^User-agent:\s*\*", txt) or not re.search(r"(?mi)^Allow:\s*/\s*$", txt):
        fail("robots.txt", "must allow all for User-agent: *")
    if re.search(r"(?mi)^Disallow:\s*/\s*$", txt):
        fail("robots.txt", "disallows the whole site")
    if f"Sitemap: {BASE}/sitemap.xml" not in txt:
        fail("robots.txt", f"missing 'Sitemap: {BASE}/sitemap.xml'")


def main():
    rows, titles, indexable = [], {}, []
    pages = html_pages()
    if not pages:
        print("SEO FAIL (no pages found under " + ROOT + ")")
        return 1
    for rel in pages:
        raw = open(os.path.join(ROOT, rel), encoding="utf-8").read()
        h = Head()
        h.feed(raw)
        size = len(raw.encode("utf-8"))
        rows.append((rel, size, HTML_MAX))
        if size > HTML_MAX:
            fail(rel, f"{size} bytes exceeds the {HTML_MAX} byte HTML budget")
        noindex = "noindex" in h.meta.get("robots", "")
        if not noindex:
            indexable.append(rel)
        title = " ".join(h.title.split())
        if not title:
            fail(rel, "no <title>")
        elif len(title) > TITLE_MAX:
            fail(rel, f"title is {len(title)} chars (> {TITLE_MAX})")
        if title in titles:
            fail(rel, f"title duplicates {titles[title]}")
        titles[title] = rel
        desc = h.meta.get("description", "")
        if not desc:
            fail(rel, "no meta description")
        elif len(desc) > DESC_MAX:
            fail(rel, f"description is {len(desc)} chars (> {DESC_MAX})")
        if h.canonical != page_url(rel):
            fail(rel, f"canonical is {h.canonical!r}, wanted {page_url(rel)!r}")
        for k in ("og:title", "og:description"):
            if not h.meta.get(k):
                fail(rel, f"missing {k}")
        for ext in h.external:
            fail(rel, f"external request {ext}")
        # JSON-LD
        if rel in LANDING:
            if not h.ld:
                fail(rel, "no JSON-LD block")
        for block in h.ld:
            try:
                data = json.loads(block)
            except ValueError as e:
                fail(rel, f"JSON-LD does not parse: {e}")
                continue
            if rel in LANDING:
                if data.get("@type") != "SoftwareApplication":
                    fail(rel, "JSON-LD @type is not SoftwareApplication")
                for k in ("name", "operatingSystem", "applicationCategory"):
                    if not data.get(k):
                        fail(rel, f"JSON-LD missing {k}")
                if "macOS" not in str(data.get("operatingSystem", "")):
                    fail(rel, "JSON-LD operatingSystem does not name macOS")
                offers = data.get("offers")
                if offers:
                    price = str(offers.get("price", "")).split(".")[0]
                    body = " ".join(h.text)
                    if not price or price not in body:
                        fail(rel, f"JSON-LD offers price {offers.get('price')} is not written on the page")
    # assets
    total = 0
    adir = os.path.join(ROOT, "assets")
    for dirpath, _d, files in os.walk(adir):
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            n = os.path.getsize(p)
            total += n
            rows.append(("assets/" + os.path.relpath(p, adir), n, None))
            if f.endswith(".css") and re.search(r"url\(\s*['\"]?(https?:)?//", open(p, encoding="utf-8").read()):
                fail("assets/" + f, "external url() in CSS")
    if total > ASSETS_MAX:
        fail("assets/", f"{total} bytes exceeds the {ASSETS_MAX} byte budget")
    check_sitemap(indexable)
    check_robots()
    print(f"{'file':<28} {'bytes':>8}  budget")
    for rel, n, cap in rows:
        print(f"{rel:<28} {n:>8}  {cap if cap else ''}")
    print(f"{'assets/ total':<28} {total:>8}  {ASSETS_MAX}")
    for f in failures:
        print("FAIL:", f)
    if failures:
        print(f"SEO FAIL ({len(failures)} failures)")
        return 1
    print("SEO OK")
    return 0


sys.exit(main())
