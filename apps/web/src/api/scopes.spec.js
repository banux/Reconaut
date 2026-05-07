import { describe, it, expect, vi } from "vitest";
import { ScopesClient } from "./scopes.js";

function fakeApiClient({ list, create, del } = {}) {
  return {
    get: vi.fn(async () => list ?? { scopes: [] }),
    post: vi.fn(async (_path, body) => create?.(body) ?? { scope: { id: "x", ...body } }),
    delete: vi.fn(async () => del ?? null),
  };
}

describe("ScopesClient", () => {
  it("liste retourne un tableau meme si le backend renvoie un objet sans scopes", async () => {
    const apiClient = fakeApiClient({ list: {} });
    const scopes = new ScopesClient({ apiClient });
    expect(await scopes.list()).toEqual([]);
  });

  it("liste deserialise scopes:[...]", async () => {
    const apiClient = fakeApiClient({
      list: { scopes: [{ id: "s1", kind: "domain", value: "example.fr" }] },
    });
    const scopes = new ScopesClient({ apiClient });
    const got = await scopes.list();
    expect(got).toHaveLength(1);
    expect(got[0].kind).toBe("domain");
  });

  it("create poste {kind, value} et renvoie le scope cree", async () => {
    const apiClient = fakeApiClient();
    const scopes = new ScopesClient({ apiClient });
    const created = await scopes.create({ kind: "ip", value: "192.0.2.1" });
    expect(apiClient.post).toHaveBeenCalledWith("/scopes", { kind: "ip", value: "192.0.2.1" });
    expect(created.value).toBe("192.0.2.1");
  });

  it("create rejette si kind ou value est manquant (cote client)", async () => {
    const apiClient = fakeApiClient();
    const scopes = new ScopesClient({ apiClient });
    await expect(scopes.create({})).rejects.toThrow(/required/);
    expect(apiClient.post).not.toHaveBeenCalled();
  });

  it("revoke encode l'id pour les caracteres speciaux et appelle DELETE", async () => {
    const apiClient = fakeApiClient();
    const scopes = new ScopesClient({ apiClient });
    await scopes.revoke("a/b c");
    expect(apiClient.delete).toHaveBeenCalledWith("/scopes/a%2Fb%20c");
  });

  it("revoke rejette un id falsy sans appel reseau", async () => {
    const apiClient = fakeApiClient();
    const scopes = new ScopesClient({ apiClient });
    await expect(scopes.revoke("")).rejects.toThrow(/required/);
    expect(apiClient.delete).not.toHaveBeenCalled();
  });
});
