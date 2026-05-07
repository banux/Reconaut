import { describe, it, expect, vi, beforeEach } from "vitest";
import { AuthClient } from "./auth.js";

function fakeApiClient(overrides = {}) {
  return {
    apiKey: null,
    post: vi.fn(overrides.post ?? (async (_path, body) => ({
      user: { id: "u1", email: body.email, role: "owner" },
      api_key: { id: "k1", token: "raw-token", prefix: "raw-toke" },
    }))),
  };
}

function memoryStorage() {
  const map = new Map();
  return {
    getItem: vi.fn((k) => (map.has(k) ? map.get(k) : null)),
    setItem: vi.fn((k, v) => map.set(k, v)),
    removeItem: vi.fn((k) => map.delete(k)),
    raw: map,
  };
}

beforeEach(() => globalThis.sessionStorage?.clear?.());

describe("AuthClient", () => {
  describe("login", () => {
    it("poste vers /auth/sessions et persiste la session", async () => {
      const apiClient = fakeApiClient();
      const storage = memoryStorage();
      const auth = new AuthClient({ apiClient, storage });

      const session = await auth.login({ email: "owner@x.y", password: "p" });

      expect(apiClient.post).toHaveBeenCalledWith("/auth/sessions", {
        email: "owner@x.y",
        password: "p",
      });
      expect(session.user.email).toEqual("owner@x.y");
      expect(session.apiKey).toEqual("raw-token");
      expect(storage.setItem).toHaveBeenCalled();
      expect(apiClient.apiKey).toEqual("raw-token");
    });

    it("rejette une reponse malformee (pas de user/api_key)", async () => {
      const apiClient = fakeApiClient({ post: async () => ({}) });
      const auth = new AuthClient({ apiClient, storage: memoryStorage() });
      await expect(auth.login({ email: "a@b.c", password: "p" }))
        .rejects.toThrow(/malformed login response/);
    });
  });

  describe("restore", () => {
    it("renvoie null si aucune session en storage" , () => {
      const apiClient = fakeApiClient();
      const auth = new AuthClient({ apiClient, storage: memoryStorage() });
      expect(auth.restore()).toBe(null);
    });

    it("restaure la session et configure l'apiKey du client" , () => {
      const storage = memoryStorage();
      storage.setItem("reconaut.session.v1", JSON.stringify({
        user: { email: "a@b.c", role: "analyst" },
        apiKey: "tk",
      }));
      const apiClient = fakeApiClient();
      const auth = new AuthClient({ apiClient, storage });

      const session = auth.restore();
      expect(session.user.email).toBe("a@b.c");
      expect(apiClient.apiKey).toBe("tk");
    });

    it("nettoie le storage si le contenu est corrompu", () => {
      const storage = memoryStorage();
      storage.setItem("reconaut.session.v1", "not json");
      const apiClient = fakeApiClient();
      const auth = new AuthClient({ apiClient, storage });

      expect(auth.restore()).toBe(null);
      expect(storage.removeItem).toHaveBeenCalledWith("reconaut.session.v1");
    });
  });

  describe("logout", () => {
    it("supprime la session du storage et de l'apiClient", () => {
      const storage = memoryStorage();
      storage.setItem("reconaut.session.v1", "x");
      const apiClient = fakeApiClient();
      apiClient.apiKey = "tk";
      const auth = new AuthClient({ apiClient, storage });

      auth.logout();
      expect(storage.removeItem).toHaveBeenCalled();
      expect(apiClient.apiKey).toBe(null);
    });
  });
});
