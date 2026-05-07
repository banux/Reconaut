<script setup>
import AgentChat from "../components/AgentChat.vue";
import ScopesPanel from "../components/ScopesPanel.vue";
</script>

<template>
  <div class="home-view">
    <header class="home-view__header">
      <h1>Reconaut</h1>
      <p>Outil open source d'Attack Surface Management.</p>
    </header>

    <main class="home-view__main">
      <AgentChat />
      <ScopesPanel />
    </main>
  </div>
</template>
