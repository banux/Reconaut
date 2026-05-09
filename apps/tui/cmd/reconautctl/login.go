// SPDX-License-Identifier: AGPL-3.0-only
// Sous-commande `reconautctl login` : exception au pacte MCP-only.
// Appelle POST /auth/sessions pour obtenir une clé API personnelle puis
// la persiste sous $XDG_CONFIG_HOME/reconaut/credentials (fichier 0600,
// répertoire 0700). C'est le SEUL chemin REST que le binaire emprunte
// (cf. spec mcp-as-primary-entrypoint, scenario "Bootstrap initial —
// REST puis MCP").
//
// Le mot de passe N'EST PAS persisté ; seul le token de la clé API est
// stocké. Cf. openspec/changes/replace-web-with-tui/tasks.md §2.2.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/banux/Reconaut/apps/tui/internal/auth"
)

type LoginResult struct {
	APIKey string `json:"api_key"`
	UserID string `json:"user_id"`
}

func runLogin(ctx context.Context, baseURL, password string, out io.Writer, hc *http.Client) (*LoginResult, error) {
	if hc == nil {
		hc = http.DefaultClient
	}
	body, _ := json.Marshal(map[string]any{"password": password})

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(baseURL, "/")+"/auth/sessions", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		raw, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("login: status=%d body=%s", resp.StatusCode, string(raw))
	}
	var payload struct {
		APIKey struct {
			Token  string `json:"token"`
			Secret string `json:"secret"` // rétrocompat avec un futur renommage Rails
		} `json:"api_key"`
		User struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	token := payload.APIKey.Token
	if token == "" {
		token = payload.APIKey.Secret
	}

	// Persiste la clé sous $XDG_CONFIG_HOME/reconaut/credentials.
	if err := auth.Save(auth.Credentials{Server: strings.TrimRight(baseURL, "/"), APIKey: token}); err != nil {
		return nil, fmt.Errorf("login: persist credentials: %w", err)
	}

	fmt.Fprintf(out, "logged in as %s\n", payload.User.ID)
	return &LoginResult{APIKey: token, UserID: payload.User.ID}, nil
}
