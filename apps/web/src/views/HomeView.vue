<script setup>
import { ref, onMounted } from "vue";
import AgentChat from "../components/AgentChat.vue";
import ScopesPanel from "../components/ScopesPanel.vue";
import LoginForm from "../components/LoginForm.vue";
import { ApiClient } from "../api/client.js";
import { AuthClient } from "../api/auth.js";

// Une seule instance d'ApiClient partagee : login() pose Authorization
// Bearer sur ce client, donc les autres composants (AgentChat,
// ScopesPanel) qui font new ApiClient() vont aussi heriter du Bearer
// si on leur injecte ce client. Pour l'instant on les laisse construire
// leur propre client (le Bearer n'est pas encore propage par defaut)
// et on stocke l'apiKey en sessionStorage pour les iterations qui
// connecteront les composants.
const apiClient = new ApiClient();
const authClient = new AuthClient({ apiClient });

const session = ref(null);

onMounted(() => {
  session.value = authClient.restore();
});

function onLoggedIn(s) {
  session.value = s;
}

function onLogout() {
  authClient.logout();
  session.value = null;
}
</script>

<template>
  <div class="home-view">
    <header class="home-view__header">
      <h1>Reconaut</h1>
      <p>Outil open source d'Attack Surface Management.</p>
      <div v-if="session" class="home-view__session" data-testid="session-bar">
        <span>Connecte en tant que {{ session.user.email }} ({{ session.user.role }})</span>
        <button type="button" @click="onLogout" data-testid="logout-button">Deconnexion</button>
      </div>
    </header>

    <main class="home-view__main">
      <template v-if="session">
        <AgentChat />
        <ScopesPanel />
      </template>
      <template v-else>
        <LoginForm :auth-client="authClient" @logged-in="onLoggedIn" />
      </template>
    </main>
  </div>
</template>
