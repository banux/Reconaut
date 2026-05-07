<script setup>
import { ref, onMounted } from "vue";
import { ScopesClient } from "../api/scopes.js";
import { ApiError } from "../api/client.js";

const props = defineProps({
  scopesClient: {
    type: Object,
    default: () => new ScopesClient(),
  },
});

const scopes = ref([]);
const loadError = ref(null);
const formKind = ref("domain");
const formValue = ref("");
const submitting = ref(false);
const submitError = ref(null);

onMounted(refresh);

async function refresh() {
  loadError.value = null;
  try {
    scopes.value = await props.scopesClient.list();
  } catch (err) {
    loadError.value = err instanceof ApiError ? err.code : "client_error";
  }
}

async function add() {
  const value = formValue.value.trim();
  if (!value || submitting.value) return;
  submitting.value = true;
  submitError.value = null;
  try {
    await props.scopesClient.create({ kind: formKind.value, value });
    formValue.value = "";
    await refresh();
  } catch (err) {
    submitError.value = err instanceof ApiError ? err.code : "client_error";
  } finally {
    submitting.value = false;
  }
}

async function revoke(scope) {
  if (!confirm(`Revoquer le scope ${scope.kind}:${scope.value} ?`)) return;
  try {
    await props.scopesClient.revoke(scope.id);
    await refresh();
  } catch (err) {
    submitError.value = err instanceof ApiError ? err.code : "client_error";
  }
}
</script>

<template>
  <section class="scopes-panel" aria-label="Gestion des scopes d'autorisation">
    <h2>Scopes autorises</h2>

    <p v-if="loadError" role="alert" class="scopes-panel__error">
      Echec du chargement ({{ loadError }}).
    </p>

    <ul v-if="scopes.length" class="scopes-panel__list" data-testid="scopes-list">
      <li v-for="s in scopes" :key="s.id">
        <code>{{ s.kind }}:{{ s.value }}</code>
        <button
          type="button"
          class="scopes-panel__revoke"
          @click="revoke(s)"
          :data-testid="`revoke-${s.id}`"
        >
          Revoquer
        </button>
      </li>
    </ul>
    <p v-else-if="!loadError" class="scopes-panel__empty">
      Aucun scope declare. Reconaut refusera tout scan jusqu'a ce qu'au moins
      un scope soit ajoute.
    </p>

    <form class="scopes-panel__form" @submit.prevent="add">
      <label>
        Type
        <select v-model="formKind" data-testid="scope-kind">
          <option value="domain">domain</option>
          <option value="ip">ip</option>
          <option value="cidr">cidr</option>
          <option value="host">host</option>
        </select>
      </label>
      <label>
        Valeur
        <input
          v-model="formValue"
          type="text"
          required
          autocomplete="off"
          data-testid="scope-value"
        />
      </label>
      <button
        type="submit"
        :disabled="submitting || !formValue.trim()"
        data-testid="scope-submit"
      >
        {{ submitting ? "Ajout..." : "Ajouter" }}
      </button>
      <p v-if="submitError" role="alert" class="scopes-panel__error">
        Echec ({{ submitError }}).
      </p>
    </form>
  </section>
</template>
