// INTEGRATION (real local database): concurrent membership changes.
//
// Two real PostgreSQL sessions act as two different users (role
// `authenticated` + JWT claims, exactly like PostgREST). Session A runs an
// RPC and keeps its transaction open; session B runs a conflicting RPC, which
// must block on the organization lock and — once A commits — fail against the
// new state instead of breaking an invariant.

import { assertEquals } from "jsr:@std/assert@1.0.14";
import { cleanup, createTestUser, liveTest, sql } from "./_env.js";

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function beginAs(conn, userId) {
  await conn`begin`;
  await conn.unsafe("set local lock_timeout = '15s'");
  await conn`select set_config('request.jwt.claims', ${JSON.stringify({ sub: userId, role: "authenticated" })}, true)`;
  await conn`select set_config('role', 'authenticated', true)`;
}

/** Start a query and report whether it is still blocked after `ms`. */
async function startBlocked(query, ms = 750) {
  const settled = query.then((rows) => ({ ok: true, rows }), (error) => ({ ok: false, error }));
  const state = await Promise.race([settled.then(() => "finished"), delay(ms).then(() => "blocked")]);
  return { state, settled };
}

async function setupOrganization(db, users, roles) {
  const [owner] = users;
  const { data: org, error } = await owner.client.rpc("create_organization", { p_name: "Concurrency Org" });
  if (error) throw error;
  for (const [user, role] of roles) {
    await db`insert into public.organization_members (organization_id, user_id, role) values (${org.id}, ${user.id}, ${role})`;
  }
  return org;
}

const rolesOf = async (db, orgId) =>
  Object.fromEntries(
    (await db`select user_id, role::text from public.organization_members where organization_id = ${orgId}`)
      .map((r) => [r.user_id, r.role]),
  );

Deno.test({
  name: "integration: concurrent ownership changes are serialized per organization",
  ...liveTest,
  fn: async (t) => {
    const db = sql();
    const [alice, bob, carol, dan] = await Promise.all(["alice", "bob", "carol", "dan"].map(createTestUser));
    const orgIds = [];
    const extraUserIds = [];

    try {
      await t.step("two owners demoting themselves at once cannot leave the organization ownerless", async () => {
        const org = await setupOrganization(db, [alice], [[bob, "owner"]]);
        orgIds.push(org.id);
        const a = await db.reserve();
        const b = await db.reserve();
        try {
          await beginAs(a, alice.id);
          await a`select public.update_organization_member_role(${org.id}, ${alice.id}, 'admin')`;

          await beginAs(b, bob.id);
          const race = await startBlocked(
            b`select public.update_organization_member_role(${org.id}, ${bob.id}, 'admin')`,
          );
          assertEquals(race.state, "blocked", "the second demotion waits for the organization lock");

          await a`commit`;
          const result = await race.settled;
          assertEquals(result.ok, false);
          assertEquals(result.error.code, "23514");
          await b`rollback`;
        } finally {
          a.release();
          b.release();
        }

        const roles = await rolesOf(db, org.id);
        assertEquals([roles[alice.id], roles[bob.id]], ["admin", "owner"]);
      });

      await t.step("a double-submitted ownership transfer only succeeds once", async () => {
        const org = await setupOrganization(db, [alice], [[carol, "member"], [dan, "member"]]);
        orgIds.push(org.id);
        const a = await db.reserve();
        const b = await db.reserve();
        try {
          await beginAs(a, alice.id);
          await a`select public.transfer_organization_ownership(${org.id}, ${carol.id})`;

          await beginAs(b, alice.id);
          const race = await startBlocked(b`select public.transfer_organization_ownership(${org.id}, ${dan.id})`);
          assertEquals(race.state, "blocked");

          await a`commit`;
          const result = await race.settled;
          assertEquals(result.ok, false);
          assertEquals(result.error.code, "42501", "after the first transfer alice is no longer an owner");
          await b`rollback`;
        } finally {
          a.release();
          b.release();
        }

        const roles = await rolesOf(db, org.id);
        assertEquals([roles[alice.id], roles[carol.id], roles[dan.id]], ["admin", "owner", "member"]);
      });

      await t.step("concurrent removal of the two remaining owners keeps one owner", async () => {
        const org = await setupOrganization(db, [alice], [[bob, "owner"]]);
        orgIds.push(org.id);
        const a = await db.reserve();
        const b = await db.reserve();
        try {
          await beginAs(a, alice.id);
          await a`select public.remove_organization_member(${org.id}, ${bob.id})`;

          await beginAs(b, bob.id);
          const race = await startBlocked(b`select public.remove_organization_member(${org.id}, ${alice.id})`);
          assertEquals(race.state, "blocked");

          await a`commit`;
          const result = await race.settled;
          assertEquals(result.ok, false);
          assertEquals(result.error.code, "42501", "bob was removed and lost his rights before his request ran");
          await b`rollback`;
        } finally {
          a.release();
          b.release();
        }

        const roles = await rolesOf(db, org.id);
        assertEquals(roles, { [alice.id]: "owner" });
      });

      await t.step("concurrent invitation acceptances cannot exceed the plan's seat limit", async () => {
        // Free plan: 5 seats. 3 members + 2 pending invitations, then a 4th
        // member joins directly: only one of the two invitees may get the last seat.
        const [nina, omar, extra] = await Promise.all(["nina", "omar", "extra"].map(createTestUser));
        const org = await setupOrganization(db, [alice], [[carol, "member"], [dan, "member"]]);
        orgIds.push(org.id);

        const invite = async (email) => {
          const { data, error } = await alice.client.rpc("invite_organization_member", {
            p_organization_id: org.id,
            p_email: email,
          });
          if (error) throw error;
          return data.id;
        };
        const ninaInvite = await invite(nina.email);
        const omarInvite = await invite(omar.email);
        await db`insert into public.organization_members (organization_id, user_id) values (${org.id}, ${extra.id})`;

        const a = await db.reserve();
        const b = await db.reserve();
        try {
          await beginAs(a, nina.id);
          await a`select public.accept_organization_invitation(${ninaInvite})`;

          await beginAs(b, omar.id);
          const race = await startBlocked(b`select public.accept_organization_invitation(${omarInvite})`);
          assertEquals(race.state, "blocked");

          await a`commit`;
          const result = await race.settled;
          assertEquals(result.ok, false);
          assertEquals(result.error.code, "54000");
          await b`rollback`;
        } finally {
          a.release();
          b.release();
        }

        const members =
          await db`select count(*)::int as n from public.organization_members where organization_id = ${org.id}`;
        assertEquals(members[0].n, 5);
        extraUserIds.push(nina.id, omar.id, extra.id);
      });
    } finally {
      await cleanup(db, { organizationIds: orgIds, userIds: [alice.id, bob.id, carol.id, dan.id, ...extraUserIds] });
      await db.end();
    }
  },
});
