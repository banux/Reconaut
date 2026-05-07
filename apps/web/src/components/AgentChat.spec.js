import { describe, it, expect, vi } from "vitest";
import { mount, flushPromises } from "@vue/test-utils";
import AgentChat from "./AgentChat.vue";
import { ApiError } from "../api/client.js";

function makeAgentClient(impl) {
  return { chat: vi.fn(impl) };
}

describe("AgentChat", () => {
  it("envoie la requete au client et affiche le retour hybride", async () => {
    const agentClient = makeAgentClient(async () => ({
      rows: [{ host_id: "h1", scanned_at: "2026-05-01" }],
      citations: [{ host_id: "h1", scanned_at: "2026-05-01" }],
      warnings: [],
      retrievalPath: "hybrid",
      durationMs: 42,
    }));

    const wrapper = mount(AgentChat, { props: { agentClient } });
    await wrapper.find("[data-testid='query-input']").setValue("hotes nginx");
    await wrapper.find("form").trigger("submit.prevent");
    await flushPromises();

    expect(agentClient.chat).toHaveBeenCalledWith("hotes nginx");
    const messages = wrapper.find("[data-testid='messages']");
    expect(messages.text()).toContain("hotes nginx"); // user message
    expect(messages.text()).toContain("vectoriel + graphe"); // path label
    expect(messages.text()).toContain("h1"); // row
    expect(messages.text()).toContain("(42 ms)");
  });

  it("affiche les warnings quand le graphe est down", async () => {
    const agentClient = makeAgentClient(async () => ({
      rows: [{ host_id: "h1" }],
      citations: [],
      warnings: ["graph_unavailable"],
      retrievalPath: "vector",
      durationMs: 10,
    }));

    const wrapper = mount(AgentChat, { props: { agentClient } });
    await wrapper.find("[data-testid='query-input']").setValue("partage cert");
    await wrapper.find("form").trigger("submit.prevent");
    await flushPromises();

    const warnings = wrapper.find("[data-testid='warnings']");
    expect(warnings.exists()).toBe(true);
    expect(warnings.text()).toContain("graph_unavailable");
  });

  it("affiche un message explicite sur ensemble vide", async () => {
    const agentClient = makeAgentClient(async () => ({
      rows: [],
      citations: [],
      warnings: [],
      retrievalPath: "none",
      durationMs: 5,
    }));

    const wrapper = mount(AgentChat, { props: { agentClient } });
    await wrapper.find("[data-testid='query-input']").setValue("requete vague");
    await wrapper.find("form").trigger("submit.prevent");
    await flushPromises();

    expect(wrapper.text()).toMatch(/Aucun hote n'a matche/);
  });

  it("transforme une ApiError en message d'erreur structure (pas de crash)", async () => {
    const agentClient = makeAgentClient(async () => {
      throw new ApiError({ status: 403, code: "rbac_forbidden", body: null });
    });

    const wrapper = mount(AgentChat, { props: { agentClient } });
    await wrapper.find("[data-testid='query-input']").setValue("test");
    await wrapper.find("form").trigger("submit.prevent");
    await flushPromises();

    expect(wrapper.text()).toContain("rbac_forbidden");
  });

  it("ignore les soumissions avec une requete vide ou pendant un envoi en cours", async () => {
    const agentClient = makeAgentClient(async () => {
      // Bloque la promesse pour simuler un envoi en cours.
      await new Promise((resolve) => setTimeout(resolve, 50));
      return { rows: [], citations: [], warnings: [], retrievalPath: "none", durationMs: 0 };
    });

    const wrapper = mount(AgentChat, { props: { agentClient } });
    // Vide -> ne soumet pas.
    await wrapper.find("form").trigger("submit.prevent");
    expect(agentClient.chat).not.toHaveBeenCalled();

    // Premier envoi.
    await wrapper.find("[data-testid='query-input']").setValue("a");
    await wrapper.find("form").trigger("submit.prevent");
    // Deuxieme envoi pendant que le premier est inflight.
    await wrapper.find("[data-testid='query-input']").setValue("b");
    await wrapper.find("form").trigger("submit.prevent");

    await flushPromises();
    // L'input est disabled pendant inflight, le second submit est ignore.
    expect(agentClient.chat).toHaveBeenCalledTimes(1);
  });

  it("expose les citations dans une section repliable", async () => {
    const agentClient = makeAgentClient(async () => ({
      rows: [{ host_id: "h1" }, { host_id: "h2" }],
      citations: [
        { host_id: "h1", scanned_at: "2026-05-01" },
        { host_id: "h2", scanned_at: "2026-05-02" },
      ],
      warnings: [],
      retrievalPath: "graph",
      durationMs: 30,
    }));

    const wrapper = mount(AgentChat, { props: { agentClient } });
    await wrapper.find("[data-testid='query-input']").setValue("voisinage");
    await wrapper.find("form").trigger("submit.prevent");
    await flushPromises();

    const citations = wrapper.findAll("[data-testid='citation']");
    expect(citations).toHaveLength(2);
    expect(citations[0].text()).toContain("h1");
  });
});
