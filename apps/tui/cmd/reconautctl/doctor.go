// Sous-commande `reconautctl doctor` : invoque system_doctor.
package main

import (
	"context"
	"encoding/json"
	"io"

	"github.com/banux/Reconaut/apps/tui/internal/mcp"
)

func runDoctor(ctx context.Context, c *mcp.Client, out io.Writer) error {
	res, err := c.Invoke(ctx, "system_doctor", map[string]any{})
	if err != nil {
		return err
	}
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(res.Result)
}
