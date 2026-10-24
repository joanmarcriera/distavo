#!/usr/bin/env python3
"""Print line coverage (percent, rounded DOWN to 0.1) of Sources/DistavoCore from llvm-cov JSON.

Usage: python3 -I ops/coverage-lines.py <llvm-cov-export.json>
Only files under /Sources/DistavoCore/ count (not tests, not DistavoEmbedded).
Exit 1 when the data holds no DistavoCore sources.
"""
import json
import sys


def main(path: str) -> int:
    with open(path) as fh:
        data = json.load(fh)
    covered = total = 0
    for export in data["data"]:
        for f in export["files"]:
            if "/Sources/DistavoCore/" in f["filename"]:
                lines = f["summary"]["lines"]
                covered += lines["covered"]
                total += lines["count"]
    if total == 0:
        print("no DistavoCore sources in the coverage data", file=sys.stderr)
        return 1
    # integer maths so the floor never exceeds what was measured
    print("%.1f" % (int(covered * 1000 / total) / 10.0))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
