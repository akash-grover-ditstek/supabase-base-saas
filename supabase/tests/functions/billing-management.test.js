// MOCKED tests: create-billing-portal-session and manage-subscription.

import { assertEquals } from "jsr:@std/assert@1.0.14";
import { createBillingPortalHandler } from "../../functions/create-billing-portal-session/handler.js";
import { createManageSubscriptionHandler } from "../../functions/manage-subscription/handler.js";
import {
  baseDeps,
  billingContext,
  fakeRepo,
  fakeStripe,
  jsonRequest,
  ORG_ID,
  readJson,
  stripeSubscription,
} from "./_helpers.js";

const subscribed = (overrides = {}) =>
  fakeRepo({
    getBillingContext: (_org, planCode) =>
      billingContext({
        stripe_customer_id: "cus_acme",
        current_subscription: { stripe_subscription_id: "sub_123", status: "active", plan_code: "pro" },
        price: planCode === "business"
          ? { stripe_price_id: "price_business_monthly", plan_code: "business", trial_period_days: 14 }
          : planCode === "pro"
          ? { stripe_price_id: "price_pro_monthly", plan_code: "pro", trial_period_days: 14 }
          : null,
        ...overrides,
      }),
  });

// -----------------------------------------------------------------------------
// Billing portal
// -----------------------------------------------------------------------------
Deno.test("portal: owner receives a portal session for the organization's own customer", async () => {
  const deps = baseDeps({ repo: subscribed() });
  const res = await readJson(
    await createBillingPortalHandler(deps)(jsonRequest({ organization_id: ORG_ID }, { token: "owner" })),
  );
  assertEquals(res.status, 200);
  assertEquals(res.body.url, "https://billing.stripe.com/p/session/bps_123");
  const [[params]] = deps.stripe.callsTo("billingPortal.sessions.create");
  assertEquals(params, { customer: "cus_acme", return_url: "https://app.example.test/billing" });
});

Deno.test("portal: admins and outsiders cannot manage billing", async () => {
  for (const token of ["admin", "outsider"]) {
    const deps = baseDeps({ repo: subscribed() });
    const res = await createBillingPortalHandler(deps)(jsonRequest({ organization_id: ORG_ID }, { token }));
    assertEquals(res.status, 403, token);
    assertEquals(deps.stripe.calls.length, 0);
  }
});

Deno.test("portal: organizations without a billing account get 404", async () => {
  const res = await readJson(
    await createBillingPortalHandler(baseDeps())(jsonRequest({ organization_id: ORG_ID }, { token: "owner" })),
  );
  assertEquals(res.status, 404);
  assertEquals(res.body.error.code, "no_billing_account");
});

// -----------------------------------------------------------------------------
// manage-subscription
// -----------------------------------------------------------------------------
Deno.test("manage: upgrade uses the catalog price and pending_if_incomplete", async () => {
  const deps = baseDeps({ repo: subscribed() });
  const res = await readJson(
    await createManageSubscriptionHandler(deps)(
      jsonRequest({ organization_id: ORG_ID, action: "change_plan", plan_code: "business", interval: "month" }, {
        token: "owner",
      }),
    ),
  );
  assertEquals(res.status, 200);
  const [[subscriptionId, params]] = deps.stripe.callsTo("subscriptions.update");
  assertEquals(subscriptionId, "sub_123");
  assertEquals(params.items, [{ id: "si_123", price: "price_business_monthly" }]);
  assertEquals(params.payment_behavior, "pending_if_incomplete");
  const [[applied, observedAt]] = deps.repo.callsTo("applySubscription");
  assertEquals(applied.price_id, "price_business_monthly");
  assertEquals(observedAt.toISOString(), "2025-12-06T05:46:40.000Z");
});

Deno.test("manage: changing to the current plan is rejected", async () => {
  const deps = baseDeps({ repo: subscribed() });
  const res = await readJson(
    await createManageSubscriptionHandler(deps)(
      jsonRequest({ organization_id: ORG_ID, action: "change_plan", plan_code: "pro", interval: "month" }, {
        token: "owner",
      }),
    ),
  );
  assertEquals(res.status, 409);
  assertEquals(res.body.error.code, "already_on_plan");
  assertEquals(deps.stripe.callsTo("subscriptions.update").length, 0);
});

Deno.test("manage: cancel schedules cancellation at period end; resume undoes it", async () => {
  for (const [action, expected] of [["cancel", true], ["resume", false]]) {
    const deps = baseDeps({ repo: subscribed() });
    const res = await readJson(
      await createManageSubscriptionHandler(deps)(jsonRequest({ organization_id: ORG_ID, action }, { token: "owner" })),
    );
    assertEquals(res.status, 200);
    assertEquals(deps.stripe.callsTo("subscriptions.update")[0][1], { cancel_at_period_end: expected });
    assertEquals(res.body.subscription.cancel_at_period_end, expected);
    const audit = deps.repo.callsTo("recordAuditEvent")[0][0];
    assertEquals(audit.action, expected ? "billing.subscription_cancel_requested" : "billing.subscription_resumed");
  }
});

Deno.test("manage: admins cannot change or cancel subscriptions", async () => {
  const deps = baseDeps({ repo: subscribed() });
  const res = await createManageSubscriptionHandler(deps)(
    jsonRequest({ organization_id: ORG_ID, action: "cancel" }, { token: "admin" }),
  );
  assertEquals(res.status, 403);
  assertEquals(deps.stripe.calls.length, 0);
});

Deno.test("manage: a subscription belonging to another customer is refused", async () => {
  const deps = baseDeps({
    repo: subscribed(),
    stripe: fakeStripe({ "subscriptions.retrieve": (id) => stripeSubscription({ id, customer: "cus_globex" }) }),
  });
  const res = await readJson(
    await createManageSubscriptionHandler(deps)(
      jsonRequest({ organization_id: ORG_ID, action: "cancel" }, { token: "owner" }),
    ),
  );
  assertEquals(res.status, 409);
  assertEquals(res.body.error.code, "billing_state_mismatch");
  assertEquals(deps.stripe.callsTo("subscriptions.update").length, 0);
});

Deno.test("manage: no active subscription -> 404; unknown action -> 400", async () => {
  const none = await createManageSubscriptionHandler(baseDeps())(
    jsonRequest({ organization_id: ORG_ID, action: "cancel" }, { token: "owner" }),
  );
  assertEquals(none.status, 404);
  const bad = await createManageSubscriptionHandler(baseDeps())(
    jsonRequest({ organization_id: ORG_ID, action: "refund_everything" }, { token: "owner" }),
  );
  assertEquals(bad.status, 400);
});
