#!/usr/bin/env bash
# scripts/check_ssh_probe_no_auth_test.sh — tests du linter anti-auth
# du sondeur SSH.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_ssh_probe_no_auth.sh > /tmp/check_ssh_probe_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_ssh_probe_out
    fail=1
  fi
}

# 1. État de base : OK (le sondeur ne contient aucune méthode d'auth).
assert_lint "current sshprobe tree -> exit 0" 0

# 2. Injection d'une auth -> exit != 0.
TARGET=apps/scanner/internal/sshprobe/sshprobe.go
cp "$TARGET" "$TARGET.bak"
# Ajoute une ligne avec ssh.Password (en-dehors de tout commentaire).
cat >> "$TARGET" <<'GO'

func injectedForTest() {
	_ = ssh.Password("nope")
}
GO
assert_lint "ssh.Password injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 3. Injection d'une PublicKeys -> exit != 0.
cp "$TARGET" "$TARGET.bak"
cat >> "$TARGET" <<'GO'

func injectedForTest() {
	_ = ssh.PublicKeys()
}
GO
assert_lint "ssh.PublicKeys injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 4. Injection d'une KeyboardInteractive -> exit != 0.
cp "$TARGET" "$TARGET.bak"
cat >> "$TARGET" <<'GO'

func injectedForTest() {
	_ = ssh.KeyboardInteractive(nil)
}
GO
assert_lint "ssh.KeyboardInteractive injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 5. État propre.
assert_lint "clean tree (post-cleanup) -> exit 0" 0

# 6. Les fichiers _test.go peuvent contenir des callbacks serveur
#    sans déclencher le linter (ex. PasswordCallback dans le fake
#    server). Ce test passe simplement parce que le tree actuel
#    contient déjà sshprobe_test.go avec ces callbacks.
assert_lint "_test.go callbacks tolerated -> exit 0" 0

if (( fail != 0 )); then
  echo "check_ssh_probe_no_auth tests: KO" >&2
  exit 1
fi

echo "check_ssh_probe_no_auth tests: all green"
