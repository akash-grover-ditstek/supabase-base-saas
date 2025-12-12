// MOCKED tests: stripe-webhook.
// Signatures are verified by the real Stripe SDK; the Stripe API and the
// database repository are fakes. See tests/integration for the same flows
// against the real local database.

import { assert, assertEquals } from "jsr:@std/assert@1.0.14";
import { createStripeWebhookHandler } from "../../functions/stripe-webhook/handler.js";
import {
  baseDeps,
  fakeRepo,
  fakeStripe,
  ORG_ID,
  OTHER_ORG_ID,
  readJson,
  stripeEvent,
  stripeSubscription,
  webhookRequest,
} from "./_helpers.js";

const subscriptionEvent = (type = "customer.subscription.updated", object = stripeSubscription()) =>
  stripeEvent(type, object);

// -----------------------------------------------------------------------------
// Signature verification
// -----------------------------------------------------------------------------
Deno.test("webhook: only POST is accepted", async () => {
  const res = await createStripeWebhookHandler(baseDeps())(new Request("http://localhost", { method: "GET" }));
  assertEquals(res.status, 405);
});

Deno.test("webhook: missing signature is rejected", async () => {
  const deps = baseDeps();
  const res = await createStripeWebhookHandler(deps)(
    new Request("http://localhost", { method: "POST", body: JSON.stringify(subscriptionEvent()) }),
  );
  assertEquals(res.status, 400);
  assertEquals(deps.repo.calls.length, 0);
});

Deno.test("webhook: signature made with another secret is rejected", async () => {
  const deps = baseDeps();
  const res = await readJson(
    await createStripeWebhookHandler(deps)(await webhookRequest(subscriptionEvent(), { secret: "whsec_attacker" })),
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error.code, "invalid_signature");
  assertEquals(deps.repo.calls.length, 0, "nothing is recorded for unsigned payloads");
  assertEquals(deps.stripe.calls.length, 0);
});

Deno.test("webhook: a tampered body fails verification (raw body is signed)", async () => {
  const deps = baseDeps();
  const res = await createStripeWebhookHandler(deps)(
    await webhookRequest(subscriptionEvent(), { tamper: (payload) => payload.replace('"active"', '"trialing"') }),
  );
  assertEquals(res.status, 400);
  assertEquals(deps.repo.calls.length, 0);
});

Deno.test("webhook: re-serialized JSON (whitespace change) fails verification", async () => {
  const res = await createStripeWebhookHandler(baseDeps())(
    await webhookRequest(subscriptionEvent(), { tamper: (payload) => JSON.stringify(JSON.parse(payload), null, 2) }),
  );
  assertEquals(res.status, 400);
});

Deno.test("webhook: replayed events outside the tolerance window are rejected", async () => {
  const res = await createStripeWebhookHandler(baseDeps())(
    await webhookRequest(subscriptionEvent(), { timestamp: Math.floor(Date.now() / 1000) - 3600 }),
  );
  assertEquals(res.status, 400);
});

Deno.test("webhook: oversized payloads are rejected before verification", async () => {
  const deps = baseDeps();
  const res = await createStripeWebhookHandler(deps)(
    new Request("http://localhost", {
      method: "POST",
      headers: { "stripe-signature": "t=1,v1=00" },
      body: "x".repeat(1024 * 1024 + 1),
    }),
  );
  assertEquals(res.status, 413);
  assertEquals(deps.repo.calls.length, 0);
});

// -----------------------------------------------------------------------------
// Idempotency
// -----------------------------------------------------------------------------
Deno.test("webhook: unhandled event types are acknowledged without processing", async () => {
  const deps = baseDeps();
  const res = await readJson(
    await createStripeWebhookHandler(deps)(await webhookRequest(stripeEvent("customer.created", { id: "cus_1" }))),
  );
  assertEquals(res.status, 200);
  assertEquals(res.body.ignored, true);
  assertEquals(deps.repo.calls.length, 0);
});

Deno.test("webhook: duplicate deliveries are acknowledged and not re-processed", async () => {
  const deps = baseDeps({ repo: fakeRepo({ claimWebhookEvent: () => "duplicate" }) });
  const res = await readJson(await createStripeWebhookHandler(deps)(await webhookRequest(subscriptionEvent())));
  assertEquals(res.status, 200);
  assertEquals(res.body.duplicate, true);
  assertEquals(deps.stripe.calls.length, 0);
  assertEquals(deps.repo.callsTo("applySubscription").length, 0);
});

Deno.test("webhook: an event being processed elsewhere returns 409 so Stripe retries", async () => {
  const deps = baseDeps({ repo: fakeRepo({ claimWebhookEvent: () => "in_progress" }) });
  const res = await createStripeWebhookHandler(deps)(await webhookRequest(subscriptionEvent()));
  assertEquals(res.status, 409);
  assertEquals(deps.stripe.calls.length, 0);
});

Deno.test("webhook: the claimed event payload and metadata are passed to the ledger", async () => {
  const deps = baseDeps();
  const event = subscriptionEvent();
  await createStripeWebhookHandler(deps)(await webhookRequest(event));
  const [[claimed]] = deps.repo.callsTo("claimWebhookEvent");
  assertEquals(claimed.id, event.id);
  assertEquals(claimed.type, event.type);
  assertEquals(deps.repo.callsTo("completeWebhookEvent")[0], [event.id, "processed", "applied:active"]);
});

// -----------------------------------------------------------------------------
// Out-of-order handling: Stripe state is re-read, payload state is never trusted
// -----------------------------------------------------------------------------
Deno.test("webhook: a stale payload is replaced by the current Stripe state", async () => {
  const deps = baseDeps({
    stripe: fakeStripe({ "subscriptions.retrieve": (id) => stripeSubscription({ id, status: "active" }) }),
  });
  const stalePayload = stripeSubscription({ status: "trialing", trialEnd: 1_800_000_000 });
  const res = await createStripeWebhookHandler(deps)(
    await webhookRequest(subscriptionEvent("customer.subscription.updated", stalePayload)),
  );
  assertEquals(res.status, 200);
  assertEquals(deps.stripe.callsTo("subscriptions.retrieve"), [["sub_123"]]);
  const [[applied, observedAt, eventId]] = deps.repo.callsTo("applySubscription");
  assertEquals(applied.status, "active");
  assertEquals(observedAt.toISOString(), "2025-12-06T05:46:40.000Z");
  assert(eventId.startsWith("evt_test_"));
});

Deno.test("webhook: stale writes rejected by the database are still acknowledged", async () => {
  const deps = baseDeps({
    repo: fakeRepo({ applySubscription: () => ({ applied: false, reason: "stale", organization_id: ORG_ID }) }),
  });
  const res = await readJson(await createStripeWebhookHandler(deps)(await webhookRequest(subscriptionEvent())));
  assertEquals(res.status, 200);
  assertEquals(deps.repo.callsTo("completeWebhookEvent")[0][1], "processed");
  assertEquals(deps.repo.callsTo("completeWebhookEvent")[0][2], "skipped:stale");
});

Deno.test("webhook: subscription deletion applies the canceled state", async () => {
  const deps = baseDeps({
    stripe: fakeStripe({ "subscriptions.retrieve": (id) => stripeSubscription({ id, status: "canceled" }) }),
  });
  await createStripeWebhookHandler(deps)(
    await webhookRequest(
      subscriptionEvent("customer.subscription.deleted", stripeSubscription({ status: "canceled" })),
    ),
  );
  assertEquals(deps.repo.callsTo("applySubscription")[0][0].status, "canceled");
});

Deno.test("webhook: subscriptions deleted at Stripe are ignored instead of retried forever", async () => {
  const deps = baseDeps({
    stripe: fakeStripe({
      "subscriptions.retrieve": () => {
        const err = new Error("No such subscription");
        err.code = "resource_missing";
        throw err;
      },
    }),
  });
  const res = await createStripeWebhookHandler(deps)(await webhookRequest(subscriptionEvent()));
  assertEquals(res.status, 200);
  assertEquals(deps.repo.callsTo("completeWebhookEvent")[0].slice(1), ["ignored", "subscription_not_found"]);
});

// -----------------------------------------------------------------------------
// Checkout
// -----------------------------------------------------------------------------
const checkoutSession = (overrides = {}) => ({
  id: "cs_test_123",
  object: "checkout.session",
  mode: "subscription",
  customer: "cus_acme",
  subscription: "sub_123",
  client_reference_id: ORG_ID,
  payment_status: "paid",
  metadata: { organization_id: ORG_ID },
  ...overrides,
});

Deno.test("checkout.session.completed: entitlement follows the Stripe subscription, not the session", async () => {
  const deps = baseDeps({
    stripe: fakeStripe({ "subscriptions.retrieve": (id) => stripeSubscription({ id, status: "incomplete" }) }),
  });
  const res = await createStripeWebhookHandler(deps)(
    await webhookRequest(stripeEvent("checkout.session.completed", checkoutSession({ payment_status: "unpaid" }))),
  );
  assertEquals(res.status, 200);
  assertEquals(deps.repo.callsTo("getOrganizationIdForCustomer"), [["cus_acme"]]);
  assertEquals(deps.repo.callsTo("applySubscription")[0][0].status, "incomplete");
  const audit = deps.repo.callsTo("recordAuditEvent").map(([a]) => a.action);
  assertEquals(audit, ["billing.checkout_completed"]);
});

Deno.test("checkout.session.completed: a session claiming another organization is rejected", async () => {
  const deps = baseDeps();
  const res = await createStripeWebhookHandler(deps)(
    await webhookRequest(
      stripeEvent("checkout.session.completed", checkoutSession({ client_reference_id: OTHER_ORG_ID })),
    ),
  );
  assertEquals(res.status, 200);
  assertEquals(deps.stripe.calls.length, 0, "no subscription is fetched or attached");
  assertEquals(deps.repo.callsTo("applySubscription").length, 0);
  const [[audit]] = deps.repo.callsTo("recordAuditEvent");
  assertEquals(audit.action, "billing.checkout_rejected");
  assertEquals(audit.organizationId, ORG_ID);
  assertEquals(deps.repo.callsTo("completeWebhookEvent")[0].slice(1), ["ignored", "organization_mismatch"]);
});

Deno.test("checkout.session.completed: unknown customers are ignored", async () => {
  const deps = baseDeps();
  await createStripeWebhookHandler(deps)(
    await webhookRequest(stripeEvent("checkout.session.completed", checkoutSession({ customer: "cus_unknown" }))),
  );
  assertEquals(deps.stripe.calls.length, 0);
  assertEquals(deps.repo.callsTo("completeWebhookEvent")[0].slice(1), ["ignored", "unknown_customer"]);
});

Deno.test("checkout.session.completed: one-time payment sessions are ignored", async () => {
  const deps = baseDeps();
  await createStripeWebhookHandler(deps)(
    await webhookRequest(
      stripeEvent("checkout.session.completed", checkoutSession({ mode: "payment", subscription: null })),
    ),
  );
  assertEquals(deps.repo.callsTo("completeWebhookEvent")[0].slice(1), ["ignored", "not_a_subscription_checkout"]);
});

// -----------------------------------------------------------------------------
// Invoices and trials
// -----------------------------------------------------------------------------
Deno.test("invoice.payment_failed: resyncs (past_due) and audits the failure", async () => {
  const deps = baseDeps({
    stripe: fakeStripe({ "subscriptions.retrieve": (id) => stripeSubscription({ id, status: "past_due" }) }),
  });
  const invoice = {
    id: "in_123",
    object: "invoice",
    parent: { subscription_details: { subscription: "sub_123" } },
    amount_due: 2900,
    amount_paid: 0,
    currency: "usd",
    attempt_count: 2,
    next_payment_attempt: 1_765_100_000,
  };
  const res = await createStripeWebhookHandler(deps)(
    await webhookRequest(stripeEvent("invoice.payment_failed", invoice)),
  );
  assertEquals(res.status, 200);
  assertEquals(deps.repo.callsTo("applySubscription")[0][0].status, "past_due");
  const [[audit]] = deps.repo.callsTo("recordAuditEvent");
  assertEquals(audit.action, "billing.invoice_payment_failed");
  assertEquals(audit.metadata.attempt_count, 2);
  assertEquals(audit.actorType, "stripe");
});

Deno.test("invoice.paid: legacy invoice shape is supported", async () => {
  const deps = baseDeps();
  await createStripeWebhookHandler(deps)(
    await webhookRequest(stripeEvent("invoice.paid", { id: "in_1", subscription: "sub_123", amount_paid: 2900 })),
  );
  assertEquals(deps.stripe.callsTo("subscriptions.retrieve"), [["sub_123"]]);
  assertEquals(deps.repo.callsTo("recordAuditEvent")[0][0].action, "billing.invoice_paid");
});

Deno.test("invoice without a subscription is ignored", async () => {
  const deps = baseDeps();
  await createStripeWebhookHandler(deps)(await webhookRequest(stripeEvent("invoice.paid", { id: "in_oneoff" })));
  assertEquals(deps.stripe.calls.length, 0);
  assertEquals(deps.repo.callsTo("completeWebhookEvent")[0].slice(1), ["ignored", "invoice_without_subscription"]);
});

Deno.test("customer.subscription.trial_will_end: resyncs and records an audit event", async () => {
  const deps = baseDeps();
  const sub = stripeSubscription({ status: "trialing", trialEnd: 1_765_300_000 });
  await createStripeWebhookHandler(deps)(
    await webhookRequest(stripeEvent("customer.subscription.trial_will_end", sub)),
  );
  const [[audit]] = deps.repo.callsTo("recordAuditEvent");
  assertEquals(audit.action, "billing.trial_will_end");
  assertEquals(audit.metadata.trial_end, new Date(1_765_300_000 * 1000).toISOString());
});

// -----------------------------------------------------------------------------
// Failures and retries
// -----------------------------------------------------------------------------
Deno.test("webhook: processing failures are recorded and return 500 for Stripe retry", async () => {
  const deps = baseDeps({
    stripe: fakeStripe({
      "subscriptions.retrieve": () => {
        throw new Error("Stripe API timeout");
      },
    }),
  });
  const event = subscriptionEvent();
  const res = await readJson(await createStripeWebhookHandler(deps)(await webhookRequest(event)));
  assertEquals(res.status, 500);
  assertEquals(res.body.error.code, "processing_failed");
  assertEquals(deps.repo.callsTo("failWebhookEvent"), [[event.id, "Stripe API timeout"]]);
  assertEquals(deps.repo.callsTo("completeWebhookEvent").length, 0);
});

Deno.test("webhook: database errors are recorded with their cause and not leaked", async () => {
  const deps = baseDeps({
    repo: fakeRepo({
      applySubscription: () => {
        const err = new Error("Could not store subscription state");
        err.cause = { message: 'Unknown Stripe price "price_new"' };
        throw err;
      },
    }),
  });
  const res = await readJson(await createStripeWebhookHandler(deps)(await webhookRequest(subscriptionEvent())));
  assertEquals(res.status, 500);
  assertEquals(JSON.stringify(res.body).includes("price_new"), false);
  assertEquals(deps.repo.callsTo("failWebhookEvent")[0][1], 'Unknown Stripe price "price_new"');
});
