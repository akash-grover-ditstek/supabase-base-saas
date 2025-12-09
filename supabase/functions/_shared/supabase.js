import { createClient } from "./deps.js";

const clientOptions = {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
};

/**
 * Privileged client (bypasses RLS). Only for server-side work that cannot be
 * done as the user: Stripe state writes, webhook ledger, audit events.
 */
export function createServiceClient(config) {
  return createClient(config.supabaseUrl, config.supabaseServiceRoleKey, clientOptions);
}

/**
 * Returns a factory for clients that act *as the calling user*: every query
 * and RPC runs under the user's JWT, so PostgreSQL RLS stays the authority.
 */
export function createUserClientFactory(config) {
  return (accessToken) =>
    createClient(config.supabaseUrl, config.supabaseAnonKey, {
      ...clientOptions,
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    });
}
