// Production wiring for Edge Functions. Handlers receive their dependencies
// explicitly (see each function's handler.js), which keeps them testable with
// mocks; this module builds the real ones from environment configuration.

import { createAuthenticator } from "./auth.js";
import { createBillingRepository } from "./billing-repository.js";
import { loadConfig, missingConfig } from "./config.js";
import { errorBody, json } from "./http.js";
import { createLogger } from "./logger.js";
import { createStripeClient, createStripeCryptoProvider } from "./stripe.js";
import { createServiceClient, createUserClientFactory } from "./supabase.js";

export function createDependencies(config, logger) {
  const serviceClient = createServiceClient(config);
  return {
    config,
    logger,
    now: () => new Date(),
    serviceClient,
    repo: createBillingRepository(serviceClient),
    authenticate: createAuthenticator({ createUserClient: createUserClientFactory(config) }),
    stripe: config.stripeSecretKey ? createStripeClient(config) : null,
    cryptoProvider: createStripeCryptoProvider(),
  };
}

/**
 * Start an Edge Function. Dependencies are created on the first request so a
 * missing secret yields a clean 500 instead of a crashed worker.
 */
export function serveFunction(name, requiredConfig, buildHandler) {
  const logger = createLogger(name);
  let handler = null;

  Deno.serve((req) => {
    if (!handler) {
      const config = loadConfig();
      const missing = missingConfig(config, requiredConfig);
      if (missing.length > 0) {
        logger.error("missing configuration", { missing });
        return json(errorBody("server_misconfigured", "The service is not configured"), 500);
      }
      handler = buildHandler(createDependencies(config, logger));
    }
    return handler(req);
  });
}
