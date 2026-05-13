// SPDX-License-Identifier: AGPL-3.0-only
// Package agentclient est le client HTTP MCP minimal utilisé par les
// binaires scanner-<kind> pour dialoguer EXCLUSIVEMENT avec le serveur
// Rails (claim, submit, fail). Les workers n'accèdent JAMAIS à Postgres.
//
// Source de vérité :
//
//	openspec/changes/remote-scanner-agents/specs/scanning/spec.md
//	  -> Requirement: Workers Go consomment la file via MCP HTTP
//	openspec/changes/remote-scanner-agents/specs/mcp-server/spec.md
//	  -> Requirement: MCP Tool claim_scan_job / submit_scan_result / fail_scan_job
//
// Stdlib only : net/http + encoding/json + crypto/tls. Aucune dépendance
// externe (audit AGPL trivial, surface d'attaque minimale).
package agentclient

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Job est la représentation côté worker d'un job claimé.
type Job struct {
	ID         string         `json:"id"`
	Params     map[string]any `json:"params"`
	LeaseUntil time.Time      `json:"-"`
	Empty      bool           `json:"-"`
}

// Client encapsule l'URL de base et la clé API. Thread-safe pour les
// appels concurrents via un *http.Client sous-jacent.
type Client struct {
	BaseURL    string
	APIKey     string
	WorkerID   string
	UserAgent  string
	HTTPClient *http.Client
}

// New construit un Client avec un *http.Client par défaut.
// `tlsInsecure=true` désactive la vérification du cert serveur — DEV ONLY.
func New(baseURL, apiKey, workerID string, tlsInsecure bool) *Client {
	transport := &http.Transport{}
	if tlsInsecure {
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec // opt-in dev only
	}
	return &Client{
		BaseURL:    strings.TrimRight(baseURL, "/"),
		APIKey:     apiKey,
		WorkerID:   workerID,
		UserAgent:  "reconaut-scanner-agent/dev",
		HTTPClient: &http.Client{Transport: transport, Timeout: 30 * time.Second},
	}
}

// Claim appelle POST /mcp/tools/claim_scan_job. Retourne un *Job
// (Empty=true si la file est vide) ou une erreur réseau/HTTP.
func (c *Client) Claim(ctx context.Context, queue string, leaseSeconds int) (*Job, error) {
	if queue == "" {
		return nil, errors.New("agentclient.Claim: queue required")
	}
	params := map[string]any{
		"queue":         queue,
		"worker_id":     c.WorkerID,
		"lease_seconds": leaseSeconds,
	}
	result, err := c.invoke(ctx, "claim_scan_job", params)
	if err != nil {
		return nil, err
	}
	empty, _ := result["empty"].(bool)
	if empty {
		return &Job{Empty: true}, nil
	}
	rawJob, ok := result["job"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("agentclient: claim response missing job field; got %v", result)
	}
	id, _ := rawJob["id"].(string)
	params2, _ := rawJob["params"].(map[string]any)
	leaseStr, _ := rawJob["lease_until"].(string)
	leaseUntil, _ := time.Parse(time.RFC3339, leaseStr)
	return &Job{
		ID:         id,
		Params:     params2,
		LeaseUntil: leaseUntil,
		Empty:      false,
	}, nil
}

// Submit appelle POST /mcp/tools/submit_scan_result.
func (c *Client) Submit(ctx context.Context, jobID, idemKey, scanKind, targetKind, targetValue, status string, observedAt time.Time) error {
	params := map[string]any{
		"job_id":          jobID,
		"idempotency_key": idemKey,
		"scan_kind":       scanKind,
		"target_kind":     targetKind,
		"target_value":    targetValue,
		"status":          status,
		"observed_at":     observedAt.UTC().Format(time.RFC3339),
	}
	result, err := c.invoke(ctx, "submit_scan_result", params)
	if err != nil {
		return err
	}
	if ok, _ := result["ok"].(bool); !ok {
		errCode, _ := result["error"].(string)
		return fmt.Errorf("agentclient: submit refused: %s", errCode)
	}
	return nil
}

// Fail appelle POST /mcp/tools/fail_scan_job.
func (c *Client) Fail(ctx context.Context, jobID, errMsg string) error {
	params := map[string]any{
		"job_id": jobID,
		"error":  errMsg,
	}
	_, err := c.invoke(ctx, "fail_scan_job", params)
	return err
}

// invoke est l'appel HTTP générique POST /mcp/tools/<name> avec auth
// Bearer. Retourne le sous-hash `result` de la réponse JSON.
func (c *Client) invoke(ctx context.Context, toolName string, params map[string]any) (map[string]any, error) {
	body, err := json.Marshal(params)
	if err != nil {
		return nil, fmt.Errorf("agentclient: marshal: %w", err)
	}
	url := c.BaseURL + "/mcp/tools/" + toolName
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("agentclient: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", c.UserAgent)
	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("agentclient: do %s: %w", toolName, err)
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("agentclient: %s returned %d: %s", toolName, resp.StatusCode, strings.TrimSpace(string(raw)))
	}

	var decoded struct {
		Tool   string         `json:"tool"`
		Result map[string]any `json:"result"`
		Error  string         `json:"error,omitempty"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, fmt.Errorf("agentclient: decode %s: %w (raw=%q)", toolName, err, string(raw))
	}
	if decoded.Error != "" {
		return nil, fmt.Errorf("agentclient: %s error %s", toolName, decoded.Error)
	}
	if decoded.Result == nil {
		decoded.Result = map[string]any{}
	}
	return decoded.Result, nil
}
