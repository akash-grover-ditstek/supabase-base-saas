// Live-stack integration test support (REAL local Supabase: Auth, PostgREST,
// PostgreSQL, Edge Runtime). Stripe's API is still mocked here; see
// stripe-live.test.js for the opt-in real Stripe test-mode suite.
//
// Environment (exported by scripts/test.sh from `supabase status -o env`):
//   API_URL, ANON_KEY, SERVICE_ROLE_KEY, DB_URL
// Tests are skipped (ignored) when the variables are missing.

import { createClient } from "../../functions/_shared/deps.js";
import postgres from "npm:postgres@3.4.7";

const get = (...names) => names.map((n) => Deno.env.get(n)).find((v) => v && v.length > 0);

export const env = {
  url: get("SUPABASE_URL", "API_URL"),
  anonKey: get("SUPABASE_ANON_KEY", "ANON_KEY"),
  serviceRoleKey: get("SUPABASE_SERVICE_ROLE_KEY", "SERVICE_ROLE_KEY"),
  dbUrl: get("SUPABASE_DB_URL", "DB_URL"),
};

export const live = Boolean(env.url && env.anonKey && env.serviceRoleKey && env.dbUrl);

/** Options for Deno.test: skip without a stack; DB clients keep sockets open. */
export const liveTest = { ignore: !live, sanitizeOps: false, sanitizeResources: false };

const clientOptions = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };

export function serviceClient() {
  return createClient(env.url, env.serviceRoleKey, clientOptions);
}

export function userClient(accessToken) {
  return createClient(env.url, env.anonKey, {
    ...clientOptions,
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}

export function sql() {
  return postgres(env.dbUrl, { max: 6, onnotice: () => {}, idle_timeout: 5 });
}

export const uniqueSuffix = () => crypto.randomUUID().replaceAll("-", "").slice(0, 10);

/** Create a confirmed user through the Auth admin API and sign them in. */
export async function createTestUser(label) {
  const service = serviceClient();
  const email = `${label}.${uniqueSuffix()}@integration.test`;
  const password = `Pw-${crypto.randomUUID()}`;
  const { data, error } = await service.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw error;

  const anon = createClient(env.url, env.anonKey, clientOptions);
  const { data: session, error: signInError } = await anon.auth.signInWithPassword({ email, password });
  if (signInError) throw signInError;

  return {
    id: data.user.id,
    email,
    accessToken: session.session.access_token,
    client: userClient(session.session.access_token),
  };
}

/** Removes organizations and users created by a test (best effort). */
export async function cleanup(db, { organizationIds = [], userIds = [] }) {
  if (organizationIds.length) {
    await db`delete from public.organization_subscriptions where organization_id = any(${organizationIds}::uuid[])`;
    await db`delete from public.organizations where id = any(${organizationIds}::uuid[])`;
  }
  if (userIds.length) {
    await db`delete from auth.users where id = any(${userIds}::uuid[])`;
  }
}

export async function activePriceId(planCode, interval = "month") {
  const { data, error } = await serviceClient()
    .from("subscription_plan_prices")
    .select("stripe_price_id, subscription_plans!inner(code)")
    .eq("subscription_plans.code", planCode)
    .eq("billing_interval", interval)
    .eq("is_active", true)
    .limit(1)
    .single();
  if (error) {
    throw new Error(`No active ${planCode}/${interval} price (run supabase db reset to seed): ${error.message}`);
  }
  return data.stripe_price_id;
}

/** Webhook secret used by the locally served functions. */
export async function localWebhookSecret() {
  const fromEnv = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (fromEnv) return fromEnv;
  try {
    const file = await Deno.readTextFile(new URL("../../functions/.env", import.meta.url));
    return file.match(/^STRIPE_WEBHOOK_SECRET=(.+)$/m)?.[1]?.trim();
  } catch {
    return undefined;
  }
}
