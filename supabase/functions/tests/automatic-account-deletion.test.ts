import { handleAutomaticAccountDeletion } from "../automatic-account-deletion/index.ts";
import { handleAccountDeletionReceipt } from "../account-deletion-receipt/index.ts";
import type { DatabaseGateway } from "../_shared/database.ts";
import { softDeleteAndVerifyIdentity } from "../_shared/identity-deletion.ts";
import { handleRequestAccountDeletion } from "../request-account-deletion/index.ts";

const ID = "71000000-0000-4000-8000-000000000001";
const TOKEN = "d".repeat(64);
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(a: unknown, b: unknown) {
  assert(JSON.stringify(a) === JSON.stringify(b), "values differ");
}
class Database implements DatabaseGateway {
  calls: Array<{ name: string; parameters: Record<string, unknown> }> = [];
  values: Record<string, unknown> = {};
  handler?: (name: string, parameters: Record<string, unknown>) => unknown;
  rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T> {
    this.calls.push({ name, parameters });
    const value = this.handler
      ? this.handler(name, parameters)
      : this.values[name];
    return value instanceof Error
      ? Promise.reject(value)
      : Promise.resolve(value as T);
  }
}
function request(body: unknown, token?: string) {
  return new Request("https://catalog.example/functions/v1/account-deletion", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(token ? { "x-wali-account-deletion-token": token } : {}),
    },
    body: JSON.stringify(body),
  });
}
function dependencies(database: Database) {
  return {
    database,
    dispatchToken: TOKEN,
    now: () => new Date("2026-09-13T12:00:00Z"),
    revokeApple: () => Promise.reject(new Error("unexpected Apple call")),
    deleteIdentity: () => Promise.reject(new Error("unexpected identity call")),
  };
}

for (const token of [undefined, "user-jwt", "a".repeat(64)]) {
  Deno.test("deletion dispatcher rejects an unrelated credential before database access", async () => {
    const db = new Database();
    equal(
      (await handleAutomaticAccountDeletion(
        request({ api_version: "account_deletion_worker.v1" }, token),
        dependencies(db),
      )).status,
      401,
    );
    equal(db.calls.length, 0);
  });
}
Deno.test("deletion dispatcher rejects caller-selected identity", async () => {
  const db = new Database();
  equal(
    (await handleAutomaticAccountDeletion(
      request(
        { api_version: "account_deletion_worker.v1", user_id: ID },
        TOKEN,
      ),
      dependencies(db),
    )).status,
    400,
  );
  equal(db.calls.length, 0);
});

const RUN = "71000000-0000-4000-8000-000000000002";
const JOB = "71000000-0000-4000-8000-000000000003";
const LEASE = "71000000-0000-4000-8000-000000000004";
function oneJobDatabase(bindings: unknown[] = []) {
  const db = new Database();
  let claims = 0;
  db.handler = (name, p) => {
    if (name === "wali_edge_begin_account_deletion_dispatch_v1") {
      return { run_token: RUN };
    }
    if (name === "wali_edge_end_account_deletion_dispatch_v1") return true;
    if (name === "wali_edge_claim_account_deletion_v1") {
      return {
        job: claims++ === 0
          ? { job_id: JOB, lease_token: LEASE, revision: 1 }
          : null,
      };
    }
    equal(p.run_token, RUN);
    equal(p.job_id, JOB);
    equal(p.lease_token, LEASE);
    if (name === "wali_edge_prepare_automatic_account_deletion_v1") {
      return {
        user_id: ID,
        deletion_id: JOB,
        revision: 2,
        apple_authorizations: bindings,
      };
    }
    if (name === "wali_edge_checkpoint_account_apple_revocation_v1") {
      return { revision: Number(p.expected_revision) + 1 };
    }
    if (name === "wali_edge_authorize_account_identity_deletion_v1") {
      return { user_id: ID, revision: Number(p.expected_revision) + 1 };
    }
    if (name === "wali_edge_finalize_automatic_account_deletion_v1") {
      return { completed: true, revision: Number(p.expected_revision) + 1 };
    }
    if (name === "wali_edge_retry_account_deletion_v1") return true;
    throw new Error("unexpected RPC");
  };
  return db;
}
function appleRow(client = "com.wali.store.WALI") {
  return {
    actor_id: ID,
    client_id: client,
    apple_subject: "synthetic-subject",
    encrypted_refresh_token: `v1.${"a".repeat(16)}.${"b".repeat(48)}`,
    encryption_key_version: "fixture",
    revision: 4,
  };
}
Deno.test("deletion uses each exact Apple binding before authorizing the same identity", async () => {
  const db = oneJobDatabase([
    appleRow(),
    appleRow("com.wali.store.development.WALI"),
  ]);
  const events: string[] = [];
  const response = await handleAutomaticAccountDeletion(
    request({ api_version: "account_deletion_worker.v1" }, TOKEN),
    {
      ...dependencies(db),
      revokeApple: (binding) => {
        events.push(binding.clientID);
        return Promise.resolve();
      },
      deleteIdentity: (actor) => {
        equal(actor, ID);
        events.push("identity");
        return Promise.resolve();
      },
    },
  );
  equal(response.status, 200);
  equal(events, [
    "com.wali.store.WALI",
    "com.wali.store.development.WALI",
    "identity",
  ]);
  equal(
    db.calls.filter((c) => c.name.includes("checkpoint")).map((c) =>
      c.parameters.expected_revision
    ),
    [2, 3],
  );
  equal((await response.json()).data, {
    processed: 1,
    completed: 1,
    retrying: 0,
  });
});
Deno.test("Apple failure keeps the same lease for retry and never deletes identity", async () => {
  const db = oneJobDatabase([appleRow()]);
  const response = await handleAutomaticAccountDeletion(
    request({ api_version: "account_deletion_worker.v1" }, TOKEN),
    dependencies(db),
  );
  equal((await response.json()).data, {
    processed: 1,
    completed: 0,
    retrying: 1,
  });
  assert(
    !db.calls.some((c) =>
      c.name.includes("authorize_account_identity") ||
      c.name.includes("finalize_automatic")
    ),
  );
  const retry = db.calls.find((c) =>
    c.name === "wali_edge_retry_account_deletion_v1"
  )!;
  equal(retry.parameters, {
    run_token: RUN,
    job_id: JOB,
    lease_token: LEASE,
    expected_revision: 2,
    safe_error_code: "WALI_ACCOUNT_DELETION_RETRYING",
  });
});
Deno.test("lost checkpoint reply never advances to identity deletion", async () => {
  const db = oneJobDatabase([appleRow()]);
  const original = db.handler!;
  db.handler = (name, p) =>
    name.includes("checkpoint_account_apple")
      ? new Error("response lost")
      : original(name, p);
  const response = await handleAutomaticAccountDeletion(
    request({ api_version: "account_deletion_worker.v1" }, TOKEN),
    {
      ...dependencies(db),
      revokeApple: () => Promise.resolve(),
    },
  );
  equal((await response.json()).data.completed, 0);
  assert(!db.calls.some((c) => c.name.includes("authorize_account_identity")));
});
Deno.test("insufficient run budget leaves the authorized job resumable without starting a provider call", async () => {
  const db = oneJobDatabase();
  let elapsed = 0;
  const original = db.handler!;
  db.handler = (name, p) => {
    const value = original(name, p);
    if (name.includes("authorize_account_identity")) elapsed = 39_000;
    return value;
  };
  const response = await handleAutomaticAccountDeletion(
    request({ api_version: "account_deletion_worker.v1" }, TOKEN),
    {
      ...dependencies(db),
      now: () => new Date(Date.parse("2026-09-13T12:00:00Z") + elapsed),
    },
  );
  equal((await response.json()).data.completed, 0);
  assert(!db.calls.some((c) => c.name.includes("finalize_automatic")));
});
Deno.test("wrong prepared Apple actor or identity authorization cannot redirect deletion", async () => {
  for (const mode of ["apple", "identity"]) {
    const db = oneJobDatabase(
      mode === "apple" ? [{ ...appleRow(), actor_id: RUN }] : [],
    );
    const original = db.handler!;
    db.handler = (name, p) =>
      mode === "identity" && name.includes("authorize_account_identity")
        ? { user_id: RUN, revision: 3 }
        : original(name, p);
    let providerCalls = 0;
    const response = await handleAutomaticAccountDeletion(
      request({ api_version: "account_deletion_worker.v1" }, TOKEN),
      {
        ...dependencies(db),
        revokeApple: () => {
          providerCalls++;
          return Promise.resolve();
        },
        deleteIdentity: () => {
          providerCalls++;
          return Promise.resolve();
        },
      },
    );
    equal(providerCalls, 0);
    equal((await response.json()).data.completed, 0);
  }
});
Deno.test("Auth verification rejects another returned subject, active identity and oversized reply", async () => {
  for (
    const returned of [{ id: RUN, deleted_at: "2026-09-13T00:00:00Z" }, {
      id: ID,
      deleted_at: null,
    }, { id: ID, deleted_at: "x".repeat(70000) }]
  ) {
    let rejected = false;
    try {
      await softDeleteAndVerifyIdentity(ID, {
        supabaseURL: "https://catalog.example",
        serviceRoleKey: "synthetic-test-authority",
        fetcher: (_input, init) =>
          Promise.resolve(
            init?.method === "DELETE"
              ? Response.json({})
              : Response.json(returned),
          ),
      });
    } catch {
      rejected = true;
    }
    assert(rejected);
  }
});
Deno.test("v2 consent carries only the real authenticated subject and committed receipt hash", async () => {
  const db = new Database();
  db.values.wali_edge_take_rate_limit_v1 = {
    allowed: true,
    retry_after_seconds: 0,
  };
  db.values.wali_edge_request_account_deletion_v2 = {
    deletion_id: JOB,
    status: "deletion_pending",
    revision: 2,
  };
  db.values.wali_edge_mark_account_deletion_sessions_revoked_v1 = {
    deletion_id: JOB,
    status: "deletion_pending",
    auth_identity_status: "sessions_revoked",
    revision: 3,
  };
  const response = await handleRequestAccountDeletion(
    request({
      api_version: "account.v2",
      request_id: RUN,
      idempotency_key: RUN,
      expected_profile_revision: 1,
      confirmation: "DELETE MY WALI",
      status_capability_hash: "1".repeat(64),
      policy_version: "2026-09-13",
    }),
    {
      database: db,
      now: () => new Date("2026-09-13T12:00:00Z"),
      supabaseURL: "https://catalog.example",
      serviceRoleKey: "synthetic-test-authority",
      publishableKey: "synthetic-public",
      fetcher: fetch,
      authenticate: () =>
        Promise.resolve({
          actorID: ID,
          assuranceLevel: "aal2",
          authenticatedAt: Date.parse("2026-09-13T11:59:59Z") / 1000,
          accessToken: "synthetic",
          expiresAt: 2000000000,
        }),
    },
  );
  equal(response.status, 202);
  equal((await response.json()).api_version, "account.v2");
  const call = db.calls.find((c) =>
    c.name === "wali_edge_request_account_deletion_v2"
  )!;
  equal(call.parameters.actor_id, ID);
  equal(call.parameters.status_capability_hash, "1".repeat(64));
  assert(!Object.hasOwn(call.parameters, "capability"));
});
Deno.test("global dispatcher lease refuses a duplicate run without claiming a deletion", async () => {
  const db = new Database();
  db.values.wali_edge_begin_account_deletion_dispatch_v1 = { run_token: null };
  equal(
    (await handleAutomaticAccountDeletion(
      request({ api_version: "account_deletion_worker.v1" }, TOKEN),
      dependencies(db),
    )).status,
    200,
  );
  equal(db.calls.map((c) => c.name), [
    "wali_edge_begin_account_deletion_dispatch_v1",
  ]);
});
Deno.test("status hashes the decoded capability and does not require or accept a subject", async () => {
  const db = new Database();
  db.values.wali_edge_account_deletion_receipt_v1 = {
    status: "pending",
    stage: "cleanup",
    requested_at: "2026-09-13T12:00:00Z",
    completed_at: null,
    status_expires_at: null,
    retained_categories: [],
    apple_action_required: false,
  };
  const capability = "01".repeat(32);
  const response = await handleAccountDeletionReceipt(
    request({
      api_version: "account_deletion_receipt.v1",
      request_id: ID,
      capability,
    }),
    { database: db },
  );
  equal(response.status, 200);
  const expected = [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", new Uint8Array(32).fill(1)),
    ),
  ].map((v) => v.toString(16).padStart(2, "0")).join("");
  equal(db.calls, [{
    name: "wali_edge_account_deletion_receipt_v1",
    parameters: { capability_hash: expected },
  }]);
  equal(
    (await handleAccountDeletionReceipt(
      request({
        api_version: "account_deletion_receipt.v1",
        request_id: ID,
        capability,
        user_id: ID,
      }),
      { database: db },
    )).status,
    400,
  );
});
Deno.test("receipt never reflects unexpected database identity or token fields", async () => {
  const db = new Database();
  db.values.wali_edge_account_deletion_receipt_v1 = {
    status: "completed",
    user_id: ID,
    token: "must-not-leak",
  };
  const response = await handleAccountDeletionReceipt(
    request({
      api_version: "account_deletion_receipt.v1",
      request_id: ID,
      capability: "02".repeat(32),
    }),
    { database: db },
  );
  equal(response.status, 503);
  assert(!(await response.text()).includes("must-not-leak"));
});
