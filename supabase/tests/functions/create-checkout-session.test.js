// MOCKED tests: create-checkout-session (fake Stripe API, fake repository).

import { assertEquals, assertExists, assertStringIncludes } from "jsr:@std/assert@1.0.14";
import { createCheckoutSessionHandler } from "../../functions/create-checkout-session/handler.js";
import { baseDeps, billingContext, fakeRepo, fakeStripe, jsonRequest, ORG_ID, readJson } from "./_helpers.js";

const body = { organization_id: ORG_ID, plan_code: "pro", interval: "month" };

Deno.test("checkout: unauthenticated requests are rejected", async () => {
  const deps = baseDeps();
  const res = await readJson(await createCheckoutSessionHandler(deps)(jsonRequest(body)));
  assertEquals(res.status, 401);
  assertEquals(deps.stripe.calls.length, 0);
});

Deno.test("checkout: anonymous sign-ins are rejected", async () => {
  const res = await createCheckoutSessionHandler(baseDeps())(jsonRequest(body, { token: "anonymous" }));
  assertEquals(res.status, 403);
});

for (const token of ["admin", "member", "outsider"]) {
  Deno.test(`checkout: ${token} cannot start billing for the organization`, async () => {
    const deps = baseDeps();
    const res = await readJson(await createCheckoutSessionHandler(deps)(jsonRequest(body, { token })));
    assertEquals(res.status, 403);
    assertEquals(res.body.error.code, "forbidden");
    assertEquals(deps.stripe.calls.length, 0, "no Stripe call for unauthorized users");
    assertEquals(deps.repo.calls.length, 0, "no billing data read for unauthorized users");
  });
}

Deno.test("checkout: request validation", async () => {
  const handler = createCheckoutSessionHandler(baseDeps());
  for (
    const invalid of [{ ...body, organization_id: "acme" }, { ...body, plan_code: "" }, { ...body, interval: "week" }]
  ) {
    const res = await handler(jsonRequest(invalid, { token: "owner" }));
    assertEquals(res.status, 400, JSON.stringify(invalid));
  }
});

Deno.test("checkout: owner creates customer + session with server-side price, trial and URLs", async () => {
  const deps = baseDeps();
  const malicious = {
    ...body,
    price_id: "price_attacker_free",
    success_url: "https://evil.example/steal",
    trial_period_days: 365,
  };
  const res = await readJson(await createCheckoutSessionHandler(deps)(jsonRequest(malicious, { token: "owner" })));

  assertEquals(res.status, 200);
  assertEquals(res.body.session_id, "cs_test_123");
  assertEquals(res.body.trial_days, 14);

  const [[customerParams, customerOptions]] = deps.stripe.callsTo("customers.create");
  assertEquals(customerParams.metadata.organization_id, ORG_ID);
  assertEquals(customerOptions.idempotencyKey, `organization-customer-${ORG_ID}`);
  assertEquals(deps.repo.callsTo("linkStripeCustomer"), [[ORG_ID, "cus_new123"]]);

  const [[session]] = deps.stripe.callsTo("checkout.sessions.create");
  assertEquals(session.mode, "subscription");
  assertEquals(session.customer, "cus_new123");
  assertEquals(session.client_reference_id, ORG_ID);
  assertEquals(session.line_items, [{ price: "price_pro_monthly", quantity: 1 }]);
  assertEquals(session.subscription_data.trial_period_days, 14);
  assertEquals(session.subscription_data.metadata.organization_id, ORG_ID);
  assertStringIncludes(session.success_url, "https://app.example.test/billing/success");
  assertEquals(session.cancel_url, "https://app.example.test/billing/cancelled");
});

Deno.test("checkout: does not grant entitlements (no subscription state written)", async () => {
  const deps = baseDeps();
  await createCheckoutSessionHandler(deps)(jsonRequest(body, { token: "owner" }));
  assertEquals(deps.repo.callsTo("applySubscription").length, 0);
  const [[audit]] = deps.repo.callsTo("recordAuditEvent");
  assertEquals(audit.action, "billing.checkout_session_created");
  assertEquals(audit.actorType, "user");
});

Deno.test("checkout: reuses the organization's existing Stripe customer", async () => {
  const deps = baseDeps({
    repo: fakeRepo({ getBillingContext: () => billingContext({ stripe_customer_id: "cus_acme" }) }),
  });
  const res = await createCheckoutSessionHandler(deps)(jsonRequest(body, { token: "owner" }));
  assertEquals(res.status, 200);
  assertEquals(deps.stripe.callsTo("customers.create").length, 0);
  assertEquals(deps.stripe.callsTo("checkout.sessions.create")[0][0].customer, "cus_acme");
});

Deno.test("checkout: only one free trial per organization", async () => {
  const deps = baseDeps({
    repo: fakeRepo({
      getBillingContext: () => billingContext({ stripe_customer_id: "cus_acme", trial_eligible: false }),
    }),
  });
  const res = await readJson(await createCheckoutSessionHandler(deps)(jsonRequest(body, { token: "owner" })));
  assertEquals(res.body.trial_days, 0);
  assertEquals(deps.stripe.callsTo("checkout.sessions.create")[0][0].subscription_data.trial_period_days, undefined);
});

Deno.test("checkout: unknown plan/interval is rejected", async () => {
  const deps = baseDeps({ repo: fakeRepo({ getBillingContext: () => billingContext({ price: null }) }) });
  const res = await readJson(await createCheckoutSessionHandler(deps)(jsonRequest(body, { token: "owner" })));
  assertEquals(res.status, 400);
  assertEquals(res.body.error.code, "unknown_plan");
});

Deno.test("checkout: an existing subscription must be changed, not duplicated", async () => {
  const deps = baseDeps({
    repo: fakeRepo({
      getBillingContext: () =>
        billingContext({ current_subscription: { stripe_subscription_id: "sub_123", status: "active" } }),
    }),
  });
  const res = await readJson(await createCheckoutSessionHandler(deps)(jsonRequest(body, { token: "owner" })));
  assertEquals(res.status, 409);
  assertEquals(res.body.error.code, "subscription_exists");
  assertEquals(deps.stripe.calls.length, 0);
});

Deno.test("checkout: Stripe failures return a generic 502 without provider details", async () => {
  const deps = baseDeps({
    stripe: fakeStripe({
      "customers.create": () => {
        const err = new Error("Invalid API Key provided: sk_live_****abcd");
        err.type = "StripeAuthenticationError";
        throw err;
      },
    }),
  });
  const res = await readJson(await createCheckoutSessionHandler(deps)(jsonRequest(body, { token: "owner" })));
  assertEquals(res.status, 502);
  assertEquals(res.body.error.code, "payment_provider_error");
  assertEquals(JSON.stringify(res.body).includes("sk_live"), false);
  assertExists(res.body.error.message);
});
