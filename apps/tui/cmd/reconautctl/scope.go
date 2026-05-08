// Sous-commande `reconautctl scope` : invoque les outils MCP
// list_scopes / add_scope / revoke_scope. Aucune route REST n'est
// appelée — c'est le pacte avec le linter §3.3.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/banux/Reconaut/apps/tui/internal/mcp"
)

func runScopeList(ctx context.Context, c *mcp.Client, out io.Writer) error {
	res, err := c.Invoke(ctx, "list_scopes", map[string]any{})
	if err != nil {
		return err
	}
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(res.Result)
}

func runScopeAdd(ctx context.Context, c *mcp.Client, out io.Writer, kind, value string) error {
	res, err := c.Invoke(ctx, "add_scope", map[string]any{
		"kind":  kind,
		"value": value,
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "ok=%v\n", res.Result["ok"])
	return nil
}

func runScopeRevoke(ctx context.Context, c *mcp.Client, out io.Writer, id string) error {
	res, err := c.Invoke(ctx, "revoke_scope", map[string]any{"id": id})
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "ok=%v\n", res.Result["ok"])
	return nil
}
