// Unit tests for shared Edge Function modules (pure, no network).

import { assert, assertEquals, assertFalse, assertRejects } from "jsr:@std/assert@1.0.14";
import { timingSafeEqual } from "../../functions/_shared/auth.js";
import {
  invoiceSubscriptionId,
  normalizeSubscription,
  parsePlanSelection,
  requireOrganizationId,
} from "../../functions/_shared/billing.js";
import { HttpError, httpErrorFromPostgrest, readJsonObject, withHandler } from "../../functions/_shared/http.js";
import { silentLogger } from "../../functions/_shared/logger.js";
import { fakeAuthenticate, NOW_SECONDS, ORG_ID, stripeSubscription } from "./_helpers.js";

Deno.test("normalizeSubscription reads billing periods from items (API >= 2025-03-31)", () => {
  const normalized = normalizeSubscription(stripeSubscription({ status: "trialing", trialEnd: NOW_SECONDS + 86400 }));
  assertEquals(normalized.id, "sub_123");
  assertEquals(normalized.customer, "cus_acme");
  assertEquals(normalized.status, "trialing");
  assertEquals(normalized.price_id, "price_pro_monthly");
  assertEquals(normalized.current_period_end, new Date((NOW_SECONDS + 30 * 86400) * 1000).toISOString());
  assertEquals(normalized.trial_end, new Date((NOW_SECONDS + 86400) * 1000).toISOString());
  assertEquals(normalized.metadata_organization_id, ORG_ID);
});

Deno.test("normalizeSubscription supports legacy top-level periods and expanded customers", () => {
  const legacy = {
    id: "sub_legacy",
    customer: { id: "cus_acme", object: "customer" },
    status: "active",
    current_period_start: NOW_SECONDS,
    current_period_end: NOW_SECONDS + 100,
    items: { data: [{ price: { id: "price_x" } }] },
  };
  const normalized = normalizeSubscription(legacy);
  assertEquals(normalized.customer, "cus_acme");
  assertEquals(normalized.current_period_end, new Date((NOW_SECONDS + 100) * 1000).toISOString());
  assertEquals(normalized.cancel_at_period_end, false);
  assertEquals(normalized.metadata_organization_id, null);
});

Deno.test("invoiceSubscriptionId handles legacy and current invoice shapes", () => {
  assertEquals(invoiceSubscriptionId({ subscription: "sub_old" }), "sub_old");
  assertEquals(
    invoiceSubscriptionId({ parent: { subscription_details: { subscription: "sub_new" } } }),
    "sub_new",
  );
  assertEquals(invoiceSubscriptionId({ id: "in_oneoff" }), null);
});

Deno.test("plan selection only accepts plan codes and known intervals", () => {
  assertEquals(parsePlanSelection({ plan_code: "pro" }), { planCode: "pro", interval: "month" });
  assertEquals(parsePlanSelection({ plan_code: "business", interval: "year" }).interval, "year");
  for (const body of [{}, { plan_code: "price_123; drop" }, { plan_code: "pro", interval: "week" }]) {
    let error;
    try {
      parsePlanSelection(body);
    } catch (err) {
      error = err;
    }
    assert(error instanceof HttpError && error.status === 400, JSON.stringify(body));
  }
});

Deno.test("organization ids must be UUIDs", () => {
  assertEquals(requireOrganizationId({ organization_id: ORG_ID.toUpperCase() }), ORG_ID);
  for (const value of [undefined, "", "acme", "1 or 1=1", 42]) {
    let error;
    try {
      requireOrganizationId({ organization_id: value });
    } catch (err) {
      error = err;
    }
    assertEquals(error?.status, 400);
  }
});

Deno.test("PostgreSQL error codes map to HTTP statuses without leaking unknown errors", () => {
  assertEquals(httpErrorFromPostgrest({ code: "42501", message: "Only owners" }).status, 403);
  assertEquals(httpErrorFromPostgrest({ code: "23505", message: "dup" }).status, 409);
  assertEquals(httpErrorFromPostgrest({ code: "54000", message: "limit" }).code, "plan_limit_reached");
  assertEquals(httpErrorFromPostgrest({ code: "P0002", message: "missing" }).status, 404);
  const unknown = httpErrorFromPostgrest({ code: "XX000", message: "relation secret_table does not exist" }, "Failed");
  assertEquals(unknown.status, 500);
  assertEquals(unknown.message, "Failed");
});

Deno.test("withHandler hides unexpected errors and rejects other methods", async () => {
  const handler = withHandler(() => {
    throw new Error("connection string postgres://user:secret@db");
  }, { logger: silentLogger });

  const res = await handler(new Request("http://localhost", { method: "POST" }));
  assertEquals(res.status, 500);
  const body = await res.json();
  assertEquals(body, { error: { code: "internal_error", message: "An unexpected error occurred" } });

  const getRes = await handler(new Request("http://localhost", { method: "GET" }));
  assertEquals(getRes.status, 405);

  const preflight = await handler(new Request("http://localhost", { method: "OPTIONS" }));
  assertEquals(preflight.status, 204);
});

Deno.test("readJsonObject rejects invalid, non-object and oversized bodies", async () => {
  const req = (body) => new Request("http://localhost", { method: "POST", body });
  await assertRejects(() => readJsonObject(req("{not json")), HttpError, "valid JSON");
  await assertRejects(() => readJsonObject(req("[1,2]")), HttpError, "JSON object");
  await assertRejects(() => readJsonObject(req("x".repeat(70 * 1024))), HttpError, "too large");
  assertEquals(await readJsonObject(req('{"a":1}')), { a: 1 });
});

Deno.test("authenticator requires a valid, non-anonymous bearer token", async () => {
  const authenticate = fakeAuthenticate();
  const request = (authorization) =>
    new Request("http://localhost", { method: "POST", headers: authorization ? { Authorization: authorization } : {} });

  await assertRejects(() => authenticate(request()), HttpError, "Missing");
  await assertRejects(() => authenticate(request("Basic abc")), HttpError, "Missing");
  await assertRejects(() => authenticate(request("Bearer forged-token")), HttpError, "Invalid or expired");
  await assertRejects(() => authenticate(request("Bearer anonymous")), HttpError, "Anonymous");
  const { user } = await authenticate(request("Bearer owner"));
  assertEquals(user.email, "owner@acme.test");
});

Deno.test("timingSafeEqual compares secrets exactly", () => {
  assert(timingSafeEqual("secret-value", "secret-value"));
  assertFalse(timingSafeEqual("secret-value", "secret-valuf"));
  assertFalse(timingSafeEqual("secret", "secret-value"));
  assertFalse(timingSafeEqual(undefined, "secret"));
});
