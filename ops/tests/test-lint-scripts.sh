#!/usr/bin/env bash
# ops/tests/test-lint-scripts.sh - proves ops/lint-scripts.sh passes the repo and exits 1 on a
# throwaway copy with one injected defect each (missing set -u, shellcheck warning, syntax error,
# swallowed Python exception, main() not wired to the exit code).
#
# Usage: ops/tests/test-lint-scripts.sh      exit 0 = every assertion held, last line "TEST OK"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fresh() { # fresh <name>: copy of ops/ and scripts/ the linter can run against
  rm -rf "${TMP:?}/$1"; mkdir -p "$TMP/$1"
  cp -R "$ROOT/ops" "$ROOT/scripts" "$TMP/$1/"
  find "$TMP/$1" -name __pycache__ -prune -exec rm -rf {} +
}
expect() { # expect <wanted exit> <label> <name>
  local want="$1" label="$2" got=0
  "$TMP/$3/ops/lint-scripts.sh" >"$TMP/out.txt" 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then echo "FAIL: $label: exit $got, wanted $want"; cat "$TMP/out.txt"; exit 1; fi
  echo "ok: $label (exit $got)"
}

fresh clean;   expect 0 "unmodified copy" clean
fresh nosetu;  printf '#!/usr/bin/env bash\necho hi\n' >"$TMP/nosetu/ops/bad.sh"
expect 1 "script without set -u" nosetu
fresh sc;      printf '#!/usr/bin/env bash\nset -u\nx=$(ls)\ncd $x\n' >"$TMP/sc/ops/bad.sh"
expect 1 "shellcheck warning" sc
fresh syn;     printf '#!/usr/bin/env bash\nset -u\nif then fi\n' >"$TMP/syn/ops/bad.sh"
expect 1 "shell syntax error" syn
fresh swallow; printf 'def f():\n    try:\n        g()\n    except Exception:\n        pass\n' >"$TMP/swallow/scripts/bad.py"
expect 1 "swallowed Python exception" swallow
fresh nomain;  printf 'def main():\n    return 1\n\nif __name__ == "__main__":\n    main()\n' >"$TMP/nomain/scripts/bad.py"
expect 1 "main() not wired to exit code" nomain

echo "TEST OK"
