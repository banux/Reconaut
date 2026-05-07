// Wrapper minimal autour de fetch.
//
// Source de verite : openspec/changes/init-reconaut-platform/specs/agent-interface/spec.md
// + openspec/changes/init-reconaut-platform/specs/platform/spec.md (auth
// local-first via session ou cle API personnelle).
//
// Conventions :
//  - Toujours envoyer credentials: "include" pour permettre la session.
//  - Permettre un override d'API key via VITE_RECONAUT_API_KEY (utile en
//    dev et en CI).
//  - Normaliser les erreurs reseau et 4xx/5xx en une exception unique
//    `ApiError(status, code, body)` que les composants peuvent catcher.

export class ApiError extends Error {
  constructor({ status, code, body, message }) {
    super(message ?? `api error: ${status} ${code ?? ""}`.trim());
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.body = body;
  }
}

// Construit l'origine API. En dev, Vite proxie vers le backend Rails ;
// en prod le frontend est servi par le meme origin que l'API. On expose
// un override pour les tests (passage de baseURL au constructeur).
export function defaultBaseUrl() {
  return import.meta.env?.VITE_RECONAUT_API_BASE ?? "";
}

export class ApiClient {
  constructor({ baseUrl = defaultBaseUrl(), apiKey, fetchImpl } = {}) {
    this.baseUrl = baseUrl;
    this.apiKey = apiKey ?? import.meta.env?.VITE_RECONAUT_API_KEY ?? null;
    this.fetchImpl = fetchImpl ?? globalThis.fetch.bind(globalThis);
  }

  async request(path, { method = "GET", body, headers = {}, signal } = {}) {
    const finalHeaders = { Accept: "application/json", ...headers };
    if (this.apiKey) finalHeaders.Authorization = `Bearer ${this.apiKey}`;
    if (body !== undefined) finalHeaders["Content-Type"] = "application/json";

    let response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method,
        credentials: "include",
        headers: finalHeaders,
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal,
      });
    } catch (err) {
      throw new ApiError({
        status: 0,
        code: "network_error",
        message: err?.message ?? "network unreachable",
        body: null,
      });
    }

    // 204 No Content -> renvoie null sans tenter de parser.
    if (response.status === 204) return null;

    const text = await response.text();
    let parsed = null;
    if (text.length > 0) {
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = { raw: text };
      }
    }

    if (!response.ok) {
      throw new ApiError({
        status: response.status,
        code: parsed?.error ?? `http_${response.status}`,
        body: parsed,
      });
    }
    return parsed;
  }

  get(path, opts) {
    return this.request(path, { ...opts, method: "GET" });
  }

  post(path, body, opts) {
    return this.request(path, { ...opts, method: "POST", body });
  }

  delete(path, opts) {
    return this.request(path, { ...opts, method: "DELETE" });
  }
}
