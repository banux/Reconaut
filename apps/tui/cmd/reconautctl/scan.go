// Sous-commande `reconautctl scan` : invoque request_scan / list_scans
// / get_scan_status. Routes : /mcp/* uniquement.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/banux/Reconaut/apps/tui/internal/mcp"
)

func runScanRequest(ctx context.Context, c *mcp.Client, out io.Writer, scanKind, targetKind, targetValue string) error {
	res, err := c.Invoke(ctx, "request_scan", map[string]any{
		"scan_kind":    scanKind,
		"target_kind":  targetKind,
		"target_value": targetValue,
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "scan_id=%v\n", res.Result["scan_id"])
	return nil
}

func runScanList(ctx context.Context, c *mcp.Client, out io.Writer) error {
	res, err := c.Invoke(ctx, "list_scans", map[string]any{})
	if err != nil {
		return err
	}
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(res.Result)
}

func runScanStatus(ctx context.Context, c *mcp.Client, out io.Writer, scanID string) error {
	res, err := c.Invoke(ctx, "get_scan_status", map[string]any{"scan_id": scanID})
	if err != nil {
		return err
	}
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(res.Result)
}
