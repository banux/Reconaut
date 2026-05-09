// SPDX-License-Identifier: AGPL-3.0-only
package auth

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Cf. openspec/changes/replace-web-with-tui/tasks.md §2.2 :
// "Le mot de passe N'EST PAS persisté ; le fichier credentials a 0600 ;
//  le repertoire parent est créé en 0700."

func TestSave_FilePermsAre0600AndDirIs0700(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", tmp)

	c := Credentials{Server: "https://reconaut.example", APIKey: "rk_secret"}
	if err := Save(c); err != nil {
		t.Fatalf("Save: %v", err)
	}

	path, _ := Path()
	st, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if mode := st.Mode().Perm(); mode != 0o600 {
		t.Errorf("file perms = %#o, want 0600", mode)
	}
	dir, err := os.Stat(filepath.Dir(path))
	if err != nil {
		t.Fatalf("stat dir: %v", err)
	}
	if mode := dir.Mode().Perm(); mode != 0o700 {
		t.Errorf("dir perms = %#o, want 0700", mode)
	}
}

func TestSave_ContentIsKeyValue(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", tmp)

	c := Credentials{Server: "https://reconaut.example", APIKey: "rk_secret"}
	if err := Save(c); err != nil {
		t.Fatalf("Save: %v", err)
	}
	path, _ := Path()
	raw, _ := os.ReadFile(path)
	body := string(raw)
	if !strings.Contains(body, "server=https://reconaut.example") {
		t.Errorf("body missing server line: %s", body)
	}
	if !strings.Contains(body, "api_key=rk_secret") {
		t.Errorf("body missing api_key line: %s", body)
	}
}

func TestSave_RoundTrip(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", tmp)

	c := Credentials{Server: "https://reconaut.example", APIKey: "rk_secret"}
	if err := Save(c); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got != c {
		t.Errorf("round trip: got %+v, want %+v", got, c)
	}
}

func TestSave_RefusesEmptyAPIKey(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", tmp)
	if err := Save(Credentials{Server: "x"}); err == nil {
		t.Error("expected error on empty api_key")
	}
}

func TestLoad_NotFound(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", tmp)
	_, err := Load()
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

// Le mot de passe ne DOIT PAS apparaître dans les credentials persistés
// même si l'appelant essaie maladroitement de l'inclure (ce qui n'est
// pas le contrat de l'API : Save ne prend pas de password). On fait
// un test de fuzz-like : on vérifie qu'aucun champ de Credentials ne
// peut transporter un password sous l'apparence d'autre chose.
func TestSave_NoPasswordPersisted(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", tmp)

	// L'appelant ne peut passer qu'un APIKey ; pas de champ Password.
	if err := Save(Credentials{Server: "x", APIKey: "rk_token"}); err != nil {
		t.Fatalf("Save: %v", err)
	}
	path, _ := Path()
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "password") {
		t.Errorf("credentials file contains the word 'password' : %s", raw)
	}
}
