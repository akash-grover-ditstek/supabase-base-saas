// Test doubles for Edge Function handler tests (MOCKED — no network, no DB).
//
// * Supabase Auth / PostgREST are replaced by an in-memory fake client, but
//   the real authenticator (supabase/functions/_shared/auth.js) is used.
// * The billing repository is a recording fake.
// * Stripe API methods are recording fakes; webhook signature verification
//   uses the REAL Stripe SDK (pure HMAC, no network).

import { createAuthenticator } from "../../functions/_shared/auth.js";
import { Stripe } from "../../functions/_shared/deps.js";
import { silentLogger } from "../../functions/_shared/logger.js";

export const ORG_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const OTHER_ORG_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
export const WEBHOOK_SECRET = "whsec_test_secret_for_unit_tests";

export const USERS = {
  owner: { id: "11111111-1111-4111-8111-111111111111", email: "owner@acme.test", role: "owner" },
  admin: { id: "22222222-2222-4222-8222-222222222222", email: "admin@acme.test", role: "admin" },
  member: { id: "33333333-3333-4333-8333-333333333333", email: "member@acme.test", role: "member" },
  outsider: { id: "44444444-4444-4444-8444-444444444444", email: "dave@globex.test", role: null },
  anonymous: { id: "55555555-5555-4555-8555-555555555555", email: null, role: null, is_anonymous: true },
};

const RANK = { member: 1, admin: 2, owner: 3 };

export const config = {
  supabaseUrl: "http://supabase.test",
  supabaseAnonKey: "anon-key",
  supabaseServiceRoleKey: "service-role-key",
  stripeSecretKey: "sk_test_unit",
  stripeWebhookSecret: WEBHOOK_SECRET,
  appUrl: "https://app.example.test",
  internalSyncSecret: "internal-secret-for-tests",
};

/** Fake user-scoped Supabase client: `auth.getUser` + `rpc`. */
export function fakeUserClient(token, { rpc = {} } = {}) {
  const user = USERS[token];
  return {
    auth: {
      getUser: () =>
        Promise.resolve(
          user ? { data: { user }, error: null } : { data: { user: null }, error: { message: "invalid JWT" } },
        ),
    },
    rpc: (fn, args) => {
      if (rpc[fn]) return Promise.resolve(rpc[fn](args, user));
      if (fn === "has_organization_role") {
        const role = args.p_organization_id === ORG_ID ? user?.role : null;
        return Promise.resolve({ data: Boolean(role) && RANK[role] >= RANK[args.p_role], error: null });
      }
      return Promise.resolve({ data: null, error: { code: "PGRST202", message: `unexpected rpc ${fn}` } });
    },
  };
}

/** The real authenticator wired to the fake client. Tokens are USERS keys. */
export function fakeAuthenticate(options = {}) {
  return createAuthenticator({ createUserClient: (token) => fakeUserClient(token, options) });
}

/** Recording fake of the billing repository. */
export function fakeRepo(overrides = {}) {
  const calls = [];
  const defaults = {
    getBillingContext: () => billingContext(),
    linkStripeCustomer: (organizationId, customerId) => ({
      organization_id: organizationId,
      stripe_customer_id: customerId,
    }),
    getOrganizationIdForCustomer: (customerId) => (customerId === "cus_acme" ? ORG_ID : null),
    applySubscription: (subscription) => ({
      applied: true,
      organization_id: ORG_ID,
      status: subscription.status,
      plan: "pro",
    }),
    claimWebhookEvent: () => "claimed",
    completeWebhookEvent: () => null,
    failWebhookEvent: () => null,
    recordAuditEvent: () => "audit-id",
  };
  const repo = {
    calls,
    callsTo: (name) => calls.filter((c) => c.name === name).map((c) => c.args),
  };
  for (const [name, impl] of Object.entries({ ...defaults, ...overrides })) {
    repo[name] = async (...args) => {
      calls.push({ name, args });
      return await impl(...args);
    };
  }
  return repo;
}

export function billingContext(overrides = {}) {
  return {
    organization: { id: ORG_ID, name: "Acme" },
    stripe_customer_id: null,
    price: {
      stripe_price_id: "price_pro_monthly",
      plan_code: "pro",
      plan_name: "Pro",
      interval: "month",
      currency: "usd",
      unit_amount: 2900,
      trial_period_days: 14,
    },
    current_subscription: null,
    trial_eligible: true,
    ...overrides,
  };
}

/** Recording fake Stripe client; `webhooks` is the real SDK implementation. */
export function fakeStripe(overrides = {}) {
  const calls = [];
  const real = new Stripe("sk_test_unit", { httpClient: Stripe.createFetchHttpClient() });
  const method = (name, fallback) => async (...args) => {
    calls.push({ name, args });
    return await (overrides[name] ?? fallback)(...args);
  };
  return {
    calls,
    callsTo: (name) => calls.filter((c) => c.name === name).map((c) => c.args),
    webhooks: real.webhooks,
    customers: { create: method("customers.create", (params) => ({ id: "cus_new123", ...params })) },
    checkout: {
      sessions: {
        create: method("checkout.sessions.create", () => ({
          id: "cs_test_123",
          url: "https://checkout.stripe.com/c/pay/cs_test_123",
        })),
      },
    },
    billingPortal: {
      sessions: {
        create: method("billingPortal.sessions.create", () => ({
          id: "bps_123",
          url: "https://billing.stripe.com/p/session/bps_123",
        })),
      },
    },
    subscriptions: {
      retrieve: method("subscriptions.retrieve", (id) => stripeSubscription({ id })),
      update: method("subscriptions.update", (id, params) =>
        stripeSubscription({
          id,
          cancelAtPeriodEnd: params.cancel_at_period_end ?? false,
          price: params.items?.[0]?.price ?? "price_pro_monthly",
        })),
      list: method("subscriptions.list", () => ({ data: [stripeSubscription()] })),
    },
  };
}

export const NOW_SECONDS = 1_765_000_000; // 2025-12-06T05:46:40Z

/** A Stripe Subscription in the 2025-10-29.clover shape (periods on items). */
export function stripeSubscription({
  id = "sub_123",
  customer = "cus_acme",
  status = "active",
  price = "price_pro_monthly",
  trialEnd = null,
  cancelAtPeriodEnd = false,
  metadata = { organization_id: ORG_ID },
} = {}) {
  return {
    id,
    object: "subscription",
    customer,
    status,
    cancel_at_period_end: cancelAtPeriodEnd,
    cancel_at: null,
    canceled_at: status === "canceled" ? NOW_SECONDS : null,
    ended_at: status === "canceled" ? NOW_SECONDS : null,
    trial_start: trialEnd ? NOW_SECONDS - 14 * 86400 : null,
    trial_end: trialEnd,
    metadata,
    items: {
      data: [{
        id: "si_123",
        price: { id: price },
        current_period_start: NOW_SECONDS,
        current_period_end: NOW_SECONDS + 30 * 86400,
      }],
    },
  };
}

let eventCounter = 0;
export function stripeEvent(type, object, { id, created = Math.floor(Date.now() / 1000) } = {}) {
  eventCounter += 1;
  return {
    id: id ?? `evt_test_${Date.now()}_${eventCounter}`,
    object: "event",
    api_version: "2025-10-29.clover",
    created,
    livemode: false,
    type,
    data: { object },
  };
}

/** Stripe-Signature header computed independently of the SDK (HMAC-SHA256). */
export async function signPayload(payload, secret = WEBHOOK_SECRET, timestamp = Math.floor(Date.now() / 1000)) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${payload}`));
  const hex = Array.from(new Uint8Array(mac), (b) => b.toString(16).padStart(2, "0")).join("");
  return `t=${timestamp},v1=${hex}`;
}

export async function webhookRequest(event, { secret = WEBHOOK_SECRET, timestamp, tamper } = {}) {
  const payload = JSON.stringify(event);
  const signature = await signPayload(payload, secret, timestamp);
  return new Request("http://localhost/stripe-webhook", {
    method: "POST",
    headers: { "stripe-signature": signature, "content-type": "application/json" },
    body: tamper ? tamper(payload) : payload,
  });
}

export function jsonRequest(body, { token, method = "POST", headers = {} } = {}) {
  return new Request("http://localhost/fn", {
    method,
    headers: {
      "content-type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: method === "GET" ? undefined : JSON.stringify(body),
  });
}

export async function readJson(response) {
  return { status: response.status, body: await response.json() };
}

export function baseDeps(overrides = {}) {
  return {
    config,
    logger: silentLogger,
    now: () => new Date("2025-12-06T05:46:40Z"),
    authenticate: fakeAuthenticate(),
    repo: fakeRepo(),
    stripe: fakeStripe(),
    cryptoProvider: Stripe.createSubtleCryptoProvider(),
    ...overrides,
  };
}
