import { handleCompleteUpload } from "../complete-upload/index.ts";
import type { DatabaseGateway } from "../_shared/database.ts";
import type { EndpointDependencies } from "../_shared/runtime.ts";

const ACTOR = "00000000-0000-4000-8000-000000000003";
const ID = "70000000-0000-4000-8000-000000000001";
const draft = {
  title: "Rainy street",
  description: "A quiet city scene.",
  primary_category_id: ID,
  suggested_tag_ids: [],
  content_warning: null,
  rights_basis: "licensed",
  rights_holder: "Original creator",
  license_id: ID,
  source_url: "https://publisher.example/work",
  attribution_text: "Credit: Original creator.",
  proof_object_ids: [],
  attests_rights: true,
  creator_terms_version: "2026-09-12",
};
const completion = {
  submission_id: ID,
  revision: 1,
  generation: 1,
  state: "processing",
  processing_status_key: `${ID}:1`,
};
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(a: unknown, b: unknown) {
  assert(
    JSON.stringify(a) === JSON.stringify(b),
    `${JSON.stringify(a)} != ${JSON.stringify(b)}`,
  );
}
class Database implements DatabaseGateway {
  calls: Array<{ name: string; parameters: Record<string, unknown> }> = [];
  rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T> {
    this.calls.push({ name, parameters });
    return Promise.resolve(
      (name === "wali_edge_take_rate_limit_v1"
        ? { allowed: true }
        : completion) as T,
    );
  }
}
function dependencies(database: Database): EndpointDependencies {
  return {
    database,
    authenticate: () =>
      Promise.resolve({
        actorID: ACTOR,
        assuranceLevel: "aal1",
        accessToken: "real-user-token",
        expiresAt: 9_999_999_999,
      }),
    now: () => new Date(),
    fetcher: fetch,
    supabaseURL: "https://catalog.example",
    publishableKey: "public",
    serviceRoleKey: "server-only",
  };
}
function request(value: Record<string, unknown>) {
  return new Request("https://catalog.example/functions/v1/complete-upload", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(value),
  });
}
function body() {
  return {
    api_version: "creator.v1",
    request_id: ID,
    idempotency_key: "complete_test_0001",
    upload_session_id: ID,
    expected_session_revision: 2,
    draft: structuredClone(draft),
  };
}
Deno.test("complete upload binds actual licensed draft at AAL1 before enqueue", async () => {
  const database = new Database();
  const response = await handleCompleteUpload(
    request(body()),
    dependencies(database),
  );
  equal(response.status, 200);
  const call = database.calls.find((value) =>
    value.name === "wali_edge_complete_upload_v1"
  );
  assert(call);
  equal(call.parameters.draft, draft);
  equal(call.parameters.actor_id, ACTOR);
  assert(!("actor_aal" in call.parameters));
});
Deno.test("complete upload rejects missing draft before mutation", async () => {
  const database = new Database();
  const { draft: _draft, ...value } = body();
  equal(
    (await handleCompleteUpload(request(value), dependencies(database))).status,
    400,
  );
  equal(database.calls.length, 0);
});
for (
  const [name, patch] of Object.entries({
    unattested: { attests_rights: false },
    proof: { proof_object_ids: [ID] },
    missing_source: { source_url: null },
    long_credit: { attribution_text: "x".repeat(501) },
    forged_authority: { actor_aal: "aal2" },
  })
) {
  Deno.test(`complete upload rejects ${name}`, async () => {
    const database = new Database();
    const value = body();
    Object.assign(value.draft, patch);
    equal(
      (await handleCompleteUpload(request(value), dependencies(database)))
        .status,
      400,
    );
    equal(database.calls.length, 0);
  });
}
