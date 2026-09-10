#!/usr/bin/env python3
"""Emit manifest.json for a converted WhisperKit folder: source revision, tool
revision, and size + SHA-256 per file, so the app can verify a download and a
later conversion never silently replaces this one (spec §5.6).

Usage: manifest.py <folder> <source-model-id> <source-revision> <tools-revision>
"""
import hashlib, json, os, sys
folder, source, source_rev, tools_rev = sys.argv[1:5]
files = {}
for root, _, names in os.walk(folder):
    for n in sorted(names):
        if n == "manifest.json":
            continue
        p = os.path.join(root, n); rel = os.path.relpath(p, folder)
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        files[rel] = {"bytes": os.path.getsize(p), "sha256": h.hexdigest()}
print(json.dumps({"source_model": source, "source_revision": source_rev,
                  "whisperkittools": tools_rev, "files": files}, indent=2))
