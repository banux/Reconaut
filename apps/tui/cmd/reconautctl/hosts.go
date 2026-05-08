// Sous-commande `reconautctl hosts` : invoque search_hosts / get_host.
package main

import (
	"context"
	"encoding/json"
	"io"

	"github.com/banux/Reconaut/apps/tui/internal/mcp"
)

func runHostsSearch(ctx context.Context, c *mcp.Client, out io.Writer, query string, limit int) error {
	params := map[string]any{"query": query}
	if limit > 0 {
		params["limit"] = limit
	}
	res, err := c.Invoke(ctx, "search_hosts", params)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(res.Result)
}

func runHostsGet(ctx context.Context, c *mcp.Client, out io.Writer, hostID string) error {
	res, err := c.Invoke(ctx, "get_host", map[string]any{"host_id": hostID})
	if err != nil {
		return err
	}
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(res.Result)
}
