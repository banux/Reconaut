#!/usr/bin/env bash
# scripts/check_no_mcp_stdio.sh — refuse tout point d'entrée MCP via
# stdio. Reconaut n'expose le protocole MCP QUE via HTTP+SSE
# (cf. project.md, mcp-as-primary-entrypoint).
#
# Source de vérité :
#   openspec/changes/add-mcp-engine/specs/mcp-server/spec.md
#     -> Requirement: No stdio MCP entrypoint
#
# Patterns refusés (hors commentaires et fichiers _test/_spec) :
#   - require "mcp/stdio" / require "mcp-rb/stdio" et variantes
#   - import "github.com/.../mcp-go/stdio" ou "/server/stdio"
#   - constantes / classes : MCP::Stdio, Mcp::Stdio, McpStdio
#   - flag CLI : --stdio (en chaîne, dans cmd args)
#   - constante STDIO_TRANSPORT
#
# Le script tolère explicitement :
#   - les commentaires (préfixe `#`, `//`, `/*`, `*`)
#   - les fichiers de test/spec (_test.go, _spec.rb, etc.)
#   - la documentation (`docs/`, `openspec/`, `*.md`)
#   - le linter lui-même

set -euo pipefail

cd "$(dirname "$0")/.."

errors=0

fail() {
  echo "no-mcp-stdio: $1" >&2
  errors=1
}

# Patterns interdits — case-insensitive
patterns=(
  'require\s+["'"'"'][^"'"'"']*mcp[a-zA-Z0-9_-]*[/_-]stdio'
  '"github\.com/[^"]*mcp[a-zA-Z0-9_-]*/stdio"'
  'MCP::Stdio'
  'Mcp::Stdio'
  '\bMcpStdio\b'
  '\bSTDIO_TRANSPORT\b'
  '--stdio'
)

target_dirs=(apps/api/app apps/api/lib apps/scanner apps/tui)

for dir in "${target_dirs[@]}"; do
  [[ -d "$dir" ]] || continue

  for p in "${patterns[@]}"; do
    hits=$(grep -RnE "$p" "$dir" 2>/dev/null \
      | grep -vE '_test\.|_spec\.|/spec/|/test/' \
      | grep -vE ':[0-9]+:[[:space:]]*(#|//|/\*|\*)' \
      || true)
    if [[ -n "$hits" ]]; then
      fail "stdio MCP pattern détecté dans $dir (pattern: $p) :"
      echo "$hits" >&2
    fi
  done
done

if (( errors != 0 )); then
  echo "check_no_mcp_stdio: KO ($errors violations)" >&2
  exit 1
fi

echo "check_no_mcp_stdio: OK"
