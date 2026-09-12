import { handleCuratedCatalogCommand } from "../curated-catalog-command/index.ts";
import { authenticate } from "../_shared/auth.ts";
import type { DatabaseGateway } from "../_shared/database.ts";
import { mapDatabaseError } from "../_shared/errors.ts";
import type { EndpointDependencies } from "../_shared/runtime.ts";

const ACTOR = "00000000-0000-4000-8000-000000000003";
const OTHER = "00000000-0000-4000-8000-000000000004";
const SESSION = "70000000-0000-4000-8000-000000000001";
const SUBMISSION = "71000000-0000-4000-8000-000000000001";
const REQUEST = "90000000-0000-4000-8000-000000000001";
const CATEGORY = "20000000-0000-4000-8000-000000000001";
const VERSION = "2026-09-12";
const RPC = "wali_edge_curated_catalog_command_v1";
const TUS = "https://catalog.example/storage/v1/upload/resumable/session";
const accepted = {
  document_kind: "catalog_license_attestation",
  accepted_attestation_version: VERSION,
  current_attestation_version: VERSION,
};
const draft = {
  title: "Licensed scene",
  description: "A licensed landscape.",
  primary_category_id: CATEGORY,
  suggested_tag_ids: [],
  content_warning: null,
  rights_basis: "licensed",
  rights_holder: "Original publisher",
  license_id: CATEGORY,
  source_url: "https://publisher.example/work",
  attribution_text: "Courtesy of the original publisher.",
  proof_object_ids: [],
  attests_rights: true,
  attestation_version: VERSION,
};
const creation = {
  declared_byte_count: 100,
  container_hint: "video/mp4",
  original_filename: "scene.mp4",
  target: { kind: "new" },
};
const reservation = {
  upload_session_id: SESSION,
  storage_path: `${ACTOR}/${SESSION}/source`,
  expires_at: "2026-09-13T00:00:00Z",
  revision: 1,
  upload_endpoint: null,
};
const processing = {
  submission_id: SUBMISSION,
  revision: 2,
  generation: 1,
  state: "processing",
  progress: 0.1,
  safe_error_code: null,
  media_facts: null,
  generated_variants: [],
  duplicate_warning: false,
  suggestions: [],
  findings: [],
};

function equal(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
class FakeDatabase implements DatabaseGateway {
  calls: Array<{ name: string; parameters: Record<string, unknown> }> = [];
  constructor(private readonly results: Record<string, unknown> = {}) {}
  rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T> {
    this.calls.push({ name, parameters });
    const result = this.results[String(parameters.command)];
    if (result instanceof Error) throw result;
    return Promise.resolve(result as T);
  }
}
function dependencies(
  database: FakeDatabase,
  overrides: Partial<EndpointDependencies> = {},
): EndpointDependencies {
  return {
    database,
    authenticate: () =>
      Promise.resolve({
        actorID: ACTOR,
        assuranceLevel: "aal2",
        accessToken: "user.token.signature",
        expiresAt: 2_000_000_000,
      }),
    now: () => new Date("2026-09-12T00:00:00Z"),
    fetcher: () =>
      Promise.resolve(
        new Response(null, { status: 201, headers: { location: TUS } }),
      ),
    supabaseURL: "https://catalog.example",
    publishableKey: "public-key",
    serviceRoleKey: "never-send-this-service-key",
    ...overrides,
  };
}
function request(
  action: string,
  payload: unknown,
  extra: Record<string, unknown> = {},
): Request {
  return new Request("https://edge.example/curated-catalog-command", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: "Bearer user.token.signature",
    },
    body: JSON.stringify({
      api_version: "curated_catalog.v1",
      request_id: REQUEST,
      idempotency_key: "curated_test_000000000001",
      action,
      payload,
      ...extra,
    }),
  });
}
async function run(
  action: string,
  payload: unknown,
  database = new FakeDatabase(),
  overrides: Partial<EndpointDependencies> = {},
  extra: Record<string, unknown> = {},
) {
  const response = await handleCuratedCatalogCommand(
    request(action, payload, extra),
    dependencies(database, overrides),
  );
  return { response, body: await response.json(), database };
}
const acceptPayload = {
  expected_subject_id: ACTOR,
  attestation_version: VERSION,
};

Deno.test("curated rejects AAL1 before any database or upload call", async () => {
  const database = new FakeDatabase({ accept_attestation: accepted });
  const result = await run("accept_attestation", acceptPayload, database, {
    authenticate: () =>
      Promise.resolve({
        actorID: ACTOR,
        assuranceLevel: "aal1",
        accessToken: "token",
        expiresAt: 2_000_000_000,
      }),
    fetcher: () => {
      throw new Error("must not upload");
    },
  });
  equal(result.response.status, 403);
  equal(result.body.error.code, "mfa_required");
  equal(database.calls.length, 0);
});
Deno.test("curated accepts attestation using only authenticated actor and AAL2", async () => {
  const { response, body, database } = await run(
    "accept_attestation",
    acceptPayload,
    new FakeDatabase({ accept_attestation: accepted }),
  );
  equal(response.status, 201);
  equal(body.data, accepted);
  equal(database.calls.length, 1);
  equal(database.calls[0], {
    name: RPC,
    parameters: {
      actor_id: ACTOR,
      actor_aal: "aal2",
      request_id: REQUEST,
      idempotency_key: "curated_test_000000000001",
      command: "accept_attestation",
      payload: acceptPayload,
    },
  });
  equal(response.headers.get("cache-control"), "no-store");
});
Deno.test("curated rejects an acceptance for another subject", async () => {
  const r = await run("accept_attestation", {
    ...acceptPayload,
    expected_subject_id: OTHER,
  });
  equal(r.response.status, 401);
  equal(r.database.calls.length, 0);
});
for (const action of ["bind_upload", "publish", "approve", "accept_terms"]) {
  Deno.test(`curated rejects public action ${action}`, async () => {
    const r = await run(action, {});
    equal(r.response.status, 400);
    equal(r.database.calls.length, 0);
  });
}
for (
  const extra of [{ actor_id: OTHER }, { actor_aal: "aal2" }, {
    approved: true,
  }]
) {
  Deno.test(`curated rejects caller authority ${Object.keys(extra)[0]}`, async () => {
    const r = await run(
      "accept_attestation",
      acceptPayload,
      new FakeDatabase(),
      {},
      extra,
    );
    equal(r.response.status, 400);
    equal(r.database.calls.length, 0);
  });
}
Deno.test("curated strict nested draft rejects nonlicensed rights, proof IDs, blank credit and extra keys", async () => {
  for (
    const changed of [
      { rights_basis: "original" },
      { proof_object_ids: [CATEGORY] },
      { attribution_text: " " },
      { source_url: null },
      { attests_rights: false },
      { attestation_version: "2026-09-01" },
      { actor_id: OTHER },
      { title: "bad\u0000title" },
      { rights_holder: "e\u0301" },
      { suggested_tag_ids: [CATEGORY, CATEGORY] },
    ]
  ) {
    const r = await run("complete_upload", {
      upload_session_id: SESSION,
      expected_session_revision: 2,
      draft: { ...draft, ...changed },
    });
    equal(r.response.status, 400);
    equal(r.database.calls.length, 0);
  }
});
Deno.test("curated create validates exact nested target and safe filename before reserving", async () => {
  for (
    const changed of [
      { original_filename: "../scene.mp4" },
      { target: { kind: "new", actor_id: OTHER } },
      { target: { kind: "wallpaper_update", wallpaper_id: CATEGORY } },
      { declared_byte_count: 1_073_741_825 },
      { container_hint: "image/png" },
    ]
  ) {
    const r = await run("create_upload", { ...creation, ...changed });
    equal(r.response.status, 400);
    equal(r.database.calls.length, 0);
  }
});
Deno.test("curated creates then internally binds TUS with private user bearer and no extra quota RPC", async () => {
  let fetches = 0;
  const database = new FakeDatabase({
    create_upload: reservation,
    bind_upload: { revision: 2 },
  });
  const r = await run("create_upload", creation, database, {
    fetcher: (input, init) => {
      fetches++;
      equal(
        String(input),
        "https://catalog.example/storage/v1/upload/resumable",
      );
      equal(init?.redirect, "error");
      const headers = new Headers(init?.headers);
      equal(headers.get("authorization"), "Bearer user.token.signature");
      equal(headers.get("apikey"), "public-key");
      equal(headers.get("Upload-Length"), "100");
      assert(!JSON.stringify(init).includes("never-send-this-service-key"));
      return Promise.resolve(
        new Response(null, { status: 201, headers: { location: TUS } }),
      );
    },
  });
  equal(r.response.status, 201);
  equal(fetches, 1);
  equal(database.calls.map((c) => c.name), [RPC, RPC]);
  equal(database.calls[1].parameters.command, "bind_upload");
  equal(database.calls[1].parameters.payload, {
    upload_session_id: SESSION,
    expected_session_revision: 1,
    upload_endpoint: TUS,
  });
  equal(r.body.data.upload_endpoint, TUS);
  equal(r.body.data.revision, 2);
  equal(r.body.data.scoped_upload_token, "user.token.signature");
  assert(!("storage_path" in r.body.data));
});
Deno.test("curated reservation replay resumes its bound upload without another TUS creation", async () => {
  const r = await run(
    "create_upload",
    creation,
    new FakeDatabase({
      create_upload: {
        ...reservation,
        upload_endpoint: TUS,
        revision: 2,
        replayed: true,
      },
    }),
    {
      fetcher: () => {
        throw new Error("must not allocate again");
      },
    },
  );
  equal(r.response.status, 201);
  equal(r.database.calls.length, 1);
  equal(r.body.data.revision, 2);
});
Deno.test("curated refuses cross-owner storage reservations before sending bearer", async () => {
  const r = await run(
    "create_upload",
    creation,
    new FakeDatabase({
      create_upload: {
        ...reservation,
        storage_path: `${OTHER}/${SESSION}/source`,
      },
    }),
    {
      fetcher: () => {
        throw new Error("must not upload");
      },
    },
  );
  equal(r.response.status, 503);
  equal(r.database.calls.length, 1);
});
Deno.test("curated rejects unapproved TUS locations and never binds them", async () => {
  for (
    const location of [
      "https://evil.example/storage/v1/upload/resumable/x",
      "https://catalog.example/rest/v1/private",
      "https://user:pass@catalog.example/storage/v1/upload/resumable/x",
      TUS + "?token=secret",
      TUS + "#secret",
      "https://catalog.example/storage/v1/upload/resumable/",
    ]
  ) {
    const db = new FakeDatabase({ create_upload: reservation });
    const r = await run("create_upload", creation, db, {
      fetcher: () =>
        Promise.resolve(
          new Response(null, { status: 201, headers: { location } }),
        ),
    });
    equal(r.response.status, 503);
    equal(db.calls.length, 1);
    assert(!JSON.stringify(r.body).includes("secret"));
  }
});
Deno.test("curated validates a bound replay location too", async () => {
  const r = await run(
    "create_upload",
    creation,
    new FakeDatabase({
      create_upload: {
        ...reservation,
        upload_endpoint: "https://evil.example/upload",
      },
    }),
  );
  equal(r.response.status, 503);
});
Deno.test("curated complete preserves submitted rights and reports processing", async () => {
  const result = {
    submission_id: SUBMISSION,
    revision: 2,
    generation: 1,
    state: "processing",
    processing_status_key: `${SUBMISSION}:1`,
  };
  const payload = {
    upload_session_id: SESSION,
    expected_session_revision: 2,
    draft,
  };
  const r = await run(
    "complete_upload",
    payload,
    new FakeDatabase({ complete_upload: result }),
  );
  equal(r.response.status, 200);
  equal(r.body.data, result);
  equal(r.database.calls[0].parameters.payload, payload);
});
Deno.test("curated save, submit and withdraw preserve expected revisions and generations", async () => {
  for (
    const [action, payload, result] of [
      [
        "save_draft",
        { submission_id: SUBMISSION, expected_revision: 2, draft },
        {
          submission_id: SUBMISSION,
          revision: 3,
          generation: 1,
          state: "ready_for_submission",
          field_errors: [],
        },
      ],
      ["submit", {
        submission_id: SUBMISSION,
        expected_revision: 3,
        expected_generation: 1,
        attestation_version: VERSION,
      }, {
        submission_id: SUBMISSION,
        revision: 4,
        generation: 1,
        state: "submitted",
      }],
      ["withdraw", { submission_id: SUBMISSION, expected_revision: 4 }, {
        submission_id: SUBMISSION,
        revision: 5,
        generation: 1,
        state: "withdrawn",
        field_errors: [],
      }],
    ] as const
  ) {
    const r = await run(
      action,
      payload,
      new FakeDatabase({ [action]: result }),
    );
    equal(r.response.status, 200);
    equal(r.body.data, result);
    equal(r.database.calls[0].parameters.payload, payload);
  }
});
Deno.test("curated status accepts only bounded owned processing projection", async () => {
  const data = {
    upload_session_id: SESSION,
    revision: 3,
    upload_state: "completed",
    expires_at: reservation.expires_at,
    submission: {
      submission_id: SUBMISSION,
      revision: 2,
      generation: 1,
      state: "processing",
      processing,
    },
  };
  const r = await run(
    "status",
    { upload_session_id: SESSION },
    new FakeDatabase({ status: data }),
  );
  equal(r.response.status, 200);
  equal(r.body.data, data);
  const bad = {
    ...data,
    submission: {
      ...data.submission,
      processing: { ...processing, raw_storage_path: "private-secret" },
    },
  };
  const rejected = await run(
    "status",
    { upload_session_id: SESSION },
    new FakeDatabase({ status: bad }),
  );
  equal(rejected.response.status, 503);
  assert(!JSON.stringify(rejected.body).includes("private-secret"));
});
Deno.test("curated rejects malformed, mismatched and extra response fields", async () => {
  for (
    const result of [{ ...accepted, secret: "do-not-expose" }, {
      ...accepted,
      current_attestation_version: "wrong",
    }, { ...accepted, replayed: false }]
  ) {
    const r = await run(
      "accept_attestation",
      acceptPayload,
      new FakeDatabase({ accept_attestation: result }),
    );
    equal(r.response.status, 503);
    assert(!JSON.stringify(r.body).includes("do-not-expose"));
  }
  const r = await run(
    "submit",
    {
      submission_id: SUBMISSION,
      expected_revision: 1,
      expected_generation: 1,
      attestation_version: VERSION,
    },
    new FakeDatabase({
      submit: {
        submission_id: OTHER,
        revision: 2,
        generation: 1,
        state: "submitted",
      },
    }),
  );
  equal(r.response.status, 503);
});
Deno.test("curated maps inactive admission, missing attestation and quota errors safely", async () => {
  for (
    const [marker, code, status] of [
      [
        "WALI_CATALOG_ADMISSION_UNAVAILABLE",
        "catalog_admission_unavailable",
        403,
      ],
      [
        "WALI_CATALOG_ATTESTATION_REQUIRED",
        "catalog_attestation_required",
        403,
      ],
      ["WALI_CATALOG_UPLOAD_QUOTA_EXCEEDED", "rate_limited", 429],
      ["WALI_ADMISSION_MISMATCH", "forbidden", 403],
    ] as const
  ) {
    const r = await run(
      "accept_attestation",
      acceptPayload,
      new FakeDatabase({
        accept_attestation: mapDatabaseError(marker + ": private-secret"),
      }),
    );
    equal(r.response.status, status);
    equal(r.body.error.code, code);
    assert(!JSON.stringify(r.body).includes("private-secret"));
  }
});
Deno.test("curated does not trust JWT AAL claims before real Auth accepts bearer", async () => {
  const claims = btoa(
    JSON.stringify({ sub: ACTOR, exp: 2_000_000_000, aal: "aal2" }),
  ).replaceAll("=", "");
  const token = `header.${claims}.signature`;
  const db = new FakeDatabase();
  let authCalls = 0;
  const incoming = new Request(request("accept_attestation", acceptPayload), {
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${token}`,
    },
  });
  const deps = dependencies(db, {
    authenticate: (req) =>
      authenticate(req, {
        supabaseURL: "https://catalog.example",
        publishableKey: "public-key",
      }, (url, init) => {
        authCalls++;
        equal(String(url), "https://catalog.example/auth/v1/user");
        equal(init?.redirect, "error");
        return Promise.resolve(new Response(null, { status: 401 }));
      }),
  });
  const response = await handleCuratedCatalogCommand(incoming, deps);
  equal(response.status, 401);
  equal(authCalls, 1);
  equal(db.calls.length, 0);
});
Deno.test("curated limits request bytes and duplicate nested keys", async () => {
  for (
    const body of [
      JSON.stringify({
        api_version: "curated_catalog.v1",
        request_id: REQUEST,
        idempotency_key: "curated_test_000000000001",
        action: "status",
        payload: { upload_session_id: SESSION },
        junk: "x".repeat(40_000),
      }),
      `{"api_version":"curated_catalog.v1","request_id":"${REQUEST}","idempotency_key":"curated_test_000000000001","action":"status","payload":{"upload_session_id":"${SESSION}","upload_session_id":"${OTHER}"}}`,
    ]
  ) {
    const db = new FakeDatabase();
    const r = await handleCuratedCatalogCommand(
      new Request("https://edge.example/curated", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
      }),
      dependencies(db),
    );
    assert([400, 413].includes(r.status));
    equal(db.calls.length, 0);
  }
});

Deno.test("curated preserves the downstream 500-character attribution bound", async () => {
  const payload = {
    submission_id: SUBMISSION,
    expected_revision: 2,
    draft: { ...draft, attribution_text: "c".repeat(500) },
  };
  const response = {
    submission_id: SUBMISSION,
    revision: 3,
    generation: 1,
    state: "ready_for_submission",
    field_errors: [],
  };
  const accepted = await run(
    "save_draft",
    payload,
    new FakeDatabase({ save_draft: response }),
  );
  equal(accepted.response.status, 200);
  const rejected = await run("save_draft", {
    ...payload,
    draft: { ...payload.draft, attribution_text: "c".repeat(501) },
  });
  equal(rejected.response.status, 400);
  equal(rejected.database.calls.length, 0);
});

Deno.test("curated concurrent TUS bind recovers only the canonical owned reservation", async () => {
  for (
    const marker of ["WALI_IDEMPOTENCY_CONFLICT", "WALI_REVISION_MISMATCH"]
  ) {
    const calls: Array<{ name: string; parameters: Record<string, unknown> }> =
      [];
    const winner = TUS + "-winner";
    const database: DatabaseGateway = {
      rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T> {
        calls.push({ name, parameters });
        if (parameters.command === "bind_upload") {
          throw mapDatabaseError(
            marker,
          );
        }
        return Promise.resolve(
          (calls.length === 1 ? reservation : {
            ...reservation,
            revision: 2,
            upload_endpoint: winner,
            replayed: true,
          }) as T,
        );
      },
    };
    const response = await handleCuratedCatalogCommand(
      request("create_upload", creation),
      { ...dependencies(new FakeDatabase()), database },
    );
    const body = await response.json();
    equal(response.status, 201);
    equal(body.data.upload_endpoint, winner);
    equal(body.data.revision, 2);
    equal(calls.map((c) => c.parameters.command), [
      "create_upload",
      "bind_upload",
      "create_upload",
    ]);
    equal(calls[0], calls[2]);
  }
});

Deno.test("curated bind-race recovery preserves failure for unrelated or still-unbound reservations", async () => {
  for (
    const refresh of [
      {
        ...reservation,
        upload_session_id: OTHER,
        storage_path: `${ACTOR}/${OTHER}/source`,
        upload_endpoint: TUS,
      },
      reservation,
      { ...reservation, upload_endpoint: "https://evil.example/upload" },
    ]
  ) {
    let calls = 0;
    const database: DatabaseGateway = {
      rpc<T>(_name: string, parameters: Record<string, unknown>): Promise<T> {
        calls++;
        if (parameters.command === "bind_upload") {
          throw mapDatabaseError("WALI_IDEMPOTENCY_CONFLICT");
        }
        return Promise.resolve((calls === 1 ? reservation : refresh) as T);
      },
    };
    const response = await handleCuratedCatalogCommand(
      request("create_upload", creation),
      { ...dependencies(new FakeDatabase()), database },
    );
    equal(response.status, 409);
    equal((await response.json()).error.code, "idempotency_conflict");
  }
});
