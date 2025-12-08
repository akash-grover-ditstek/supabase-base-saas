// MOCKED tests: invite-organization-member.
// Authorization is delegated to PostgreSQL (the RPC runs as the caller); these
// tests verify the function forwards the caller's identity and maps errors.

import { assertEquals } from "jsr:@std/assert@1.0.14";
import { createInviteMemberHandler } from "../../functions/invite-organization-member/handler.js";
import { baseDeps, fakeAuthenticate, jsonRequest, ORG_ID, readJson } from "./_helpers.js";

function deps({ rpcResult, delivery = "auth_invite_email_sent" } = {}) {
  const rpcCalls = [];
  const mailerCalls = [];
  return {
    rpcCalls,
    mailerCalls,
    deps: baseDeps({
      authenticate: fakeAuthenticate({
        rpc: {
          invite_organization_member: (args, user) => {
            rpcCalls.push({ args, user });
            return rpcResult ?? {
              data: {
                id: "inv_1",
                organization_id: ORG_ID,
                email: args.p_email,
                role: args.p_role,
                status: "pending",
                expires_at: "2025-12-13T00:00:00Z",
              },
              error: null,
            };
          },
        },
      }),
      inviteMailer: {
        deliver: (email) => {
          mailerCalls.push(email);
          return Promise.resolve(delivery);
        },
      },
    }),
  };
}

Deno.test("invite: creates the invitation as the caller and delivers it", async () => {
  const { deps: d, rpcCalls, mailerCalls } = deps();
  const res = await readJson(
    await createInviteMemberHandler(d)(
      jsonRequest({ organization_id: ORG_ID, email: "  New.Person@Example.test " }, { token: "admin" }),
    ),
  );
  assertEquals(res.status, 201);
  assertEquals(res.body.invitation.email, "new.person@example.test");
  assertEquals(res.body.delivery, "auth_invite_email_sent");
  assertEquals(rpcCalls[0].user.email, "admin@acme.test");
  assertEquals(rpcCalls[0].args, { p_organization_id: ORG_ID, p_email: "new.person@example.test", p_role: "member" });
  assertEquals(mailerCalls, ["new.person@example.test"]);
});

Deno.test("invite: database authorization errors are returned, nothing is sent", async () => {
  const cases = [
    [{ code: "42501", message: "Not authorized to invite members to this organization" }, 403],
    [{ code: "23505", message: "A pending invitation already exists for this email" }, 409],
    [{ code: "54000", message: "Seat limit reached for the Free plan" }, 402],
  ];
  for (const [error, status] of cases) {
    const { deps: d, mailerCalls } = deps({ rpcResult: { data: null, error } });
    const res = await readJson(
      await createInviteMemberHandler(d)(
        jsonRequest({ organization_id: ORG_ID, email: "x@example.test" }, { token: "member" }),
      ),
    );
    assertEquals(res.status, status, error.code);
    assertEquals(res.body.error.message, error.message);
    assertEquals(mailerCalls.length, 0);
  }
});

Deno.test("invite: input validation (email, role)", async () => {
  const { deps: d, rpcCalls } = deps();
  for (
    const body of [
      { organization_id: ORG_ID, email: "not-an-email" },
      { organization_id: ORG_ID, email: "x@example.test", role: "owner" },
      { organization_id: "acme", email: "x@example.test" },
    ]
  ) {
    const res = await createInviteMemberHandler(d)(jsonRequest(body, { token: "owner" }));
    assertEquals(res.status, 400, JSON.stringify(body));
  }
  assertEquals(rpcCalls.length, 0);
});

Deno.test("invite: existing accounts are notified in-app", async () => {
  const { deps: d } = deps({ delivery: "existing_account_in_app" });
  const res = await readJson(
    await createInviteMemberHandler(d)(
      jsonRequest({ organization_id: ORG_ID, email: "dave@globex.test" }, { token: "owner" }),
    ),
  );
  assertEquals(res.status, 201);
  assertEquals(res.body.delivery, "existing_account_in_app");
});

Deno.test("invite: unauthenticated callers are rejected", async () => {
  const { deps: d, rpcCalls } = deps();
  const res = await createInviteMemberHandler(d)(jsonRequest({ organization_id: ORG_ID, email: "x@example.test" }));
  assertEquals(res.status, 401);
  assertEquals(rpcCalls.length, 0);
});
