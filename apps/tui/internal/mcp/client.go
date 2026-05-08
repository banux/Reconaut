// Package mcp fournit un client minimal du transport MCP HTTP+SSE
// utilisé par le binaire reconautctl pour invoquer les outils MCP
// exposés par le serveur Rails.
//
// Source de vérité :
//
//	openspec/changes/mcp-as-primary-entrypoint/specs/architecture/spec.md
//	  -> Requirement: MCP HTTP+SSE as Primary Entrypoint
//	openspec/changes/mcp-as-primary-entrypoint/tasks.md §3.1 / §3.2
//
// Le client expose deux modes d'invocation :
//   - Invoke : appel synchrone, retourne un Result.
//   - InvokeStreaming : appel SSE, retourne un canal de Chunks. Utile
//     pour agent_chat (cf. §1.2).
//
// Authentification : l'appelant injecte une APIKey ; le client l'envoie
// systématiquement via le header Authorization: Bearer <key>. Aucune
// route hors /mcp/, /auth/sessions, /auth/api_keys, /healthz n'est
// jamais sollicitée — c'est le pacte avec le linter §3.3.
package mcp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// Result est le payload JSON retourné par /mcp/tools/<tool_name> en
// mode synchrone : { "tool": "<name>", "result": { ... } } ou
// { "error": "<code>", "message": "..." } sur erreur.
type Result struct {
	Tool   string                 `json:"tool"`
	Result map[string]any         `json:"result"`
	// Présents seulement sur erreur :
	Error   string `json:"error,omitempty"`
	Message string `json:"message,omitempty"`
}

// Chunk est un fragment "tool_result" partiel reçu via SSE.
// Cf. spec mcp-as-primary-entrypoint §1.2 (streaming agent_chat).
type Chunk struct {
	Tool    string         `json:"tool"`
	Partial bool           `json:"partial"`
	Result  map[string]any `json:"result"`
}

// Client encapsule l'URL de base et la clé API. Thread-safe pour les
// appels concurrents via un *http.Client sous-jacent.
type Client struct {
	BaseURL    string
	APIKey     string
	UserAgent  string
	HTTPClient *http.Client
}

// New construit un Client avec un *http.Client par défaut. baseURL doit
// être de la forme "https://reconaut.example.com" — le client accole
// les chemins /mcp/* lui-même.
func New(baseURL, apiKey string) *Client {
	return &Client{
		BaseURL:    strings.TrimRight(baseURL, "/"),
		APIKey:     apiKey,
		UserAgent:  "reconautctl/dev",
		HTTPClient: &http.Client{},
	}
}

// Invoke appelle POST /mcp/tools/<toolName> avec un body JSON contenant
// les params, et décode la réponse synchrone en Result. Retourne une
// erreur si la requête HTTP échoue ou si le statut n'est pas 2xx.
func (c *Client) Invoke(ctx context.Context, toolName string, params map[string]any) (*Result, error) {
	if toolName == "" {
		return nil, errors.New("mcp.Invoke: toolName required")
	}
	body, err := json.Marshal(params)
	if err != nil {
		return nil, fmt.Errorf("mcp.Invoke: marshal params: %w", err)
	}

	url := c.BaseURL + "/mcp/tools/" + toolName
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	c.applyHeaders(req)
	req.Header.Set("Accept", "application/json")

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var result Result
	if jerr := json.Unmarshal(raw, &result); jerr != nil {
		return nil, fmt.Errorf("mcp.Invoke: decode response (status=%d): %w", resp.StatusCode, jerr)
	}
	if resp.StatusCode/100 != 2 {
		if result.Error == "" {
			result.Error = fmt.Sprintf("http_%d", resp.StatusCode)
		}
		return &result, fmt.Errorf("mcp.Invoke: %s: %s", result.Error, result.Message)
	}
	return &result, nil
}

// InvokeStreaming appelle POST /mcp/tools/<toolName> avec
// Accept: text/event-stream et lit le flux SSE. Chaque événement
// "tool_result" est désérialisé en Chunk et émis sur le canal retourné.
// Le canal est fermé quand le stream est terminé ou si le contexte
// expire. L'appelant peut annuler via ctx.
func (c *Client) InvokeStreaming(ctx context.Context, toolName string, params map[string]any) (<-chan Chunk, error) {
	if toolName == "" {
		return nil, errors.New("mcp.InvokeStreaming: toolName required")
	}
	body, err := json.Marshal(params)
	if err != nil {
		return nil, fmt.Errorf("mcp.InvokeStreaming: marshal params: %w", err)
	}

	url := c.BaseURL + "/mcp/tools/" + toolName
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	c.applyHeaders(req)
	req.Header.Set("Accept", "text/event-stream")

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return nil, fmt.Errorf("mcp.InvokeStreaming: status=%d body=%s", resp.StatusCode, string(raw))
	}

	out := make(chan Chunk, 8)
	go func() {
		defer close(out)
		defer resp.Body.Close()
		parseSSE(resp.Body, out)
	}()
	return out, nil
}

// parseSSE lit un flux SSE et émet un Chunk pour chaque évènement
// "data:" qui se décode en JSON Chunk. Ignore les commentaires (lignes
// commençant par ":") et les événements vides.
func parseSSE(r io.Reader, out chan<- Chunk) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)

	var dataLines []string
	flush := func() {
		if len(dataLines) == 0 {
			return
		}
		joined := strings.Join(dataLines, "\n")
		dataLines = dataLines[:0]
		var chunk Chunk
		if err := json.Unmarshal([]byte(joined), &chunk); err == nil {
			out <- chunk
		}
	}

	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			flush()
			continue
		}
		if strings.HasPrefix(line, ":") {
			continue // commentaire SSE
		}
		if strings.HasPrefix(line, "data:") {
			dataLines = append(dataLines, strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))
		}
	}
	flush()
}

func (c *Client) applyHeaders(req *http.Request) {
	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}
	if c.UserAgent != "" {
		req.Header.Set("User-Agent", c.UserAgent)
	}
	req.Header.Set("Content-Type", "application/json")
}
