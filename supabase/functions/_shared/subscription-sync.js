// Reconciliation: Stripe is the source of truth for subscription state.
//
// Webhook payloads can be delayed, duplicated or delivered out of order, so we
// never persist `event.data.object` directly. Instead we re-read the
// subscription from the Stripe API and store that, stamped with the time the
// read *started*. The database rejects writes whose stamp is older than the
// stored one (public.apply_stripe_subscription), so concurrent workers cannot
// regress state, and a stamp taken before the read never overstates freshness.

import { normalizeSubscription } from "./billing.js";

export async function syncSubscriptionFromStripe(
  { stripe, repo, subscriptionId, eventId = null, now = () => new Date() },
) {
  const observedAt = now();
  const subscription = await stripe.subscriptions.retrieve(subscriptionId);
  const result = await repo.applySubscription(normalizeSubscription(subscription), observedAt, eventId);
  return { subscription, result };
}

/** Store a subscription object returned by a Stripe write API call. */
export async function applyStripeSubscriptionObject({ repo, subscription, observedAt, eventId = null }) {
  return await repo.applySubscription(normalizeSubscription(subscription), observedAt, eventId);
}
