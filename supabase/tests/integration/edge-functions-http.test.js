// INTEGRATION (real local stack over HTTP): Kong gateway -> Edge Runtime ->
// JavaScript functions -> Supabase Auth / PostgREST / PostgreSQL.
//
// Requires `supabase start` (functions are served automatically) with the
// local secrets in supabase/functions/.env. STRIPE_SECRET_KEY there is a dummy
// key, so any path that reaches the Stripe API must fail closed with 502.

import { assert, assertEquals } from "jsr:@std/assert@1.0.14";
import { signPayload, stripeEvent } from "../functions/_helpers.js";
import { cleanup, createTestUser, env, liveTest, localWebhookSecret, sql, uniqueSuffix } from "./_env.js";

const call = async (name, { body, token, headers = {} } = {}) => {
  const res = await fetch(`${env.url}/functions/v1/${name}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      apikey: env.anonKey,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: typeof body === "string" ? body : JSON.stringify(body ?? {}),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
};

Deno.test({
  name: "integration: Edge Functions over HTTP enforce authentication, authorization and signatures",
  ...liveTest,
  fn: async (t) => {
    const db = sql();
    const owner = await createTestUser("http-owner");
    const member = await createTestUser("http-member");
    const { data: org, error } = await owner.client.rpc("create_organization", { p_name: "HTTP Org" });
    if (error) throw error;
    await db`insert into public.organization_members (organization_id, user_id) values (${org.id}, ${member.id})`;
    const invitedEmail = `invitee.${uniqueSuffix()}@integration.test`;

    try {
      await t.step("stripe-webhook rejects missing and forged signatures", async () => {
        const missing = await call("stripe-webhook", { body: { id: "evt_x" } });
        assertEquals([missing.status, missing.body.error.code], [400, "missing_signature"]);

        const forged = await call("stripe-webhook", {
          body: "{}",
          headers: { "stripe-signature": `t=${Math.floor(Date.now() / 1000)},v1=${"0".repeat(64)}` },
        });
        assertEquals([forged.status, forged.body.error.code], [400, "invalid_signature"]);
      });

      await t.step("stripe-webhook: signed event is processed once, redelivery is a duplicate", async () => {
        const secret = await localWebhookSecret();
        assert(secret, "STRIPE_WEBHOOK_SECRET is configured in supabase/functions/.env");
        const event = stripeEvent("checkout.session.completed", {
          id: `cs_http${uniqueSuffix()}`,
          mode: "subscription",
          customer: `cus_unknown${uniqueSuffix()}`,
          subscription: `sub_unknown${uniqueSuffix()}`,
        });
        const payload = JSON.stringify(event);
        const headers = { "stripe-signature": await signPayload(payload, secret) };

        const first = await call("stripe-webhook", { body: payload, headers });
        assertEquals([first.status, first.body.status], [200, "ignored"]);
        const second = await call("stripe-webhook", { body: payload, headers });
        assertEquals([second.status, second.body.duplicate], [200, true]);

        const rows =
          await db`select status::text, outcome from public.stripe_webhook_events where stripe_event_id = ${event.id}`;
        assertEquals([...rows], [{ status: "ignored", outcome: "unknown_customer" }]);
      });

      const checkoutBody = { organization_id: org.id, plan_code: "pro", interval: "month" };

      await t.step("create-checkout-session requires a valid session", async () => {
        assertEquals((await call("create-checkout-session", { body: checkoutBody })).status, 401);
        assertEquals((await call("create-checkout-session", { body: checkoutBody, token: "not-a-jwt" })).status, 401);
      });

      await t.step("create-checkout-session is owner-only (role checked in PostgreSQL)", async () => {
        const res = await call("create-checkout-session", { body: checkoutBody, token: member.accessToken });
        assertEquals([res.status, res.body.error.code], [403, "forbidden"]);
      });

      await t.step("create-checkout-session fails closed when Stripe rejects the request", async () => {
        const res = await call("create-checkout-session", { body: checkoutBody, token: owner.accessToken });
        assertEquals([res.status, res.body.error.code], [502, "payment_provider_error"]);
        assert(!JSON.stringify(res.body).includes("sk_test"), "no provider details are leaked");
        const linked =
          await db`select count(*)::int as n from public.stripe_customers where organization_id = ${org.id}`;
        assertEquals(linked[0].n, 0, "no customer is linked when Stripe fails");
      });

      await t.step("billing portal / manage-subscription require billing state", async () => {
        const portal = await call("create-billing-portal-session", {
          body: { organization_id: org.id },
          token: owner.accessToken,
        });
        assertEquals([portal.status, portal.body.error.code], [404, "no_billing_account"]);
        const manage = await call("manage-subscription", {
          body: { organization_id: org.id, action: "cancel" },
          token: owner.accessToken,
        });
        assertEquals([manage.status, manage.body.error.code], [404, "no_active_subscription"]);
        const memberPortal = await call("create-billing-portal-session", {
          body: { organization_id: org.id },
          token: member.accessToken,
        });
        assertEquals(memberPortal.status, 403);
      });

      await t.step("sync-subscription: internal secret or admin role", async () => {
        const anonymous = await call("sync-subscription", { body: { organization_id: org.id } });
        assertEquals(anonymous.status, 401);
        const asMember = await call("sync-subscription", {
          body: { organization_id: org.id },
          token: member.accessToken,
        });
        assertEquals(asMember.status, 403);
        const asOwner = await call("sync-subscription", {
          body: { organization_id: org.id },
          token: owner.accessToken,
        });
        assertEquals([asOwner.status, asOwner.body.synced], [200, 0]);
      });

      await t.step("invite-organization-member: database rules apply to HTTP callers", async () => {
        const denied = await call("invite-organization-member", {
          body: { organization_id: org.id, email: invitedEmail },
          token: member.accessToken,
        });
        assertEquals(denied.status, 403);

        const created = await call("invite-organization-member", {
          body: { organization_id: org.id, email: invitedEmail },
          token: owner.accessToken,
        });
        assertEquals(created.status, 201);
        assertEquals(created.body.invitation.status, "pending");
        assertEquals(created.body.delivery, "auth_invite_email_sent");

        const duplicate = await call("invite-organization-member", {
          body: { organization_id: org.id, email: invitedEmail },
          token: owner.accessToken,
        });
        assertEquals([duplicate.status, duplicate.body.error.code], [409, "conflict"]);
      });
    } finally {
      const invited = await db`select id from auth.users where email = ${invitedEmail}`;
      await cleanup(db, { organizationIds: [org.id], userIds: [owner.id, member.id, ...invited.map((r) => r.id)] });
      await db.end();
    }
  },
});
