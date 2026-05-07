<script setup>
import { ref, reactive } from "vue";
import { AgentClient } from "../api/agent.js";
import { ApiError } from "../api/client.js";

const props = defineProps({
  agentClient: {
    type: Object,
    default: () => new AgentClient(),
  },
});

const query = ref("");
const messages = reactive([]); // { role, query?, response?, error? }
const inflight = ref(false);

async function send() {
  const text = query.value.trim();
  if (!text || inflight.value) return;

  const messageIndex = messages.push({ role: "user", query: text }) - 1;
  query.value = "";
  inflight.value = true;

  try {
    const response = await props.agentClient.chat(text);
    messages.push({ role: "agent", response });
  } catch (err) {
    const isApi = err instanceof ApiError;
    messages.push({
      role: "agent",
      error: {
        code: isApi ? err.code : "client_error",
        message: err?.message ?? "erreur inconnue",
        status: isApi ? err.status : null,
      },
    });
  } finally {
    inflight.value = false;
  }

  // Reference messageIndex pour eviter le warning lint sur variable inutilisee.
  void messageIndex;
}

function pathLabel(path) {
  return {
    hybrid: "vectoriel + graphe",
    graph: "graphe",
    vector: "vectoriel",
    none: "aucun resultat",
  }[path] ?? path;
}
</script>

<template>
  <section class="agent-chat" aria-label="Agent conversationnel Reconaut">
    <ol class="agent-chat__messages" data-testid="messages">
      <li
        v-for="(m, i) in messages"
        :key="i"
        :class="['agent-chat__message', `agent-chat__message--${m.role}`]"
      >
        <template v-if="m.role === 'user'">
          <p class="agent-chat__query">{{ m.query }}</p>
        </template>

        <template v-else-if="m.error">
          <p class="agent-chat__error" role="alert">
            Erreur ({{ m.error.code }}) : {{ m.error.message }}
          </p>
        </template>

        <template v-else>
          <p class="agent-chat__path">
            Chemin de recherche : <strong>{{ pathLabel(m.response.retrievalPath) }}</strong>
            <span v-if="m.response.durationMs !== null">
              ({{ m.response.durationMs }} ms)
            </span>
          </p>

          <ul
            v-if="m.response.warnings.length"
            class="agent-chat__warnings"
            role="status"
            data-testid="warnings"
          >
            <li v-for="w in m.response.warnings" :key="w">{{ w }}</li>
          </ul>

          <p
            v-if="m.response.rows.length === 0 && !m.response.warnings.length"
            class="agent-chat__empty"
          >
            Aucun hote n'a matche cette requete.
          </p>

          <ol v-if="m.response.rows.length" class="agent-chat__rows">
            <li v-for="(row, ri) in m.response.rows" :key="ri">
              <code>{{ row.host_id ?? row.id ?? "?" }}</code>
              <span v-if="row.scanned_at" class="agent-chat__scanned-at">
                ({{ row.scanned_at }})
              </span>
            </li>
          </ol>

          <details v-if="m.response.citations.length" class="agent-chat__citations">
            <summary>{{ m.response.citations.length }} citation(s)</summary>
            <ul>
              <li
                v-for="(c, ci) in m.response.citations"
                :key="ci"
                data-testid="citation"
              >
                {{ c.host_id }}
                <span v-if="c.scanned_at">- {{ c.scanned_at }}</span>
              </li>
            </ul>
          </details>
        </template>
      </li>
    </ol>

    <form class="agent-chat__form" @submit.prevent="send">
      <label for="agent-query" class="agent-chat__label">
        Posez une question sur votre perimetre d'actifs
      </label>
      <input
        id="agent-query"
        v-model="query"
        type="text"
        autocomplete="off"
        :disabled="inflight"
        data-testid="query-input"
      />
      <button
        type="submit"
        :disabled="inflight || !query.trim()"
        data-testid="send-button"
      >
        {{ inflight ? "Envoi..." : "Envoyer" }}
      </button>
    </form>
  </section>
</template>
