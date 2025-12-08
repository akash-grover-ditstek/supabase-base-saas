import { serveFunction } from "../_shared/runtime.js";
import { createInviteMemberHandler } from "./handler.js";
import { createInviteMailer } from "./mailer.js";

serveFunction(
  "invite-organization-member",
  ["supabaseUrl", "supabaseAnonKey", "supabaseServiceRoleKey"],
  (deps) =>
    createInviteMemberHandler({
      ...deps,
      inviteMailer: createInviteMailer(deps.serviceClient, deps.config, deps.logger),
    }),
);
