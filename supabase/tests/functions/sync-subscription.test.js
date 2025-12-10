// MOCKED tests: sync-subscription (reconciliation with Stripe).

import { assertEquals } from "jsr:@std/assert@1.0.14";
import { createSyncSubscriptionHandler } from "../../functions/sync-subscription/handler.js";
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

const linkedRepo = (overrides = {}) =>
  fakeRepo({ getBillingContext: () => billingContext({ stripe_customer_id: "cus_acme" }), ...overrides });

Deno.test("sync: admins reconcile every subscription of the organization's customer", async () => {
  const deps = baseDeps({
    repo: linkedRepo(),
    stripe: fakeStripe({
      "subscriptions.list": () => ({
        data: [
          stripeSubscription({ id: "sub_old", status: "canceled" }),
          stripeSubscription({ id: "sub_new", status: "active" }),
        ],
      }),
    }),
  });
  const res = await readJson(
    await createSyncSubscriptionHandler(deps)(jsonRequest({ organization_id: ORG_ID }, { token: "admin" })),
  );
  assertEquals(res.status, 200);
  assertEquals(res.body.synced, 2);
  assertEquals(deps.stripe.callsTo("subscriptions.list"), [[{ customer: "cus_acme", status: "all", limit: 20 }]]);
  assertEquals(deps.repo.callsTo("applySubscription").map(([s]) => s.id), ["sub_old", "sub_new"]);
  assertEquals(deps.repo.callsTo("recordAuditEvent")[0][0].action, "billing.subscription_reconciled");
});

Deno.test("sync: members and outsiders cannot trigger reconciliation", async () => {
  for (const token of ["member", "outsider"]) {
    const deps = baseDeps({ repo: linkedRepo() });
    const res = await createSyncSubscriptionHandler(deps)(jsonRequest({ organization_id: ORG_ID }, { token }));
    assertEquals(res.status, 403, token);
    assertEquals(deps.stripe.calls.length, 0);
  }
});

Deno.test("sync: internal jobs authenticate with the shared secret", async () => {
  const deps = baseDeps({ repo: linkedRepo() });
  const res = await createSyncSubscriptionHandler(deps)(
    jsonRequest({ organization_id: ORG_ID }, { headers: { "x-internal-sync-secret": "internal-secret-for-tests" } }),
  );
  assertEquals(res.status, 200);
  assertEquals(deps.repo.callsTo("recordAuditEvent")[0][0].actorType, "system");
});

Deno.test("sync: a wrong internal secret falls back to user authentication", async () => {
  const deps = baseDeps({ repo: linkedRepo() });
  const res = await createSyncSubscriptionHandler(deps)(
    jsonRequest({ organization_id: ORG_ID }, { headers: { "x-internal-sync-secret": "guess" } }),
  );
  assertEquals(res.status, 401);
  assertEquals(deps.stripe.calls.length, 0);
});

Deno.test("sync: organizations without a Stripe customer have nothing to sync", async () => {
  const deps = baseDeps();
  const res = await readJson(
    await createSyncSubscriptionHandler(deps)(jsonRequest({ organization_id: ORG_ID }, { token: "owner" })),
  );
  assertEquals(res.body, { organization_id: ORG_ID, synced: 0, subscriptions: [] });
  assertEquals(deps.stripe.calls.length, 0);
});
