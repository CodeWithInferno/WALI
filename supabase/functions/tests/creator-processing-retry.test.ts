import { handleCreatorCommand } from "../creator-command/index.ts";
import { EdgeError } from "../_shared/errors.ts";
import type { DatabaseGateway } from "../_shared/database.ts";
import type { EndpointDependencies } from "../_shared/runtime.ts";
const actor = "00000000-0000-4000-8000-000000000003",
  id = "70000000-0000-4000-8000-000000000001";
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function fixture(
  patch: Record<string, unknown> = {},
  responsePatch: Record<string, unknown> = {},
) {
  const calls: Array<{ name: string; parameters: Record<string, unknown> }> =
    [];
  const database: DatabaseGateway = {
    rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T> {
      calls.push({ name, parameters });
      return Promise.resolve(
        (name === "wali_edge_take_rate_limit_v1" ? { allowed: true } : {
          submission_id: id,
          revision: 4,
          generation: 2,
          state: "processing",
          ...responsePatch,
        }) as T,
      );
    },
  };
  const dependencies: EndpointDependencies = {
    database,
    authenticate: () =>
      Promise.resolve({
        actorID: actor,
        assuranceLevel: "aal1",
        accessToken: "synthetic",
        expiresAt: 9999999999,
      }),
    now: () => new Date(),
    fetcher: fetch,
    supabaseURL: "https://fixture.supabase.co",
    publishableKey: "synthetic",
    serviceRoleKey: "synthetic",
  };
  const body = {
    api_version: "creator.v1",
    request_id: id,
    idempotency_key: "retry_processing_01",
    action: "retry_processing",
    payload: { submission_id: id, expected_revision: 3, ...patch },
  };
  return {
    calls,
    dependencies,
    request: new Request(
      "https://fixture.supabase.co/functions/v1/creator-command",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      },
    ),
  };
}
Deno.test("processing retry binds real AAL1 actor and expected revision", async () => {
  const f = fixture();
  const response = await handleCreatorCommand(f.request, f.dependencies);
  assert(response.status === 200);
  const call = f.calls.find((c) => c.name === "wali_edge_retry_processing_v1");
  assert(call);
  assert(call.parameters.actor_id === actor);
  assert(call.parameters.expected_revision === 3);
  assert(!("actor_aal" in call.parameters));
  const body = await response.json();
  assert(body.data.generation === 2 && body.data.state === "processing");
});
for (
  const [name, patch] of Object.entries({
    forged_actor: { actor_id: id },
    source_override: { storage_path: "foreign" },
    rights_override: { license_id: id },
    deadline_override: { deadline_at: "2099-01-01" },
    invalid_revision: { expected_revision: 0 },
  })
) {
  Deno.test(`processing retry rejects ${name}`, async () => {
    const f = fixture(patch);
    const response = await handleCreatorCommand(f.request, f.dependencies);
    assert(response.status === 400);
    assert(!f.calls.some((c) => c.name === "wali_edge_retry_processing_v1"));
  });
}
Deno.test("processing retry never reaches mutation after authentication failure", async () => {
  const f = fixture();
  f.dependencies.authenticate = () =>
    Promise.reject(new EdgeError("authentication_required", 401));
  const response = await handleCreatorCommand(f.request, f.dependencies);
  assert(response.status === 401);
  assert(f.calls.length === 0);
});

Deno.test("processing retry accepts the existing idempotent replay marker", async () => {
  const f = fixture({}, { replayed: true });
  const response = await handleCreatorCommand(f.request, f.dependencies);
  assert(response.status === 200);
  assert((await response.json()).data.replayed === true);
});
for (
  const [name, patch] of Object.entries({
    wrong_subject: { submission_id: actor },
    stale_revision: { revision: 3 },
    old_generation: { generation: 1 },
    wrong_state: { state: "published" },
    unknown_field: { access_token: "never-expose" },
    malformed_replay: { replayed: "true" },
  })
) {
  Deno.test(`processing retry refuses malformed response ${name}`, async () => {
    const f = fixture({}, patch);
    const response = await handleCreatorCommand(f.request, f.dependencies);
    assert(response.status === 503);
    assert(!(await response.text()).includes("never-expose"));
  });
}
