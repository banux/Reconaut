import { describe, it, expect, vi, beforeEach } from "vitest";
import { mount, flushPromises } from "@vue/test-utils";
import ScopesPanel from "./ScopesPanel.vue";
import { ApiError } from "../api/client.js";

function makeScopesClient(impl = {}) {
  return {
    list: vi.fn(impl.list ?? (async () => [])),
    create: vi.fn(impl.create ?? (async (s) => ({ id: "new", ...s }))),
    revoke: vi.fn(impl.revoke ?? (async () => true)),
  };
}

beforeEach(() => {
  // confirm() est utilise par le composant pour la revocation.
  globalThis.confirm = vi.fn(() => true);
});

describe("ScopesPanel", () => {
  it("affiche un message vide quand le backend renvoie []", async () => {
    const scopesClient = makeScopesClient();
    const wrapper = mount(ScopesPanel, { props: { scopesClient } });
    await flushPromises();

    expect(scopesClient.list).toHaveBeenCalled();
    expect(wrapper.text()).toMatch(/Aucun scope declare/);
  });

  it("liste les scopes existants avec un bouton revoquer par entree", async () => {
    const scopesClient = makeScopesClient({
      list: async () => [
        { id: "s1", kind: "domain", value: "example.fr" },
        { id: "s2", kind: "ip", value: "192.0.2.1" },
      ],
    });
    const wrapper = mount(ScopesPanel, { props: { scopesClient } });
    await flushPromises();

    const list = wrapper.find("[data-testid='scopes-list']");
    expect(list.text()).toContain("example.fr");
    expect(list.text()).toContain("192.0.2.1");
    expect(wrapper.find("[data-testid='revoke-s1']").exists()).toBe(true);
    expect(wrapper.find("[data-testid='revoke-s2']").exists()).toBe(true);
  });

  it("ajoute un scope via le formulaire et rafraichit la liste", async () => {
    let listed = [];
    const scopesClient = makeScopesClient({
      list: async () => [...listed],
      create: async (body) => {
        listed = [{ id: "new", ...body }];
        return listed[0];
      },
    });
    const wrapper = mount(ScopesPanel, { props: { scopesClient } });
    await flushPromises();

    await wrapper.find("[data-testid='scope-value']").setValue("example.fr");
    await wrapper.find("form").trigger("submit.prevent");
    await flushPromises();

    expect(scopesClient.create).toHaveBeenCalledWith({ kind: "domain", value: "example.fr" });
    expect(wrapper.text()).toContain("example.fr");
  });

  it("revoque un scope apres confirmation", async () => {
    let listed = [{ id: "s1", kind: "ip", value: "192.0.2.1" }];
    const scopesClient = makeScopesClient({
      list: async () => [...listed],
      revoke: async () => {
        listed = [];
        return true;
      },
    });
    const wrapper = mount(ScopesPanel, { props: { scopesClient } });
    await flushPromises();

    await wrapper.find("[data-testid='revoke-s1']").trigger("click");
    await flushPromises();

    expect(globalThis.confirm).toHaveBeenCalled();
    expect(scopesClient.revoke).toHaveBeenCalledWith("s1");
    expect(wrapper.text()).toMatch(/Aucun scope declare/);
  });

  it("ne revoque pas si l'utilisateur annule la confirmation", async () => {
    globalThis.confirm = vi.fn(() => false);
    const scopesClient = makeScopesClient({
      list: async () => [{ id: "s1", kind: "ip", value: "192.0.2.1" }],
    });
    const wrapper = mount(ScopesPanel, { props: { scopesClient } });
    await flushPromises();

    await wrapper.find("[data-testid='revoke-s1']").trigger("click");
    await flushPromises();

    expect(scopesClient.revoke).not.toHaveBeenCalled();
  });

  it("affiche un code d'erreur quand list echoue avec une ApiError", async () => {
    const scopesClient = makeScopesClient({
      list: async () => {
        throw new ApiError({ status: 500, code: "db_unavailable", body: null });
      },
    });
    const wrapper = mount(ScopesPanel, { props: { scopesClient } });
    await flushPromises();

    expect(wrapper.text()).toContain("db_unavailable");
  });
});
