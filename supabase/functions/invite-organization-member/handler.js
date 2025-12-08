// POST /functions/v1/invite-organization-member
// Body: { organization_id, email, role?: "member" | "admin" }
//
// 1. Creates the invitation by calling public.invite_organization_member()
//    AS THE CALLER — PostgreSQL enforces the role hierarchy, duplicate and
//    seat-limit rules; this function adds no authorization of its own.
// 2. Delivers it: Supabase Auth invite email for new users, in-app for
//    existing accounts. Delivery failure does not roll back the invitation.

import { requireOrganizationId } from "../_shared/billing.js";
import { HttpError, httpErrorFromPostgrest, json, readJsonObject, withHandler } from "../_shared/http.js";

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const ROLES = new Set(["member", "admin"]);

export function createInviteMemberHandler({ authenticate, inviteMailer, logger }) {
  return withHandler(async (req) => {
    const { user, client } = await authenticate(req);
    const body = await readJsonObject(req);
    const organizationId = requireOrganizationId(body);

    const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
    if (!EMAIL.test(email) || email.length > 320) {
      throw new HttpError(400, "invalid_request", "A valid email address is required");
    }
    const role = body.role ?? "member";
    if (!ROLES.has(role)) {
      throw new HttpError(400, "invalid_request", "role must be 'member' or 'admin'");
    }

    const { data: invitation, error } = await client.rpc("invite_organization_member", {
      p_organization_id: organizationId,
      p_email: email,
      p_role: role,
    });
    if (error) throw httpErrorFromPostgrest(error, "Could not create invitation");

    const delivery = await inviteMailer.deliver(email);
    logger.info("invitation created", { organization_id: organizationId, invited_by: user.id, delivery });

    return json({
      invitation: {
        id: invitation.id,
        organization_id: invitation.organization_id,
        email: invitation.email,
        role: invitation.role,
        status: invitation.status,
        expires_at: invitation.expires_at,
      },
      delivery,
    }, 201);
  }, { name: "invite-organization-member", logger });
}
