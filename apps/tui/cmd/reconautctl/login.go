// Sous-commande `reconautctl login` : exception au pacte MCP-only.
// Appelle POST /auth/sessions puis (optionnellement) POST /auth/api_keys
// pour obtenir une clé API personnelle. C'est le SEUL chemin REST que
// le binaire emprunte (cf. spec mcp-as-primary-entrypoint, scenario
// "Bootstrap initial — REST puis MCP").
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
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
			Secret string `json:"secret"`
		} `json:"api_key"`
		User struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	fmt.Fprintf(out, "logged in as %s\n", payload.User.ID)
	return &LoginResult{APIKey: payload.APIKey.Secret, UserID: payload.User.ID}, nil
}
