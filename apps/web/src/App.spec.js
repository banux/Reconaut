// Smoke test du shell applicatif. Doit passer en isolation des
// composants enfants (qui ont leurs propres specs).

import { describe, it, expect, vi } from "vitest";
import { mount } from "@vue/test-utils";
import App from "./App.vue";

// Stubs pour les enfants : pas besoin de tester ici les API calls reels,
// chaque composant a son propre fichier spec.
vi.mock("./components/AgentChat.vue", () => ({
  default: { name: "AgentChat", template: "<div data-testid='agent-chat-stub'/>" },
}));
vi.mock("./components/ScopesPanel.vue", () => ({
  default: { name: "ScopesPanel", template: "<div data-testid='scopes-panel-stub'/>" },
}));

describe("App", () => {
  it("monte HomeView avec le titre Reconaut et les deux panneaux", () => {
    const wrapper = mount(App);
    expect(wrapper.text()).toContain("Reconaut");
    expect(wrapper.find("[data-testid='agent-chat-stub']").exists()).toBe(true);
    expect(wrapper.find("[data-testid='scopes-panel-stub']").exists()).toBe(true);
  });
});
