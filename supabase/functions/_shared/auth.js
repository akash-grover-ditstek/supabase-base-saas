import { HttpError, httpErrorFromPostgrest } from "./http.js";

const BEARER = /^Bearer\s+([A-Za-z0-9._~+/=-]+)$/;

/**
 * Builds `authenticate(req)` which validates the caller's access token with
 * Supabase Auth (signature, expiry, revoked sessions) and returns the user
 * together with a user-scoped Supabase client.
 */
export function createAuthenticator({ createUserClient }) {
  return async function authenticate(req) {
    const header = (req.headers.get("Authorization") ?? "").trim();
    const match = BEARER.exec(header);
    if (!match) {
      throw new HttpError(401, "unauthorized", "Missing or malformed Authorization header");
    }

    const token = match[1];
    const client = createUserClient(token);
    const { data, error } = await client.auth.getUser(token);
    if (error || !data?.user) {
      throw new HttpError(401, "unauthorized", "Invalid or expired session");
    }
    if (data.user.is_anonymous) {
      throw new HttpError(403, "forbidden", "Anonymous users cannot perform this action");
    }

    return { user: data.user, client };
  };
}

/**
 * Asks PostgreSQL — as the calling user — whether they hold `role` in the
 * organization. The organization id from the request is never trusted on its
 * own: the database decides using auth.uid() from the JWT.
 */
export async function assertOrganizationRole(userClient, organizationId, role) {
  const { data, error } = await userClient.rpc("has_organization_role", {
    p_organization_id: organizationId,
    p_role: role,
  });
  if (error) throw httpErrorFromPostgrest(error, "Could not verify organization permissions");
  if (data !== true) {
    throw new HttpError(403, "forbidden", `This action requires the ${role} role in the organization`);
  }
}

/** Constant-time comparison for shared secrets. */
export function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const encoder = new TextEncoder();
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  let diff = left.length ^ right.length;
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
}
