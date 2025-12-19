// INTEGRATION (real local database, mocked Stripe API):
// the production webhook handler + billing repository against PostgreSQL.
//
// Covers: idempotent duplicate delivery, out-of-order / stale observations,
// payment failure, failed processing + retry, trial expiry, cancellation,
// organization mismatch, and RLS on the resulting subscription rows.

import { assert, assertEquals } from "jsr:@std/assert@1.0.14";
import { createBillingRepository } from "../../functions/_shared/billing-repository.js";
import { createStripeWebhookHandler } from "../../functions/stripe-webhook/handler.js";
import {
  baseDeps,
  fakeStripe,
  readJson,
  stripeEvent,
  stripeSubscription,
  webhookRequest,
} from "../functions/_helpers.js";
import { activePriceId, cleanup, createTestUser, liveTest, serviceClient, sql, uniqueSuffix } from "./_env.js";

Deno.test({
  name: "integration: Stripe webhook processing against the real database",
  ...liveTest,
  fn: async (t) => {
    const db = sql();
    const service = serviceClient();
    const repo = createBillingRepository(service);

    const owner = await createTestUser("owner");
    const outsider = await createTestUser("outsider");
    const { data: org, error: orgError } = await owner.client.rpc("create_organization", {
      p_name: "Webhook Flow Org",
    });
    if (orgError) throw orgError;

    const suffix = uniqueSuffix();
    const customerId = `cus_it${suffix}`;
    const subscriptionId = `sub_it${suffix}`;
    await repo.linkStripeCustomer(org.id, customerId);
    const proPrice = await activePriceId("pro", "month");

    // Scripted Stripe API: what `subscriptions.retrieve` returns "now".
    const nowSeconds = Math.floor(Date.now() / 1000);
    let stripeState = stripeSubscription({
      id: subscriptionId,
      customer: customerId,
      status: "trialing",
      price: proPrice,
      trialEnd: nowSeconds + 14 * 86400,
      metadata: { organization_id: org.id },
    });
    let failNextRetrieve = false;
    let clock = new Date();

    const stripe = fakeStripe({
      "subscriptions.retrieve": () => {
        if (failNextRetrieve) {
          failNextRetrieve = false;
          throw new Error("Stripe API unavailable");
        }
        return structuredClone(stripeState);
      },
    });
    const handler = createStripeWebhookHandler({ ...baseDeps(), repo, stripe, now: () => clock });
    const deliver = async (event) => readJson(await handler(await webhookRequest(event)));
    const entitlements = async () => {
      const { data, error } = await owner.client.rpc("get_organization_entitlements", { p_organization_id: org.id });
      if (error) throw error;
      return data;
    };
    const ledger = async (eventId) =>
      (await db`select status::text, attempts, last_error, outcome from public.stripe_webhook_events
                where stripe_event_id = ${eventId}`)[0];
    const storedStatus = async () =>
      (await db`select status::text from public.organization_subscriptions
                where stripe_subscription_id = ${subscriptionId}`)[0]?.status;

    try {
      const created = stripeEvent("customer.subscription.created", structuredClone(stripeState));

      await t.step("subscription.created stores a trialing Pro subscription", async () => {
        const res = await deliver(created);
        assertEquals(res.status, 200);
        assertEquals(res.body.status, "processed");
        const e = await entitlements();
        assertEquals([e.plan, e.is_trialing, e.status], ["pro", true, "trialing"]);
      });

      await t.step("duplicate delivery is acknowledged once and stored once", async () => {
        const res = await deliver(created);
        assertEquals(res.body.duplicate, true);
        const rows =
          await db`select count(*)::int as n from public.stripe_webhook_events where stripe_event_id = ${created.id}`;
        assertEquals(rows[0].n, 1);
        assertEquals((await ledger(created.id)).attempts, 1);
      });

      await t.step("an older observation delivered late cannot overwrite newer state", async () => {
        const t0 = new Date();
        // Worker B observes "active" at t0 + 10s and commits first ...
        stripeState = { ...stripeState, status: "active", trial_end: null };
        clock = new Date(t0.getTime() + 10_000);
        const newer = await deliver(stripeEvent("customer.subscription.updated", structuredClone(stripeState)));
        assertEquals(newer.status, 200);
        assertEquals(await storedStatus(), "active");

        // ... worker A observed the old "trialing" state at t0 but commits later.
        const staleState = { ...stripeState, status: "trialing", trial_end: nowSeconds + 14 * 86400 };
        const staleStripe = fakeStripe({ "subscriptions.retrieve": () => structuredClone(staleState) });
        const staleHandler = createStripeWebhookHandler({ ...baseDeps(), repo, stripe: staleStripe, now: () => t0 });
        const staleEvent = stripeEvent("customer.subscription.updated", structuredClone(staleState));
        const stale = await readJson(await staleHandler(await webhookRequest(staleEvent)));

        assertEquals(stale.status, 200);
        assertEquals(await storedStatus(), "active", "stale observation was rejected");
        assertEquals((await ledger(staleEvent.id)).outcome, "skipped:stale");
      });

      await t.step("payment failure moves to past_due and flags the payment issue", async () => {
        stripeState = { ...stripeState, status: "past_due" };
        clock = new Date(Date.now() + 20_000);
        const invoice = {
          id: `in_it${suffix}`,
          parent: { subscription_details: { subscription: subscriptionId } },
          amount_due: 2900,
          amount_paid: 0,
          currency: "usd",
          attempt_count: 1,
        };
        const res = await deliver(stripeEvent("invoice.payment_failed", invoice));
        assertEquals(res.status, 200);
        const e = await entitlements();
        assertEquals([e.plan, e.has_payment_issue], ["pro", true]);
        const audit = await db`select count(*)::int as n from public.audit_logs
                               where organization_id = ${org.id} and action = 'billing.invoice_payment_failed'`;
        assertEquals(audit[0].n, 1);
      });

      await t.step("a processing failure is recorded and the retry succeeds", async () => {
        stripeState = { ...stripeState, status: "active" };
        clock = new Date(Date.now() + 30_000);
        failNextRetrieve = true;
        const paid = stripeEvent("invoice.paid", {
          id: `in_paid${suffix}`,
          subscription: subscriptionId,
          amount_paid: 2900,
        });

        const first = await deliver(paid);
        assertEquals(first.status, 500);
        const failed = await ledger(paid.id);
        assertEquals([failed.status, failed.attempts, failed.last_error], ["failed", 1, "Stripe API unavailable"]);

        const retry = await deliver(paid);
        assertEquals(retry.status, 200);
        const done = await ledger(paid.id);
        assertEquals([done.status, done.attempts], ["processed", 2]);
        assertEquals((await entitlements()).has_payment_issue, false);
      });

      await t.step("owners can read the subscription through RLS, other tenants cannot", async () => {
        const mine = await owner.client.from("organization_subscriptions").select("stripe_subscription_id, status");
        assertEquals(mine.data, [{ stripe_subscription_id: subscriptionId, status: "active" }]);
        const theirs = await outsider.client.from("organization_subscriptions").select("id").eq(
          "organization_id",
          org.id,
        );
        assertEquals(theirs.data, []);
        const denied = await outsider.client.rpc("get_organization_entitlements", { p_organization_id: org.id });
        assertEquals(denied.error?.code, "42501");
      });

      await t.step("a checkout session claiming another organization is rejected and audited", async () => {
        const res = await deliver(stripeEvent("checkout.session.completed", {
          id: `cs_it${suffix}`,
          mode: "subscription",
          customer: customerId,
          subscription: subscriptionId,
          client_reference_id: crypto.randomUUID(),
        }));
        assertEquals(res.body.status, "ignored");
        const audit = await db`select count(*)::int as n from public.audit_logs
                               where organization_id = ${org.id} and action = 'billing.checkout_rejected'`;
        assertEquals(audit[0].n, 1);
      });

      await t.step("an expired trial no longer grants entitlements", async () => {
        stripeState = { ...stripeState, status: "trialing", trial_end: nowSeconds - 3 * 3600 };
        clock = new Date(Date.now() + 40_000);
        await deliver(stripeEvent("customer.subscription.updated", structuredClone(stripeState)));
        assertEquals((await entitlements()).plan, "free");
      });

      await t.step("cancellation is terminal; a late 'active' state cannot resurrect it", async () => {
        stripeState = {
          ...stripeState,
          status: "canceled",
          trial_end: null,
          canceled_at: nowSeconds,
          ended_at: nowSeconds,
        };
        clock = new Date(Date.now() + 50_000);
        await deliver(stripeEvent("customer.subscription.deleted", structuredClone(stripeState)));
        assertEquals(await storedStatus(), "canceled");
        assertEquals((await entitlements()).plan, "free");

        stripeState = { ...stripeState, status: "active", canceled_at: null, ended_at: null };
        clock = new Date(Date.now() + 60_000);
        const late = stripeEvent("customer.subscription.updated", structuredClone(stripeState));
        await deliver(late);
        assertEquals(await storedStatus(), "canceled");
        assertEquals((await ledger(late.id)).outcome, "skipped:terminal_state");
      });

      await t.step("billing changes are in the audit trail, attributed to Stripe", async () => {
        const rows = await db`select action, actor_type from public.audit_logs
                              where organization_id = ${org.id} and entity_type = 'subscription'
                              order by created_at`;
        assert(rows.length >= 5);
        assert(rows.every((r) => r.actor_type === "stripe"), JSON.stringify(rows));
      });
    } finally {
      await cleanup(db, { organizationIds: [org.id], userIds: [owner.id, outsider.id] });
      await db.end();
    }
  },
});
