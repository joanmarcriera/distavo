#!/usr/bin/env python3
"""ops/tests/check-comparison-urls.py - every cell of the comparison table must carry an https URL
and a YYYY-MM-DD date (Vikunja #4663). Read-only, stdlib only.

Usage:   python3 -I ops/tests/check-comparison-urls.py PAGE.html
Checks:  every <td> inside <tbody> of the first <table> has an <a href="https://..."> and a date.
Exit:    0 = every cell passes; 1 = at least one cell lacks a URL or a date (listed on stdout);
         2 = usage error or no table cells found.
"""
import re
import sys
from html.parser import HTMLParser


class Cells(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_body = False
        self.cell = None      # [text parts, hrefs] while inside a <td>
        self.cells = []

    def handle_starttag(self, tag, attrs):
        if tag == "tbody":
            self.in_body = True
        elif tag == "td" and self.in_body:
            self.cell = ["", []]
        elif tag == "a" and self.cell is not None:
            self.cell[1].append(dict(attrs).get("href") or "")

    def handle_endtag(self, tag):
        if tag == "tbody":
            self.in_body = False
        elif tag == "td" and self.cell is not None:
            self.cells.append(self.cell)
            self.cell = None

    def handle_data(self, data):
        if self.cell is not None:
            self.cell[0] += data


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    p = Cells()
    p.feed(open(argv[1], encoding="utf-8").read())
    if not p.cells:
        print("no table cells found")
        return 2
    bad = 0
    for i, (text, hrefs) in enumerate(p.cells, 1):
        problems = []
        if not any(h.startswith("https://") for h in hrefs):
            problems.append("no https URL")
        if not re.search(r"\b\d{4}-\d{2}-\d{2}\b", text):
            problems.append("no YYYY-MM-DD date")
        if problems:
            bad += 1
            print("cell %d (%r): %s" % (i, " ".join(text.split())[:60], ", ".join(problems)))
    print("%d cells, %d bad" % (len(p.cells), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
