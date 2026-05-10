#!/usr/bin/env bash
# scripts/check_doc_links_test.sh — tests du linter doc-links.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_doc_links.sh > /tmp/check_doc_links_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_doc_links_out
    fail=1
  fi
}

# 1. État de base : tous les liens résolvent.
assert_lint "current docs tree -> exit 0" 0

# 2. Injection d'un lien cassé dans un fichier doc -> exit != 0.
TARGET=docs/index.md
cp "$TARGET" "$TARGET.bak"
echo '[doesnt-exist](../foo/non-existent.md)' >> "$TARGET"
assert_lint "broken relative link -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 3. URL absolue tolérée.
cp "$TARGET" "$TARGET.bak"
echo '[github](https://github.com/banux/Reconaut)' >> "$TARGET"
assert_lint "absolute URL https:// -> exit 0" 0
mv "$TARGET.bak" "$TARGET"

# 4. Ancre pure tolérée.
cp "$TARGET" "$TARGET.bak"
echo '[section](#some-section)' >> "$TARGET"
assert_lint "anchor-only link -> exit 0" 0
mv "$TARGET.bak" "$TARGET"

# 5. Lien dans bloc de code ignoré.
cp "$TARGET" "$TARGET.bak"
cat >> "$TARGET" <<'CODE'

```
[ignore me](../doesnt-exist.md)
```
CODE
assert_lint "link inside code block ignored -> exit 0" 0
mv "$TARGET.bak" "$TARGET"

# 6. État propre.
assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_doc_links tests: KO" >&2
  exit 1
fi

echo "check_doc_links tests: all green"
