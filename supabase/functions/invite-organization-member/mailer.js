// Delivers organization invitations.
//
// New users receive a Supabase Auth invite email (creates the account; the
// invitee confirms their email by following the link). Existing users already
// have an account and see the invitation in-app via
// public.get_my_pending_invitations(); no token is ever sent by email —
// acceptance is bound to the invitee's confirmed email address in SQL.

export function createInviteMailer(serviceClient, config, logger) {
  return {
    async deliver(email) {
      const { error } = await serviceClient.auth.admin.inviteUserByEmail(email, {
        redirectTo: `${config.appUrl}/invitations`,
      });
      if (!error) return "auth_invite_email_sent";

      const code = error.code ?? "";
      if (code === "email_exists" || error.status === 422 || /already been registered/i.test(error.message ?? "")) {
        return "existing_account_in_app";
      }

      logger.warn("invitation email delivery failed", { status: error.status, code });
      return "delivery_failed";
    },
  };
}
