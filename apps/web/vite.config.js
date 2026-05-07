import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

// Cf. openspec/changes/add-tech-stack/specs/architecture/spec.md
// Frontend = Vue 3 + Vite, pas de Nuxt en v1.
export default defineConfig({
  plugins: [vue()],
  test: {
    environment: "jsdom",
    globals: true,
  },
});
