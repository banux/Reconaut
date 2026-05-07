// Smoke test du shell applicatif. Doit passer en isolation des
// composants enfants (qui ont leurs propres specs).

import { describe, it, expect, vi, beforeEach } from "vitest";
import { mount, flushPromises } from "@vue/test-utils";
import App from "./App.vue";

vi.mock("./components/AgentChat.vue", () => ({
  default: { name: "AgentChat", template: "<div data-testid='agent-chat-stub'/>" },
}));
vi.mock("./components/ScopesPanel.vue", () => ({
  default: { name: "ScopesPanel", template: "<div data-testid='scopes-panel-stub'/>" },
}));
vi.mock("./components/LoginForm.vue", () => ({
  default: {
    name: "LoginForm",
    template: "<div data-testid='login-form-stub'/>",
  },
}));

beforeEach(() => {
  globalThis.sessionStorage?.clear?.();
});

describe("App", () => {
  it("affiche le LoginForm quand aucune session n'est presente", async () => {
    const wrapper = mount(App);
    await flushPromises();
    expect(wrapper.text()).toContain("Reconaut");
    expect(wrapper.find("[data-testid='login-form-stub']").exists()).toBe(true);
    expect(wrapper.find("[data-testid='agent-chat-stub']").exists()).toBe(false);
  });

  it("affiche les panneaux quand une session est restauree depuis le storage", async () => {
    globalThis.sessionStorage.setItem(
      "reconaut.session.v1",
      JSON.stringify({
        user: { email: "owner@x.y", role: "owner" },
        apiKey: "abc",
      })
    );
    const wrapper = mount(App);
    await flushPromises();
    expect(wrapper.find("[data-testid='agent-chat-stub']").exists()).toBe(true);
    expect(wrapper.find("[data-testid='scopes-panel-stub']").exists()).toBe(true);
    expect(wrapper.find("[data-testid='session-bar']").text()).toContain("owner@x.y");
  });
});
