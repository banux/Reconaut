<script setup>
import { ref } from "vue";
import { AuthClient } from "../api/auth.js";
import { ApiError } from "../api/client.js";

const props = defineProps({
  authClient: {
    type: Object,
    default: () => new AuthClient(),
  },
});

const emit = defineEmits(["logged-in"]);

const email = ref("");
const password = ref("");
const submitting = ref(false);
const errorCode = ref(null);

async function submit() {
  if (submitting.value) return;
  if (!email.value.trim() || !password.value) return;
  submitting.value = true;
  errorCode.value = null;
  try {
    const session = await props.authClient.login({
      email: email.value.trim(),
      password: password.value,
    });
    emit("logged-in", session);
    password.value = "";
  } catch (err) {
    errorCode.value = err instanceof ApiError ? err.code : "client_error";
  } finally {
    submitting.value = false;
  }
}
</script>

<template>
  <form class="login-form" @submit.prevent="submit" aria-label="Connexion">
    <h2>Connexion</h2>

    <label>
      Email
      <input
        v-model="email"
        type="email"
        autocomplete="username"
        required
        :disabled="submitting"
        data-testid="login-email"
      />
    </label>

    <label>
      Mot de passe
      <input
        v-model="password"
        type="password"
        autocomplete="current-password"
        required
        :disabled="submitting"
        data-testid="login-password"
      />
    </label>

    <button
      type="submit"
      :disabled="submitting || !email.trim() || !password"
      data-testid="login-submit"
    >
      {{ submitting ? "Connexion..." : "Se connecter" }}
    </button>

    <p
      v-if="errorCode"
      role="alert"
      class="login-form__error"
      data-testid="login-error"
    >
      Echec de connexion ({{ errorCode }}).
    </p>
  </form>
</template>
