import { describe, it, expect, vi } from "vitest";
import { mount, flushPromises } from "@vue/test-utils";
import LoginForm from "./LoginForm.vue";
import { ApiError } from "../api/client.js";

function makeAuthClient(impl) {
  return { login: vi.fn(impl) };
}

describe("LoginForm", () => {
  it("appelle authClient.login avec email + password et emit logged-in", async () => {
    const session = { user: { email: "a@b.c", role: "owner" }, apiKey: "tk" };
    const authClient = makeAuthClient(async () => session);
    const wrapper = mount(LoginForm, { props: { authClient } });

    await wrapper.find("[data-testid='login-email']").setValue("a@b.c");
    await wrapper.find("[data-testid='login-password']").setValue("hunter2");
    await wrapper.find("form").trigger("submit.prevent");
    await flushPromises();

    expect(authClient.login).toHaveBeenCalledWith({ email: "a@b.c", password: "hunter2" });
    expect(wrapper.emitted()["logged-in"]).toBeTruthy();
    expect(wrapper.emitted()["logged-in"][0][0]).toEqual(session);
  });

  it("affiche le code d'erreur sur ApiError 401" , async () => {
    const authClient = makeAuthClient(async () => {
      throw new ApiError({ status: 401, code: "invalid_credentials", body: null });
    });
    const wrapper = mount(LoginForm, { props: { authClient } });

    await wrapper.find("[data-testid='login-email']").setValue("a@b.c");
    await wrapper.find("[data-testid='login-password']").setValue("wrong");
    await wrapper.find("form").trigger("submit.prevent");
    await flushPromises();

    const err = wrapper.find("[data-testid='login-error']");
    expect(err.exists()).toBe(true);
    expect(err.text()).toContain("invalid_credentials");
    expect(wrapper.emitted()["logged-in"]).toBeFalsy();
  });

  it("ignore les soumissions vides ou pendant un envoi en cours", async () => {
    let resolveLogin;
    const authClient = makeAuthClient(() => new Promise((r) => { resolveLogin = r; }));
    const wrapper = mount(LoginForm, { props: { authClient } });

    // vide -> submit ne fait rien
    await wrapper.find("form").trigger("submit.prevent");
    expect(authClient.login).not.toHaveBeenCalled();

    // premier submit (pendant)
    await wrapper.find("[data-testid='login-email']").setValue("a@b.c");
    await wrapper.find("[data-testid='login-password']").setValue("p");
    await wrapper.find("form").trigger("submit.prevent");

    // pendant l'attente, deuxieme submit -> ignore (button disabled, mais
    // on simule via re-trigger)
    await wrapper.find("form").trigger("submit.prevent");
    expect(authClient.login).toHaveBeenCalledTimes(1);

    resolveLogin({ user: { email: "a@b.c", role: "viewer" }, apiKey: "k" });
    await flushPromises();
  });
});
