import { describe, it, expect, vi } from "vitest";
import { AgentClient } from "./agent.js";

function fakeApiClient(payload) {
  return {
    post: vi.fn(async () => payload),
  };
}

describe("AgentClient", () => {
  it("normalise une reponse hybride complete", async () => {
    const apiClient = fakeApiClient({
      rows: [{ host_id: "h1" }],
      citations: [{ host_id: "h1", scanned_at: "2026-05-01T00:00:00Z" }],
      warnings: [],
      retrieval_path: "hybrid",
      duration_ms: 42,
    });
    const agent = new AgentClient({ apiClient });

    const result = await agent.chat("hotes nginx");
    expect(apiClient.post).toHaveBeenCalledWith(
      "/agent/chat",
      { query: "hotes nginx" },
      { signal: undefined }
    );
    expect(result.rows[0].host_id).toBe("h1");
    expect(result.retrievalPath).toBe("hybrid");
    expect(result.durationMs).toBe(42);
    expect(result.warnings).toEqual([]);
  });

  it("force des tableaux meme quand le backend renvoie des champs manquants", async () => {
    const apiClient = fakeApiClient({});
    const agent = new AgentClient({ apiClient });

    const result = await agent.chat("anything");
    expect(result.rows).toEqual([]);
    expect(result.citations).toEqual([]);
    expect(result.warnings).toEqual([]);
    expect(result.retrievalPath).toBe("none");
  });

  it("rejette une requete vide cote client (n'appelle pas l'API)", async () => {
    const apiClient = fakeApiClient({});
    const agent = new AgentClient({ apiClient });

    await expect(agent.chat("   ")).rejects.toThrow(/non-empty string/);
    expect(apiClient.post).not.toHaveBeenCalled();
  });

  it("propage les warnings tels quels (graph_unavailable, vector_unavailable, ...)", async () => {
    const apiClient = fakeApiClient({
      rows: [{ host_id: "h1" }],
      warnings: ["graph_unavailable"],
      retrieval_path: "vector",
    });
    const agent = new AgentClient({ apiClient });

    const result = await agent.chat("partage cert");
    expect(result.warnings).toEqual(["graph_unavailable"]);
    expect(result.retrievalPath).toBe("vector");
  });
});
