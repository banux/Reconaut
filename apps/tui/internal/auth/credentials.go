// SPDX-License-Identifier: AGPL-3.0-only
// Package auth gère le stockage local de la clé API personnelle de
// l'opérateur après `reconautctl login`.
//
// Source de vérité :
//
//	openspec/changes/replace-web-with-tui/tasks.md §2.2 :
//	  "Stockage de la clé sous $XDG_CONFIG_HOME/reconaut/credentials
//	   (créer le répertoire avec 0700 et le fichier avec 0600)."
//
// Pacte : le mot de passe N'EST PAS persisté. Seul le token de la
// clé API (en clair, comme délivré une fois par /auth/sessions) est
// écrit, dans un fichier strictement réservé à l'utilisateur courant.
package auth

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Credentials est le contenu persisté. Format minimal : un fichier
// "key=value\n" qu'on peut éditer à la main si besoin (pas de JSON
// pour rester `cat`-able).
type Credentials struct {
	Server string // ex: https://reconaut.example.com
	APIKey string // raw token, valide tant que la clé n'est pas révoquée
}

// Path retourne le chemin du fichier credentials. Suit XDG :
//   - $XDG_CONFIG_HOME/reconaut/credentials si la variable est définie
//   - sinon $HOME/.config/reconaut/credentials
func Path() (string, error) {
	if v := os.Getenv("XDG_CONFIG_HOME"); v != "" {
		return filepath.Join(v, "reconaut", "credentials"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("auth: cannot resolve home dir: %w", err)
	}
	return filepath.Join(home, ".config", "reconaut", "credentials"), nil
}

// Save écrit les credentials sur disque. Crée le répertoire parent en
// 0700 et le fichier en 0600 — le pacte explicite du change.
func Save(c Credentials) error {
	if c.APIKey == "" {
		return errors.New("auth: refusing to save empty api_key")
	}
	path, err := Path()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("auth: mkdir: %w", err)
	}
	body := fmt.Sprintf("server=%s\napi_key=%s\n", c.Server, c.APIKey)
	// Open with O_CREATE|O_TRUNC|O_WRONLY and explicit perms ; if the
	// file pre-existed with a more permissive mode, force 0600.
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("auth: open: %w", err)
	}
	defer f.Close()
	if _, err := f.WriteString(body); err != nil {
		return fmt.Errorf("auth: write: %w", err)
	}
	// Force perms even if umask reset them.
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("auth: chmod: %w", err)
	}
	return nil
}

// Load lit les credentials depuis le disque. Renvoie ErrNotFound quand
// le fichier n'existe pas (cas premier login).
func Load() (Credentials, error) {
	path, err := Path()
	if err != nil {
		return Credentials{}, err
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Credentials{}, ErrNotFound
	}
	if err != nil {
		return Credentials{}, fmt.Errorf("auth: read: %w", err)
	}
	c := Credentials{}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "server":
			c.Server = strings.TrimSpace(v)
		case "api_key":
			c.APIKey = strings.TrimSpace(v)
		}
	}
	return c, nil
}

// ErrNotFound est retourné par Load quand l'opérateur n'a jamais
// loggué via `reconautctl login`.
var ErrNotFound = errors.New("auth: credentials not found (run `reconautctl login`)")
