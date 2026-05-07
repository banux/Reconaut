// Client de gestion des scopes d'autorisation.
//
// Source de verite : openspec/changes/init-reconaut-platform/tasks.md
// section 2.4 ("Endpoints POST /scopes, DELETE /scopes/{id}. Toute
// mutation ecrit une ligne d'audit. UI Vue minimale pour lister, ajouter
// et revoquer.")

import { ApiClient } from "./client.js";

export class ScopesClient {
  constructor({ apiClient } = {}) {
    this.apiClient = apiClient ?? new ApiClient();
  }

  async list() {
    const payload = await this.apiClient.get("/scopes");
    return Array.isArray(payload?.scopes) ? payload.scopes : [];
  }

  async create({ kind, value }) {
    if (!kind || !value) {
      throw new Error("kind and value are required");
    }
    const payload = await this.apiClient.post("/scopes", { kind, value });
    return payload?.scope ?? null;
  }

  async revoke(id) {
    if (!id) throw new Error("id is required");
    await this.apiClient.delete(`/scopes/${encodeURIComponent(id)}`);
    return true;
  }
}
