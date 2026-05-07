import { describe, it, expect, vi } from "vitest";
import { ApiClient, ApiError } from "./client.js";

function fakeFetch(responses) {
  // responses : Array<{ status, body, ok? }> - une reponse par appel.
  let i = 0;
  return vi.fn(async () => {
    const r = responses[i++] ?? responses[responses.length - 1];
    return {
      ok: r.ok ?? (r.status >= 200 && r.status < 300),
      status: r.status,
      text: async () => (r.body == null ? "" : JSON.stringify(r.body)),
    };
  });
}

describe("ApiClient", () => {
  it("envoie Accept et Authorization quand une apiKey est fournie", async () => {
    const f = fakeFetch([{ status: 200, body: { ok: true } }]);
    const client = new ApiClient({ baseUrl: "http://x", apiKey: "k1", fetchImpl: f });
    await client.get("/foo");

    const [, opts] = f.mock.calls[0];
    expect(opts.headers.Accept).toBe("application/json");
    expect(opts.headers.Authorization).toBe("Bearer k1");
    expect(opts.credentials).toBe("include");
  });

  it("serialise le body en JSON et pose Content-Type", async () => {
    const f = fakeFetch([{ status: 200, body: { ok: true } }]);
    const client = new ApiClient({ baseUrl: "", fetchImpl: f });
    await client.post("/agent/chat", { query: "hi" });

    const [, opts] = f.mock.calls[0];
    expect(opts.method).toBe("POST");
    expect(opts.headers["Content-Type"]).toBe("application/json");
    expect(opts.body).toBe('{"query":"hi"}');
  });

  it("retourne null sur 204 No Content", async () => {
    const f = fakeFetch([{ status: 204, body: null }]);
    const client = new ApiClient({ fetchImpl: f });
    const result = await client.delete("/scopes/abc");
    expect(result).toBe(null);
  });

  it("leve ApiError sur 4xx avec le code structure du body", async () => {
    const f = fakeFetch([{ status: 403, body: { error: "rbac_forbidden" } }]);
    const client = new ApiClient({ fetchImpl: f });

    await expect(client.get("/agent/chat")).rejects.toMatchObject({
      name: "ApiError",
      status: 403,
      code: "rbac_forbidden",
    });
  });

  it("leve ApiError network_error quand fetch throw", async () => {
    const f = vi.fn(async () => {
      throw new TypeError("Failed to fetch");
    });
    const client = new ApiClient({ fetchImpl: f });

    await expect(client.get("/agent/chat")).rejects.toMatchObject({
      name: "ApiError",
      status: 0,
      code: "network_error",
    });
  });

  it("propage le body parse meme sur 200 sans Content-Type", async () => {
    const f = fakeFetch([{ status: 200, body: { rows: [{ host_id: "h1" }] } }]);
    const client = new ApiClient({ fetchImpl: f });
    const result = await client.get("/foo");
    expect(result.rows[0].host_id).toBe("h1");
  });

  it("ApiError est instance de Error et de ApiError", () => {
    const err = new ApiError({ status: 500, code: "x", body: null });
    expect(err).toBeInstanceOf(Error);
    expect(err).toBeInstanceOf(ApiError);
  });
});
