// Client de l'agent conversationnel.
//
// Source de verite :
//   openspec/changes/init-reconaut-platform/specs/agent-interface/spec.md
//   openspec/changes/add-graph-retrieval/specs/agent-interface/spec.md
//
// Le contrat de reponse expose : rows, citations, warnings,
// retrieval_path. L'endpoint reel est sous /agent/chat (encore a
// implementer cote Rails) ; cette fonction encapsule le shape pour que
// les composants Vue ne fassent pas leurs propres calls fetch.

import { ApiClient } from "./client.js";

export class AgentClient {
  constructor({ apiClient } = {}) {
    this.apiClient = apiClient ?? new ApiClient();
  }

  async chat(query, { signal } = {}) {
    if (typeof query !== "string" || query.trim().length === 0) {
      throw new Error("query must be a non-empty string");
    }
    const payload = await this.apiClient.post("/agent/chat", { query }, { signal });

    return {
      rows: Array.isArray(payload?.rows) ? payload.rows : [],
      citations: Array.isArray(payload?.citations) ? payload.citations : [],
      warnings: Array.isArray(payload?.warnings) ? payload.warnings : [],
      retrievalPath: payload?.retrieval_path ?? "none",
      durationMs: payload?.duration_ms ?? null,
    };
  }
}
