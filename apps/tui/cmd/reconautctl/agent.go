// SPDX-License-Identifier: AGPL-3.0-only
// Sous-commande `reconautctl agent` : invoque agent_chat en streaming
// SSE. Chaque chunk reçu est rendu au fur et à mesure.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/banux/Reconaut/apps/tui/internal/mcp"
)

func runAgentChat(ctx context.Context, c *mcp.Client, out io.Writer, prompt string) error {
	chunks, err := c.InvokeStreaming(ctx, "agent_chat", map[string]any{"prompt": prompt})
	if err != nil {
		return err
	}
	for chunk := range chunks {
		b, _ := json.Marshal(chunk.Result)
		fmt.Fprintf(out, "[%s] %s\n", typeOf(chunk), b)
	}
	return nil
}

func typeOf(c mcp.Chunk) string {
	if t, ok := c.Result["type"].(string); ok {
		return t
	}
	return "chunk"
}
