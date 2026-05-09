// SPDX-License-Identifier: AGPL-3.0-only
// reconautctl : binaire opérateur Reconaut.
//
// Toutes les opérations métier passent par MCP HTTP+SSE.
// Seul `login` parle REST (auth bootstrap), c'est le pacte du change
// mcp-as-primary-entrypoint.
//
// Usage indicatif (le squelette UI complet — bubbletea — viendra
// avec replace-web-with-tui) :
//
//	reconautctl login           # POST /auth/sessions + /auth/api_keys
//	reconautctl scope list      # MCP list_scopes
//	reconautctl scan request …  # MCP request_scan
//	reconautctl hosts search …  # MCP search_hosts
//	reconautctl agent "modbus"  # MCP agent_chat (SSE)
//	reconautctl doctor          # MCP system_doctor
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/banux/Reconaut/apps/tui/internal/mcp"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: reconautctl <login|scope|scan|hosts|agent|doctor> ...")
		os.Exit(2)
	}

	baseURL := envOr("RECONAUT_URL", "http://localhost:3000")
	apiKey := os.Getenv("RECONAUT_API_KEY")
	c := mcp.New(baseURL, apiKey)
	ctx := context.Background()

	switch os.Args[1] {
	case "login":
		password := os.Getenv("RECONAUT_PASSWORD")
		if _, err := runLogin(ctx, baseURL, password, os.Stdout, nil); err != nil {
			die(err)
		}
	case "scope":
		dispatchScope(ctx, c, os.Args[2:])
	case "scan":
		dispatchScan(ctx, c, os.Args[2:])
	case "hosts":
		dispatchHosts(ctx, c, os.Args[2:])
	case "agent":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "usage: reconautctl agent <prompt>")
			os.Exit(2)
		}
		if err := runAgentChat(ctx, c, os.Stdout, os.Args[2]); err != nil {
			die(err)
		}
	case "doctor":
		if err := runDoctor(ctx, c, os.Stdout); err != nil {
			die(err)
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n", os.Args[1])
		os.Exit(2)
	}
}

func dispatchScope(ctx context.Context, c *mcp.Client, args []string) {
	if len(args) == 0 {
		args = []string{"list"}
	}
	switch args[0] {
	case "list":
		if err := runScopeList(ctx, c, os.Stdout); err != nil {
			die(err)
		}
	case "add":
		if len(args) < 3 {
			fmt.Fprintln(os.Stderr, "usage: reconautctl scope add <kind> <value>")
			os.Exit(2)
		}
		if err := runScopeAdd(ctx, c, os.Stdout, args[1], args[2]); err != nil {
			die(err)
		}
	case "revoke":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: reconautctl scope revoke <id>")
			os.Exit(2)
		}
		if err := runScopeRevoke(ctx, c, os.Stdout, args[1]); err != nil {
			die(err)
		}
	}
}

func dispatchScan(ctx context.Context, c *mcp.Client, args []string) {
	if len(args) == 0 {
		args = []string{"list"}
	}
	switch args[0] {
	case "list":
		if err := runScanList(ctx, c, os.Stdout); err != nil {
			die(err)
		}
	case "request":
		if len(args) < 4 {
			fmt.Fprintln(os.Stderr, "usage: reconautctl scan request <scan_kind> <target_kind> <target_value>")
			os.Exit(2)
		}
		if err := runScanRequest(ctx, c, os.Stdout, args[1], args[2], args[3]); err != nil {
			die(err)
		}
	case "status":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: reconautctl scan status <scan_id>")
			os.Exit(2)
		}
		if err := runScanStatus(ctx, c, os.Stdout, args[1]); err != nil {
			die(err)
		}
	}
}

func dispatchHosts(ctx context.Context, c *mcp.Client, args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: reconautctl hosts <search|get> ...")
		os.Exit(2)
	}
	switch args[0] {
	case "search":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: reconautctl hosts search <query>")
			os.Exit(2)
		}
		if err := runHostsSearch(ctx, c, os.Stdout, args[1], 0); err != nil {
			die(err)
		}
	case "get":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: reconautctl hosts get <host_id>")
			os.Exit(2)
		}
		if err := runHostsGet(ctx, c, os.Stdout, args[1]); err != nil {
			die(err)
		}
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func die(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
