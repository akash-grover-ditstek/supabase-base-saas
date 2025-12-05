// HTTP helpers shared by all Edge Functions: structured JSON responses,
// consistent error envelopes and safe error handling.

import { createLogger } from "./logger.js";

const MAX_JSON_BODY_BYTES = 64 * 1024;

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** An error that is safe to show to the caller. */
export class HttpError extends Error {
  constructor(status, code, message, details = undefined) {
    super(message);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

export function json(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...extraHeaders },
  });
}

export function errorBody(code, message, details) {
  return { error: details === undefined ? { code, message } : { code, message, details } };
}

/**
 * Wrap a request handler with method checks, CORS and error handling.
 * Unexpected errors are logged server-side and returned as a generic 500 so
 * internal details (SQL, Stripe responses, stack traces) never leak.
 */
export function withHandler(handler, { name, methods = ["POST"], cors = true, logger } = {}) {
  const log = logger ?? createLogger(name ?? "edge-function");
  const baseHeaders = cors ? corsHeaders : {};

  return async (req) => {
    if (cors && req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }
    if (!methods.includes(req.method)) {
      return json(errorBody("method_not_allowed", `Use ${methods.join(", ")}`), 405, {
        ...baseHeaders,
        Allow: methods.join(", "),
      });
    }

    try {
      const response = await handler(req);
      for (const [key, value] of Object.entries(baseHeaders)) response.headers.set(key, value);
      return response;
    } catch (err) {
      if (err instanceof HttpError) {
        if (err.status >= 500) log.error("request failed", { code: err.code, error: err.message });
        return json(errorBody(err.code, err.message, err.details), err.status, baseHeaders);
      }
      log.error("unhandled error", { error: err?.message ?? String(err) });
      return json(errorBody("internal_error", "An unexpected error occurred"), 500, baseHeaders);
    }
  };
}

/** Parse a JSON object body with a size limit. */
export async function readJsonObject(req) {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_JSON_BODY_BYTES) {
    throw new HttpError(413, "payload_too_large", "Request body is too large");
  }
  const text = await req.text();
  if (text.length > MAX_JSON_BODY_BYTES) {
    throw new HttpError(413, "payload_too_large", "Request body is too large");
  }
  let body;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    throw new HttpError(400, "invalid_json", "Request body must be valid JSON");
  }
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    throw new HttpError(400, "invalid_json", "Request body must be a JSON object");
  }
  return body;
}

/**
 * Translate a PostgREST/PostgreSQL error raised by our RPCs into an HttpError.
 * Messages raised by our own functions are written to be user-safe; anything
 * unexpected collapses to a generic message.
 */
export function httpErrorFromPostgrest(error, fallbackMessage = "Database request failed") {
  const code = error?.code;
  const message = error?.message ?? fallbackMessage;
  switch (code) {
    case "42501":
      return new HttpError(403, "forbidden", message);
    case "22023":
    case "22P02":
      return new HttpError(400, "invalid_request", message);
    case "23505":
      return new HttpError(409, "conflict", message);
    case "23514":
    case "55000":
      return new HttpError(409, "precondition_failed", message);
    case "54000":
      return new HttpError(402, "plan_limit_reached", message);
    case "P0002":
      return new HttpError(404, "not_found", message);
    default:
      return new HttpError(500, "database_error", fallbackMessage);
  }
}
