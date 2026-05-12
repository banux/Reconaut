#!/usr/bin/env bash
# scripts/check_rdp_probe_no_auth_test.sh — tests du linter anti-auth
# du sondeur RDP.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

assert_lint() {
  local desc="$1"
  local expected_code="$2"
  set +e
  bash scripts/check_rdp_probe_no_auth.sh > /tmp/check_rdp_probe_out 2>&1
  local got=$?
  set -e
  if [[ "$got" -eq "$expected_code" ]]; then
    echo "[ok]   $desc"
  else
    echo "[FAIL] $desc -- expected exit=$expected_code got=$got"
    cat /tmp/check_rdp_probe_out
    fail=1
  fi
}

# 1. État de base : OK (le sondeur ne contient aucune méthode d'auth).
assert_lint "current rdpprobe tree -> exit 0" 0

# 2. Injection d'un champ 'password' -> exit != 0.
TARGET=apps/scanner/internal/rdpprobe/rdpprobe.go
cp "$TARGET" "$TARGET.bak"
cat >> "$TARGET" <<'GO'

func injectedForTest() {
	var password = "nope"
	_ = password
}
GO
assert_lint "password injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 3. Injection d'un NTLM -> exit != 0.
cp "$TARGET" "$TARGET.bak"
cat >> "$TARGET" <<'GO'

func injectedForTest() {
	var ntlmHash string
	_ = ntlmHash
}
GO
assert_lint "ntlm injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 4. Injection d'un kerberos -> exit != 0.
cp "$TARGET" "$TARGET.bak"
cat >> "$TARGET" <<'GO'

func injectedForTest() {
	var kerberosTicket []byte
	_ = kerberosTicket
}
GO
assert_lint "kerberos injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 5. Injection d'un CredSSP -> exit != 0.
cp "$TARGET" "$TARGET.bak"
cat >> "$TARGET" <<'GO'

func injectedForTest() {
	var CredSSP int
	_ = CredSSP
}
GO
assert_lint "credssp injected -> exit != 0" 1
mv "$TARGET.bak" "$TARGET"

# 6. État propre post-cleanup.
assert_lint "clean tree (post-cleanup) -> exit 0" 0

# 7. Les commentaires qui DOCUMENTENT l'interdiction sont autorisés.
#    Le linter regex out les lignes commencant par //, /* ou *. Comme
#    le fichier de prod en contient déjà (commentaires de package qui
#    mentionnent password/credential/NTLM/Kerberos/CredSSP comme
#    interdits), si ce cas n'était pas géré la passe #1 aurait déjà
#    échoué — son succès est l'assertion implicite.
assert_lint "comments mentioning forbidden terms tolerated -> exit 0" 0

# 8. Les fichiers _test.go ne sont pas scannés (ex. variables locales
#    dans le faux serveur). Idem, vérifié implicitement par #1.
assert_lint "_test.go files skipped -> exit 0" 0

if (( fail != 0 )); then
  echo "check_rdp_probe_no_auth tests: KO" >&2
  exit 1
fi

echo "check_rdp_probe_no_auth tests: all green"
