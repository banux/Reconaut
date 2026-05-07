// Smoke test - satisfait le critere "chaque suite contient un test smoke
// trivial qui passe" de add-tech-stack tasks 2.1.

import { describe, it, expect } from "vitest";
import { mount } from "@vue/test-utils";
import App from "./App.vue";

describe("App", () => {
  it("mounts and renders the bootstrap label", () => {
    const wrapper = mount(App);
    expect(wrapper.text()).toContain("Reconaut bootstrap");
  });
});
