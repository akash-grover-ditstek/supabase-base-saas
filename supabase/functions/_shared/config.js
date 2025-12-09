// Configuration is read from environment variables only (Supabase secrets in
// production, supabase/functions/.env locally). Values are never logged.

export function loadConfig(env = Deno.env) {
  const get = (name) => {
    const value = env.get(name);
    return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
  };

  return {
    // Injected automatically by the Supabase Edge Runtime.
    supabaseUrl: get("SUPABASE_URL"),
    supabaseAnonKey: get("SUPABASE_ANON_KEY"),
    supabaseServiceRoleKey: get("SUPABASE_SERVICE_ROLE_KEY"),
    // Project secrets.
    stripeSecretKey: get("STRIPE_SECRET_KEY"),
    stripeWebhookSecret: get("STRIPE_WEBHOOK_SECRET"),
    appUrl: (get("APP_URL") ?? "http://localhost:3000").replace(/\/+$/, ""),
    internalSyncSecret: get("INTERNAL_SYNC_SECRET"),
  };
}

/** Names of required configuration keys that are missing. */
export function missingConfig(config, keys) {
  return keys.filter((key) => !config[key]);
}
