// POST /functions/v1/stripe-webhook   (called by Stripe; verify_jwt = false)
//
// Pipeline
//   1. Verify the Stripe-Signature header against the RAW request body.
//   2. Claim the event id in stripe_webhook_events (idempotency ledger):
//        duplicate   -> 200, nothing re-processed
//        in_progress -> 409, Stripe retries later
//   3. Process: re-read the subscription from Stripe (payloads may be stale or
//      out of order) and apply it with a monotonic upsert in PostgreSQL.
//   4. Mark processed / ignored, or failed (-> 500, Stripe retries; the
//      failed event is re-claimable).
//
// Tenant resolution always uses our stripe_customers mapping. Metadata such as
// client_reference_id is only cross-checked, never trusted.

import { idOf, invoiceSubscriptionId, toIso } from "../_shared/billing.js";
import { errorBody, HttpError, json, withHandler } from "../_shared/http.js";
import { syncSubscriptionFromStripe } from "../_shared/subscription-sync.js";

// Stripe event payloads are far below this; anything larger is not from Stripe.
const MAX_WEBHOOK_BYTES = 1024 * 1024;

export const HANDLED_EVENT_TYPES = new Set([
  "checkout.session.completed",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "customer.subscription.trial_will_end",
  "invoice.paid",
  "invoice.payment_failed",
]);

export function createStripeWebhookHandler(deps) {
  const { stripe, repo, config, cryptoProvider, logger } = deps;

  return withHandler(async (req) => {
    const signature = req.headers.get("stripe-signature");
    if (!signature) throw new HttpError(400, "missing_signature", "Missing Stripe-Signature header");

    if (Number(req.headers.get("content-length") ?? "0") > MAX_WEBHOOK_BYTES) {
      throw new HttpError(413, "payload_too_large", "Webhook payload is too large");
    }

    // The signature covers the exact bytes Stripe sent: never re-serialize JSON.
    const rawBody = await req.text();
    if (rawBody.length > MAX_WEBHOOK_BYTES) {
      throw new HttpError(413, "payload_too_large", "Webhook payload is too large");
    }

    let event;
    try {
      event = await stripe.webhooks.constructEventAsync(
        rawBody,
        signature,
        config.stripeWebhookSecret,
        undefined,
        cryptoProvider,
      );
    } catch {
      logger.warn("webhook signature verification failed");
      throw new HttpError(400, "invalid_signature", "Webhook signature verification failed");
    }

    if (!HANDLED_EVENT_TYPES.has(event.type)) {
      return json({ received: true, ignored: true });
    }

    const claim = await repo.claimWebhookEvent(event);
    if (claim === "duplicate") {
      logger.info("duplicate webhook delivery", { event_id: event.id, type: event.type });
      return json({ received: true, duplicate: true });
    }
    if (claim === "in_progress") {
      return json(errorBody("event_in_progress", "Event is being processed; retry later"), 409);
    }

    try {
      const outcome = await processStripeEvent(event, deps);
      await repo.completeWebhookEvent(event.id, outcome.status, outcome.note ?? null);
      logger.info("webhook processed", {
        event_id: event.id,
        type: event.type,
        status: outcome.status,
        note: outcome.note,
      });
      return json({ received: true, status: outcome.status });
    } catch (err) {
      const message = err?.cause?.message ?? err?.message ?? String(err);
      logger.error("webhook processing failed", { event_id: event.id, type: event.type, error: message });
      try {
        await repo.failWebhookEvent(event.id, message);
      } catch (ledgerError) {
        logger.error("could not record webhook failure", { event_id: event.id, error: ledgerError?.message });
      }
      return json(errorBody("processing_failed", "Webhook processing failed and will be retried"), 500);
    }
  }, { name: "stripe-webhook", cors: false, logger });
}

// -----------------------------------------------------------------------------
// Event processing
// -----------------------------------------------------------------------------

const processed = (note, organizationId = null) => ({ status: "processed", note, organizationId });
const ignored = (note, organizationId = null) => ({ status: "ignored", note, organizationId });

function outcomeFromApply(result) {
  if (!result) return processed(null);
  if (result.applied) return processed(`applied:${result.status}`, result.organization_id);
  if (result.reason === "unknown_customer" || result.reason === "organization_mismatch") {
    return ignored(result.reason, result.organization_id ?? null);
  }
  // stale / terminal_state: a newer state is already stored. Success.
  return processed(`skipped:${result.reason}`, result.organization_id ?? null);
}

async function syncOrIgnore(subscriptionId, event, deps) {
  try {
    const { result } = await syncSubscriptionFromStripe({
      stripe: deps.stripe,
      repo: deps.repo,
      subscriptionId,
      eventId: event.id,
      now: deps.now,
    });
    return outcomeFromApply(result);
  } catch (err) {
    if (err?.code === "resource_missing") return ignored("subscription_not_found");
    throw err;
  }
}

export async function processStripeEvent(event, deps) {
  const object = event.data?.object ?? {};

  switch (event.type) {
    case "checkout.session.completed":
      return await handleCheckoutCompleted(event, object, deps);

    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
      return await syncOrIgnore(object.id, event, deps);

    case "customer.subscription.trial_will_end": {
      const outcome = await syncOrIgnore(object.id, event, deps);
      if (outcome.organizationId) {
        await deps.repo.recordAuditEvent({
          organizationId: outcome.organizationId,
          action: "billing.trial_will_end",
          entityType: "subscription",
          entityId: object.id,
          actorType: "stripe",
          metadata: { trial_end: toIso(object.trial_end), stripe_event_id: event.id },
        });
      }
      return outcome;
    }

    case "invoice.paid":
    case "invoice.payment_failed":
      return await handleInvoice(event, object, deps);

    default:
      return ignored("unhandled_event_type");
  }
}

async function handleCheckoutCompleted(event, session, deps) {
  if (session.mode !== "subscription" || !session.subscription) {
    return ignored("not_a_subscription_checkout");
  }

  const customerId = idOf(session.customer);
  const organizationId = customerId ? await deps.repo.getOrganizationIdForCustomer(customerId) : null;
  if (!organizationId) return ignored("unknown_customer");

  const claimedOrganizationId = session.client_reference_id ?? session.metadata?.organization_id ?? null;
  if (claimedOrganizationId && claimedOrganizationId !== organizationId) {
    await deps.repo.recordAuditEvent({
      organizationId,
      action: "billing.checkout_rejected",
      entityType: "checkout_session",
      entityId: session.id,
      actorType: "stripe",
      metadata: {
        reason: "organization_mismatch",
        claimed_organization_id: claimedOrganizationId,
        stripe_event_id: event.id,
      },
    });
    return ignored("organization_mismatch", organizationId);
  }

  // A completed Checkout is not proof of payment: entitlement follows the
  // subscription status read back from Stripe (e.g. trialing, active, incomplete).
  const outcome = await syncOrIgnore(idOf(session.subscription), event, deps);

  await deps.repo.recordAuditEvent({
    organizationId,
    action: "billing.checkout_completed",
    entityType: "checkout_session",
    entityId: session.id,
    actorType: "stripe",
    metadata: {
      subscription_id: idOf(session.subscription),
      payment_status: session.payment_status ?? null,
      stripe_event_id: event.id,
    },
  });

  return outcome;
}

async function handleInvoice(event, invoice, deps) {
  const subscriptionId = invoiceSubscriptionId(invoice);
  if (!subscriptionId) return ignored("invoice_without_subscription");

  const outcome = await syncOrIgnore(subscriptionId, event, deps);

  if (outcome.organizationId) {
    await deps.repo.recordAuditEvent({
      organizationId: outcome.organizationId,
      action: event.type === "invoice.paid" ? "billing.invoice_paid" : "billing.invoice_payment_failed",
      entityType: "invoice",
      entityId: invoice.id ?? null,
      actorType: "stripe",
      metadata: {
        subscription_id: subscriptionId,
        amount_due: invoice.amount_due ?? null,
        amount_paid: invoice.amount_paid ?? null,
        currency: invoice.currency ?? null,
        attempt_count: invoice.attempt_count ?? null,
        next_payment_attempt: toIso(invoice.next_payment_attempt),
        stripe_event_id: event.id,
      },
    });
  }

  return outcome;
}
