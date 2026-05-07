// Client de l'auth locale.
//
// Source de verite : init-reconaut-platform section 7.2 et les routes
// /auth/sessions / /auth/api_keys cote Rails (apps/api/config/routes.rb).
//
// Le token brut n'est renvoye QU'UNE seule fois par le backend a la
// creation. Cote frontend on le persiste dans sessionStorage (pas
// localStorage : on veut qu'il disparaisse a la fermeture de l'onglet).

import { ApiClient } from "./client.js";

const STORAGE_KEY = "reconaut.session.v1";

export class AuthClient {
  constructor({ apiClient, storage } = {}) {
    this.apiClient = apiClient ?? new ApiClient();
    this.storage = storage ?? defaultStorage();
  }

  // Login email + password : enregistre la session (user + api_key) et
  // configure le client API pour envoyer Authorization Bearer.
  async login({ email, password }) {
    const payload = await this.apiClient.post("/auth/sessions", { email, password });
    const session = {
      user: payload?.user ?? null,
      apiKey: payload?.api_key?.token ?? null,
      apiKeyId: payload?.api_key?.id ?? null,
      apiKeyPrefix: payload?.api_key?.prefix ?? null,
    };
    if (!session.user || !session.apiKey) {
      throw new Error("malformed login response");
    }
    this.persist(session);
    this.apiClient.apiKey = session.apiKey;
    return session;
  }

  // Restore session depuis le storage. Si une session est presente, met
  // a jour apiClient.apiKey et renvoie l'objet session.
  restore() {
    const raw = this.storage.getItem(STORAGE_KEY);
    if (!raw) return null;
    try {
      const session = JSON.parse(raw);
      if (session?.apiKey) {
        this.apiClient.apiKey = session.apiKey;
      }
      return session;
    } catch {
      this.storage.removeItem(STORAGE_KEY);
      return null;
    }
  }

  logout() {
    this.storage.removeItem(STORAGE_KEY);
    this.apiClient.apiKey = null;
  }

  persist(session) {
    this.storage.setItem(STORAGE_KEY, JSON.stringify(session));
  }
}

function defaultStorage() {
  if (typeof globalThis.sessionStorage !== "undefined") {
    return globalThis.sessionStorage;
  }
  // Fallback in-memory pour SSR ou tests sans jsdom.
  const map = new Map();
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, v),
    removeItem: (k) => map.delete(k),
  };
}
