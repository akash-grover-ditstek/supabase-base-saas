// REAL STRIPE TEST-MODE INTEGRATION (opt-in, never runs by default).
//
// Talks to api.stripe.com with a TEST-mode key to verify that our payload
// normalization matches the pinned API version and that the Checkout/Customer
// calls we make are accepted by Stripe. Everything created is deleted again.
//
//   STRIPE_LIVE_TESTS=1 \
//   STRIPE_SECRET_KEY=sk_test_... \
//   STRIPE_TEST_PRICE_ID=price_... (a recurring test-mode price) \
//   npx deno test --allow-env --allow-net --allow-read --no-lock supabase/tests/integration/stripe-live.test.js

import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1.0.14";
import { normalizeSubscription } from "../../functions/_shared/billing.js";
import { createStripeClient } from "../../functions/_shared/stripe.js";

const key = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const priceId = Deno.env.get("STRIPE_TEST_PRICE_ID") ?? "";
const enabled = Deno.env.get("STRIPE_LIVE_TESTS") === "1" && key.startsWith("sk_test_") && priceId.startsWith("price_");

Deno.test({
  name: "stripe test mode: customer, checkout session and trial subscription lifecycle",
  ignore: !enabled,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const stripe = createStripeClient({ stripeSecretKey: key });
    const organizationId = crypto.randomUUID();
    const customer = await stripe.customers.create(
      { name: "Live Test Org", metadata: { organization_id: organizationId } },
      { idempotencyKey: `organization-customer-${organizationId}` },
    );

    try {
      const again = await stripe.customers.create(
        { name: "Live Test Org", metadata: { organization_id: organizationId } },
        { idempotencyKey: `organization-customer-${organizationId}` },
      );
      assertEquals(again.id, customer.id, "idempotency key returns the same customer");

      const session = await stripe.checkout.sessions.create({
        mode: "subscription",
        customer: customer.id,
        client_reference_id: organizationId,
        line_items: [{ price: priceId, quantity: 1 }],
        subscription_data: { trial_period_days: 7, metadata: { organization_id: organizationId } },
        success_url: "https://app.example.test/billing/success?session_id={CHECKOUT_SESSION_ID}",
        cancel_url: "https://app.example.test/billing/cancelled",
      });
      assertMatch(session.url, /^https:\/\/checkout\.stripe\.com\//);

      const subscription = await stripe.subscriptions.create({
        customer: customer.id,
        items: [{ price: priceId }],
        trial_period_days: 7,
        trial_settings: { end_behavior: { missing_payment_method: "cancel" } },
        metadata: { organization_id: organizationId },
      });
      const normalized = normalizeSubscription(subscription);
      assertEquals(normalized.status, "trialing");
      assertEquals(normalized.customer, customer.id);
      assertEquals(normalized.price_id, priceId);
      assertEquals(normalized.metadata_organization_id, organizationId);
      assert(normalized.current_period_end, "billing period is read from the subscription item");
      assert(normalized.trial_end);

      const canceled = await stripe.subscriptions.cancel(subscription.id);
      assertEquals(normalizeSubscription(canceled).status, "canceled");
    } finally {
      await stripe.customers.del(customer.id);
    }
  },
});
