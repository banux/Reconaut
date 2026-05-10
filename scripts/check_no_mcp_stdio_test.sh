#!/usr/bin/env bash
# scripts/check_no_mcp_stdio_test.sh — tests du linter no-mcp-stdio.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_no_mcp_stdio.sh > /tmp/check_no_mcp_stdio_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_no_mcp_stdio_out
    fail=1
  fi
}

# 1. État de base.
assert_lint "current tree -> exit 0" 0

# 2. Injection MCP::Stdio dans un fichier de prod -> exit != 0.
TARGET=apps/api/app/lib/mcp/agent_chat_streamer.rb
cp "$TARGET" "$TARGET.bak"
echo 'MCP::Stdio.start' >> "$TARGET"
assert_lint "MCP::Stdio injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 3. Injection require mcp-rb/stdio -> exit != 0.
cp "$TARGET" "$TARGET.bak"
echo 'require "mcp-rb/stdio"' >> "$TARGET"
assert_lint 'require "mcp-rb/stdio" -> exit != 0' 1
mv "$TARGET.bak" "$TARGET"

# 4. Injection import Go stdio MCP -> exit != 0.
TARGET_GO=apps/scanner/internal/sshprobe/sshprobe.go
cp "$TARGET_GO" "$TARGET_GO.bak"
sed -i 's|"golang.org/x/crypto/ssh"|"github.com/foo/mcp-go/stdio"|' "$TARGET_GO"
assert_lint "github.com/.../mcp-go/stdio import -> exit != 0" 1
mv "$TARGET_GO.bak" "$TARGET_GO"

# 5. Commentaire mentionnant MCP::Stdio est toléré.
cp "$TARGET" "$TARGET.bak"
echo '# Pas de MCP::Stdio dans le code (interdit par check_no_mcp_stdio.sh)' >> "$TARGET"
assert_lint "MCP::Stdio in comment -> exit 0" 0
mv "$TARGET.bak" "$TARGET"

# 6. Pattern dans un fichier _spec est toléré.
TARGET_SPEC=apps/api/spec/lib/mcp/agent_chat_streamer_spec.rb
if [[ -f "$TARGET_SPEC" ]]; then
  cp "$TARGET_SPEC" "$TARGET_SPEC.bak"
  echo 'MCP::Stdio.start' >> "$TARGET_SPEC"
  assert_lint "MCP::Stdio in _spec.rb -> exit 0" 0
  mv "$TARGET_SPEC.bak" "$TARGET_SPEC"
fi

# 7. État propre.
assert_lint "clean tree (post-cleanup) -> exit 0" 0

if (( fail != 0 )); then
  echo "check_no_mcp_stdio tests: KO" >&2
  exit 1
fi

echo "check_no_mcp_stdio tests: all green"
