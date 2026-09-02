import { authenticate } from "../_shared/auth.ts";
import type { DatabaseGateway } from "../_shared/database.ts";
import { EdgeError, mapDatabaseError } from "../_shared/errors.ts";
import type { EndpointDependencies } from "../_shared/runtime.ts";
import { readExactJSON } from "../_shared/validation.ts";
import { handleCreateUpload } from "../create-upload/index.ts";
import { handleCatalogSecurityState } from "../catalog-security-state/index.ts";
import { handleCreatorCommand } from "../creator-command/index.ts";
import { handleModerateSubmission } from "../moderate-submission/index.ts";
import { handleRecordInstall } from "../record-install/index.ts";
import { handleRequestInstall } from "../request-install/index.ts";
import { handlePublishRelease } from "../publish-release/index.ts";
import { handleRequestAccountExport } from "../request-account-export/index.ts";
import { handleRequestAccountDeletion } from "../request-account-deletion/index.ts";
import {
  signCanonicalDocument,
  unpaddedBase64URL,
} from "../_shared/manifest.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown): void {
  const left = JSON.stringify(actual);
  const right = JSON.stringify(expected);
  if (left !== right) throw new Error(`expected ${right}, got ${left}`);
}

async function responseJSON(
  response: Response,
): Promise<Record<string, unknown>> {
  return await response.json() as Record<string, unknown>;
}

class FakeDatabase implements DatabaseGateway {
  readonly calls: Array<{ name: string; parameters: Record<string, unknown> }> =
    [];
  constructor(private readonly results: Record<string, unknown>) {}
  rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T> {
    this.calls.push({ name, parameters });
    const result = this.results[name];
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
        actorID: "00000000-0000-4000-8000-000000000003",
        assuranceLevel: "aal1",
        accessToken: "valid.token.signature",
        expiresAt: 2_000_000_000,
      }),
    now: () => new Date("2026-09-01T00:00:00Z"),
    fetcher: () =>
      Promise.resolve(
        new Response(null, {
          status: 201,
          headers: {
            location:
              "https://catalog.example/storage/v1/upload/resumable/session",
          },
        }),
      ),
    supabaseURL: "https://catalog.example",
    publishableKey: "public-key",
    serviceRoleKey: "service-role-key",
    ...overrides,
  };
}

function jsonRequest(body: string): Request {
  return new Request("https://edge.example/function", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: "Bearer valid.token.signature",
    },
    body,
  });
}

Deno.test("strict JSON rejects duplicate object keys", async () => {
  let error: unknown;
  try {
    await readExactJSON(jsonRequest('{"value":1,"value":2}'), 1_024, ["value"]);
  } catch (caught) {
    error = caught;
  }
  assert(error instanceof EdgeError);
  assertEquals(error.code, "invalid_request");
});

Deno.test("strict JSON rejects excessive nesting", async () => {
  const nested = '{"value":' + "[".repeat(9) + "0" + "]".repeat(9) + "}";
  let error: unknown;
  try {
    await readExactJSON(jsonRequest(nested), 1_024, ["value"]);
  } catch (caught) {
    error = caught;
  }
  assert(error instanceof EdgeError);
  assertEquals(error.code, "invalid_request");
});

Deno.test("strict JSON cancels an oversized streaming body before buffering it", async () => {
  let cancelled = false;
  let pulls = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      pulls += 1;
      controller.enqueue(new Uint8Array(700).fill(0x20));
      if (pulls >= 3) controller.close();
    },
    cancel() {
      cancelled = true;
    },
  });
  const request = new Request("https://edge.example/function", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
  });
  let error: unknown;
  try {
    await readExactJSON(request, 1_024, ["value"]);
  } catch (caught) {
    error = caught;
  }
  assert(error instanceof EdgeError);
  assertEquals(error.status, 413);
  assert(cancelled, "the unread stream remainder must be cancelled");
});

Deno.test("publish release retries through prepare-level completed replay", async () => {
  const replay = {
    wallpaper_id: "30000000-0000-4000-8000-000000000001",
    release_id: "40000000-0000-4000-8000-000000000001",
    edition: 1,
    manifest_digest: "a".repeat(64),
    key_id: "catalog-local-1",
    wallpaper_revision: 2,
    published_at: "2026-09-01T00:00:00Z",
  };
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
    wali_edge_prepare_publication_v1: { replayed: true, response: replay },
  });
  const response = await handlePublishRelease(
    jsonRequest(JSON.stringify({
      api_version: "moderation.v1",
      request_id: "90000000-0000-4000-8000-000000000041",
      idempotency_key: "publish_retry_000000000001",
      submission_id: "71000000-0000-4000-8000-000000000001",
      expected_revision: 4,
      expected_generation: 2,
      expected_wallpaper_revision: 1,
      manifest_schema: { epoch: 1, revision: 0 },
    })),
    dependencies(database, {
      authenticate: () =>
        Promise.resolve({
          actorID: "00000000-0000-4000-8000-000000000003",
          assuranceLevel: "aal2",
          accessToken: "valid.token.signature",
          expiresAt: 2_000_000_000,
        }),
    }),
  );
  assertEquals(response.status, 200);
  assertEquals((await responseJSON(response)).data, replay);
  assertEquals(database.calls.map((call) => call.name), [
    "wali_edge_take_rate_limit_v1",
    "wali_edge_prepare_publication_v1",
  ]);
});

Deno.test("catalog revocation retries before post-revocation state checks", async () => {
  const replay = {
    release_id: "40000000-0000-4000-8000-000000000001",
    artifact_digest: "4".repeat(64),
    reason: "critical_security",
    revision: 2,
    key_id: "catalog-local-1",
    body_digest: "b".repeat(64),
  };
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
    wali_edge_prepare_catalog_revocation_v1: {
      replayed: true,
      response: replay,
    },
  });
  const response = await handlePublishRelease(
    jsonRequest(JSON.stringify({
      api_version: "moderation.v1",
      request_id: "90000000-0000-4000-8000-000000000042",
      idempotency_key: "revoke_retry_000000000001",
      operation: "issue_catalog_revocation",
      release_id: "40000000-0000-4000-8000-000000000001",
      artifact_digest: "4".repeat(64),
      expected_list_revision: 1,
      expected_keyset_revision: 0,
      reason: "critical_security",
    })),
    dependencies(database, {
      authenticate: () =>
        Promise.resolve({
          actorID: "00000000-0000-4000-8000-000000000003",
          assuranceLevel: "aal2",
          accessToken: "valid.token.signature",
          expiresAt: 2_000_000_000,
        }),
    }),
  );
  assertEquals(response.status, 200);
  assertEquals((await responseJSON(response)).data, replay);
  assertEquals(database.calls.map((call) => call.name), [
    "wali_edge_take_rate_limit_v1",
    "wali_edge_prepare_catalog_revocation_v1",
  ]);
});

Deno.test("catalog document signing self-verifies and rejects a mismatched public key", async () => {
  const signer = await crypto.subtle.generateKey(
    "Ed25519",
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  const wrongSigner = await crypto.subtle.generateKey(
    "Ed25519",
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  const privateKey = unpaddedBase64URL(
    new Uint8Array(await crypto.subtle.exportKey("pkcs8", signer.privateKey)),
  );
  const publicKey = unpaddedBase64URL(
    new Uint8Array(await crypto.subtle.exportKey("raw", signer.publicKey)),
  );
  const wrongPublicKey = unpaddedBase64URL(
    new Uint8Array(await crypto.subtle.exportKey("raw", wrongSigner.publicKey)),
  );
  const body = new TextEncoder().encode(
    '{"schema":{"epoch":1,"revision":0},"key_id":"test-key","revision":1,"issued_at":"2026-09-01T00:00:00Z","revocations":[]}',
  );
  const signed = await signCanonicalDocument(
    body,
    "test-key",
    "test-key",
    privateKey,
    publicKey,
  );
  assertEquals(signed.signature.length, 64);
  assert(/^[0-9a-f]{64}$/.test(signed.digest));
  let mismatch: unknown;
  try {
    await signCanonicalDocument(
      body,
      "test-key",
      "test-key",
      privateKey,
      wrongPublicKey,
    );
  } catch (error) {
    mismatch = error;
  }
  assert(mismatch instanceof EdgeError);
  assertEquals(mismatch.code, "signing_key_unavailable");
});

Deno.test("authentication validates token against Auth before trusting claims", async () => {
  const payload = btoa(JSON.stringify({
    sub: "00000000-0000-4000-8000-000000000003",
    exp: 2_000_000_000,
    aal: "aal2",
    amr: [{ method: "password", timestamp: 1_700_000_000 }, {
      method: "totp",
      timestamp: 1_800_000_000,
    }],
  })).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  const token = `header.${payload}.signature`;
  const context = await authenticate(
    new Request("https://edge.example", {
      headers: { authorization: `Bearer ${token}` },
    }),
    { supabaseURL: "https://catalog.example", publishableKey: "public-key" },
    (_input, init) => {
      assertEquals(
        (init?.headers as Record<string, string>).authorization,
        `Bearer ${token}`,
      );
      return Promise.resolve(
        Response.json({ id: "00000000-0000-4000-8000-000000000003" }),
      );
    },
  );
  assertEquals(context.assuranceLevel, "aal2");
  assertEquals(context.authenticatedAt, 1_800_000_000);
});

Deno.test("account deletion requires a recent AAL2 step-up before any mutation", async () => {
  const database = new FakeDatabase({});
  const body = JSON.stringify({
    api_version: "account.v1",
    request_id: "90000000-0000-4000-8000-000000000061",
    idempotency_key: "account_deletion_000000000001",
    expected_profile_revision: 2,
    confirmation: "DELETE MY WALI",
  });
  for (
    const auth of [
      { assuranceLevel: "aal1" as const, authenticatedAt: 1_788_220_800 },
      { assuranceLevel: "aal2" as const, authenticatedAt: 1_788_220_000 },
      { assuranceLevel: "aal2" as const, authenticatedAt: 1_888_220_800 },
    ]
  ) {
    const response = await handleRequestAccountDeletion(
      jsonRequest(body),
      dependencies(database, {
        authenticate: () =>
          Promise.resolve({
            actorID: "00000000-0000-4000-8000-000000000003",
            accessToken: "valid.token.signature",
            expiresAt: 2_000_000_000,
            ...auth,
          }),
      }),
    );
    assertEquals(response.status, 403);
  }
  assertEquals(database.calls.length, 0);
});

Deno.test("account deletion atomically requests and checkpoints provider session revocation", async () => {
  const deletionID = "94000000-0000-4000-8000-000000000001";
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
    wali_edge_request_account_deletion_v1: {
      deletion_id: deletionID,
      status: "deletion_pending",
      revision: 3,
      requested_at: "2026-09-01T00:00:00Z",
    },
    wali_edge_mark_account_deletion_sessions_revoked_v1: {
      deletion_id: deletionID,
      status: "deletion_pending",
      processing_status: "pending",
      auth_identity_status: "sessions_revoked",
      revision: 4,
      requested_at: "2026-09-01T00:00:00Z",
    },
  });
  const response = await handleRequestAccountDeletion(
    jsonRequest(JSON.stringify({
      api_version: "account.v1",
      request_id: "90000000-0000-4000-8000-000000000062",
      idempotency_key: "account_deletion_000000000002",
      expected_profile_revision: 2,
      confirmation: "DELETE MY WALI",
    })),
    dependencies(database, {
      authenticate: () =>
        Promise.resolve({
          actorID: "00000000-0000-4000-8000-000000000003",
          assuranceLevel: "aal2",
          accessToken: "valid.token.signature",
          expiresAt: 2_000_000_000,
          authenticatedAt: 1_788_220_800,
        }),
      fetcher: () => {
        throw new Error(
          "session revocation must be transactional SQL, not a fallible second provider call",
        );
      },
    }),
  );
  assertEquals(response.status, 202);
  assertEquals(database.calls.map((call) => call.name), [
    "wali_edge_take_rate_limit_v1",
    "wali_edge_request_account_deletion_v1",
    "wali_edge_mark_account_deletion_sessions_revoked_v1",
  ]);
});

Deno.test("admin deletion executor soft-deletes, verifies, then finalizes the CAS", async () => {
  const deletionID = "94000000-0000-4000-8000-000000000002";
  const userID = "00000000-0000-4000-8000-000000000003";
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
    wali_edge_prepare_account_identity_deletion_v1: {
      completed: false,
      deletion_id: deletionID,
      user_id: userID,
      revision: 7,
    },
    wali_edge_finalize_account_identity_deletion_v1: {
      deletion_id: deletionID,
      status: "completed",
      auth_identity_status: "completed",
      revision: 8,
      requested_at: "2026-09-01T00:00:00Z",
      completed_at: "2026-09-01T00:00:01Z",
    },
  });
  const methods: string[] = [];
  const response = await handleRequestAccountDeletion(
    jsonRequest(JSON.stringify({
      api_version: "account.v1",
      request_id: "90000000-0000-4000-8000-000000000063",
      idempotency_key: "account_deletion_finalize_001",
      operation: "finalize_identity",
      deletion_id: deletionID,
      expected_revision: 7,
    })),
    dependencies(database, {
      authenticate: () =>
        Promise.resolve({
          actorID: "00000000-0000-4000-8000-000000000001",
          assuranceLevel: "aal2",
          accessToken: "valid.token.signature",
          expiresAt: 2_000_000_000,
          authenticatedAt: 1_788_220_800,
        }),
      fetcher: (input, init) => {
        methods.push(init?.method ?? "GET");
        const url = new URL(input instanceof Request ? input.url : input);
        assert(url.pathname.endsWith(`/auth/v1/admin/users/${userID}`));
        if (init?.method === "DELETE") {
          assertEquals(url.searchParams.get("should_soft_delete"), "true");
        }
        return Promise.resolve(
          init?.method === "DELETE"
            ? Response.json({}, { status: 200 })
            : Response.json({ deleted_at: "2026-09-01T00:00:00Z" }),
        );
      },
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(methods, ["DELETE", "GET"]);
  assertEquals(database.calls.map((call) => call.name), [
    "wali_edge_take_rate_limit_v1",
    "wali_edge_prepare_account_identity_deletion_v1",
    "wali_edge_finalize_account_identity_deletion_v1",
  ]);
});

Deno.test("admin deletion retry replays completion before stale revision checks", async () => {
  const deletionID = "94000000-0000-4000-8000-000000000002";
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
    wali_edge_prepare_account_identity_deletion_v1: {
      completed: true,
      deletion_id: deletionID,
      user_id: "00000000-0000-4000-8000-000000000003",
      revision: 8,
    },
    wali_edge_finalize_account_identity_deletion_v1: {
      deletion_id: deletionID,
      status: "completed",
      auth_identity_status: "completed",
      revision: 8,
      requested_at: "2026-09-01T00:00:00Z",
      completed_at: "2026-09-01T00:00:01Z",
    },
  });
  const response = await handleRequestAccountDeletion(
    jsonRequest(JSON.stringify({
      api_version: "account.v1",
      request_id: "90000000-0000-4000-8000-000000000066",
      idempotency_key: "account_deletion_finalize_001",
      operation: "finalize_identity",
      deletion_id: deletionID,
      expected_revision: 7,
    })),
    dependencies(database, {
      authenticate: () =>
        Promise.resolve({
          actorID: "00000000-0000-4000-8000-000000000001",
          assuranceLevel: "aal2",
          accessToken: "valid.token.signature",
          expiresAt: 2_000_000_000,
          authenticatedAt: 1_788_220_800,
        }),
      fetcher: () => {
        throw new Error(
          "a completed retry must not repeat the provider soft-delete",
        );
      },
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(database.calls.map((call) => call.name), [
    "wali_edge_take_rate_limit_v1",
    "wali_edge_prepare_account_identity_deletion_v1",
    "wali_edge_finalize_account_identity_deletion_v1",
  ]);
});

Deno.test("ready account export returns only a five-minute owner-scoped signed grant", async () => {
  const exportID = "95000000-0000-4000-8000-000000000001";
  const path =
    `exports/00000000-0000-4000-8000-000000000003/${exportID}/account.json`;
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
    wali_edge_account_export_status_v1: {
      export_id: exportID,
      status: "ready",
      expires_at: "2026-09-08T00:00:00Z",
      completed_at: "2026-09-01T00:00:00Z",
      byte_count: 4096,
      digest: "a".repeat(64),
      download_path: path,
    },
  });
  const response = await handleRequestAccountExport(
    jsonRequest(JSON.stringify({
      api_version: "account.v1",
      request_id: "90000000-0000-4000-8000-000000000064",
      idempotency_key: "account_export_status_00001",
      operation: "status",
      export_id: exportID,
    })),
    dependencies(database, {
      fetcher: (_input, init) => {
        assertEquals(JSON.parse(String(init?.body)), { expiresIn: 300 });
        return Promise.resolve(Response.json({
          signedURL:
            `/storage/v1/object/sign/exports-private/${path}?token=safe`,
        }));
      },
    }),
  );
  assertEquals(response.status, 200);
  const data = (await responseJSON(response)).data as Record<string, unknown>;
  assert(typeof data.download_url === "string");
  assert(!("download_path" in data));
});

Deno.test("moderation queue replaces private canonical paths with bounded signed URLs", async () => {
  const path = `sha256/${"a".repeat(2)}/${"a".repeat(2)}/${
    "a".repeat(64)
  }/poster.jpg`;
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
    moderation_queue_v1: {
      items: [{
        submission_id: "71000000-0000-4000-8000-000000000001",
        canonical_artifacts: [{
          role: "poster",
          storage_path: path,
          sha256: "a".repeat(64),
          byte_count: 4096,
          media_type: "image/jpeg",
          width: 1920,
          height: 1080,
          duration_ms: 0,
        }],
      }],
      next_cursor: null,
    },
  });
  const response = await handleModerateSubmission(
    jsonRequest(JSON.stringify({
      api_version: "moderation.v1",
      request_id: "90000000-0000-4000-8000-000000000065",
      idempotency_key: "moderation_queue_000000001",
      operation: "queue",
      status: "pending",
      sort: "oldest_submitted",
      cursor: null,
      limit: 24,
    })),
    dependencies(database, {
      authenticate: () =>
        Promise.resolve({
          actorID: "00000000-0000-4000-8000-000000000004",
          assuranceLevel: "aal2",
          accessToken: "valid.token.signature",
          expiresAt: 2_000_000_000,
        }),
      fetcher: () =>
        Promise.resolve(
          Response.json([{
            path,
            signedURL:
              `/storage/v1/object/sign/processing-private/${path}?token=safe`,
          }]),
        ),
    }),
  );
  assertEquals(response.status, 200);
  const data = (await responseJSON(response)).data as {
    items: Array<Record<string, unknown>>;
  };
  const artifact =
    (data.items[0].canonical_artifacts as Array<Record<string, unknown>>)[0];
  assert(typeof artifact.url === "string");
  assertEquals(artifact.sha256, "a".repeat(64));
  assertEquals(artifact.byte_count, 4096);
  assertEquals(artifact.media_type, "image/jpeg");
  assertEquals(artifact.duration_ms, 0);
  assert(!("storage_path" in artifact));
});

Deno.test("record-install returns exact stable acknowledgment and strips replay metadata", async () => {
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
    record_install_v1: {
      release_id: "40000000-0000-4000-8000-000000000001",
      result: "verified_installed",
      recorded: true,
      replayed: true,
    },
  });
  const response = await handleRecordInstall(
    jsonRequest(JSON.stringify({
      api_version: "catalog.v1",
      request_id: "90000000-0000-4000-8000-000000000001",
      idempotency_key: "record_install_000000000000001",
      install_receipt: "91000000-0000-4000-8000-000000000010",
      manifest_digest: "a".repeat(64),
      release_id: "40000000-0000-4000-8000-000000000001",
      result: "verified_installed",
    })),
    dependencies(database),
  );
  assertEquals(response.status, 200);
  const body = await responseJSON(response);
  assertEquals(body.data, {
    release_id: "40000000-0000-4000-8000-000000000001",
    result: "verified_installed",
    recorded: true,
  });
});

Deno.test("request-install binds both release and wallpaper revision", async () => {
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
    wali_edge_request_install_v1: {
      wallpaper_id: "30000000-0000-4000-8000-000000000001",
      release_id: "40000000-0000-4000-8000-000000000001",
      manifest_body: "YWJj",
      metadata_body: "ZGVm",
      signature: "c2ln",
      key_id: "catalog-2026-01",
      install_receipt: "91000000-0000-4000-8000-000000000010",
      expires_at: "2026-09-01T00:30:00Z",
    },
  });
  const response = await handleRequestInstall(
    jsonRequest(JSON.stringify({
      api_version: "catalog.v1",
      request_id: "90000000-0000-4000-8000-000000000001",
      idempotency_key: "request_install_00000000000001",
      wallpaper_id: "30000000-0000-4000-8000-000000000001",
      release_id: "40000000-0000-4000-8000-000000000001",
      expected_wallpaper_revision: 7,
    })),
    dependencies(database),
  );
  assertEquals(response.status, 200);
  assertEquals(database.calls[1].parameters.expected_wallpaper_revision, 7);
});

Deno.test("create-upload rejects a cross-host TUS redirect", async () => {
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
    wali_edge_create_upload_v1: {
      upload_session_id: "70000000-0000-4000-8000-000000000001",
      storage_path:
        "00000000-0000-4000-8000-000000000003/70000000-0000-4000-8000-000000000001/source",
      expires_at: "2026-09-02T00:00:00Z",
      revision: 1,
    },
  });
  const response = await handleCreateUpload(
    jsonRequest(JSON.stringify({
      api_version: "creator.v1",
      request_id: "90000000-0000-4000-8000-000000000001",
      idempotency_key: "create_upload_0000000000000001",
      declared_byte_count: 100,
      container_hint: "video/mp4",
      original_filename: "safe.mp4",
      target: { kind: "new" },
    })),
    dependencies(database, {
      fetcher: () =>
        Promise.resolve(
          new Response(null, {
            status: 201,
            headers: { location: "https://evil.example/upload" },
          }),
        ),
    }),
  );
  assertEquals(response.status, 503);
});

Deno.test("creator enrollment accepts only the exact current terms command", async () => {
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
    wali_edge_accept_creator_terms_v1: {
      account_is_active: true,
      creator_enrolled: true,
      creator_grant_revision: 1,
      accepted_creator_terms_version: "2026-09-01",
      current_creator_terms_version: "2026-09-01",
      newly_enrolled: true,
    },
  });
  const response = await handleCreatorCommand(
    jsonRequest(JSON.stringify({
      api_version: "creator.v1",
      request_id: "90000000-0000-4000-8000-000000000001",
      idempotency_key: "accept_creator_terms_000000001",
      action: "accept_terms",
      payload: {
        expected_subject_id: "00000000-0000-4000-8000-000000000003",
        creator_terms_version: "2026-09-01",
      },
    })),
    dependencies(database),
  );
  assertEquals(response.status, 201);
  assertEquals(database.calls[1].name, "wali_edge_accept_creator_terms_v1");
  assertEquals(
    database.calls[1].parameters.expected_subject_id,
    "00000000-0000-4000-8000-000000000003",
  );
  assertEquals(
    database.calls[1].parameters.creator_terms_version,
    "2026-09-01",
  );
});

Deno.test("creator enrollment rejects an account switch before the acceptance mutation", async () => {
  const database = new FakeDatabase({
    wali_edge_take_rate_limit_v1: { allowed: true, retry_after_seconds: 0 },
  });
  const response = await handleCreatorCommand(
    jsonRequest(JSON.stringify({
      api_version: "creator.v1",
      request_id: "90000000-0000-4000-8000-000000000002",
      idempotency_key: "accept_creator_terms_000000002",
      action: "accept_terms",
      payload: {
        expected_subject_id: "00000000-0000-4000-8000-000000000002",
        creator_terms_version: "2026-09-01",
      },
    })),
    dependencies(database),
  );

  assertEquals(response.status, 401);
  assertEquals((await responseJSON(response)).error, {
    code: "authentication_required",
    message: "Sign in to continue.",
    retryable: false,
  });
  assertEquals(database.calls.length, 1);
  assertEquals(database.calls[0].name, "wali_edge_take_rate_limit_v1");
});

Deno.test("revoked creator self-enrollment maps to a bounded access denial", () => {
  const error = mapDatabaseError(
    "database rejected command: WALI_CREATOR_ROLE_REVOKED",
  );

  assertEquals(
    { code: error.code, status: error.status, retryable: error.retryable },
    { code: "creator_role_required", status: 403, retryable: false },
  );
});

Deno.test("moderation requires AAL2 before database access", async () => {
  const database = new FakeDatabase({});
  const response = await handleModerateSubmission(
    jsonRequest(JSON.stringify({
      api_version: "moderation.v1",
      request_id: "90000000-0000-4000-8000-000000000001",
      idempotency_key: "moderate_submission_0000000001",
      submission_id: "71000000-0000-4000-8000-000000000001",
      expected_revision: 2,
      expected_generation: 1,
      decision: "approved",
      checklist_revision: 1,
      reason_codes: [],
      creator_note: "Approved.",
      private_note: null,
    })),
    dependencies(database),
  );
  assertEquals(response.status, 403);
  assertEquals(database.calls.length, 0);
});

Deno.test("moderation rejects reason codes that do not match the decision", async () => {
  const database = new FakeDatabase({});
  const response = await handleModerateSubmission(
    jsonRequest(JSON.stringify({
      api_version: "moderation.v1",
      request_id: "90000000-0000-4000-8000-000000000001",
      idempotency_key: "moderate_submission_0000000002",
      submission_id: "71000000-0000-4000-8000-000000000001",
      expected_revision: 2,
      expected_generation: 1,
      decision: "approved",
      checklist_revision: 1,
      reason_codes: ["unsafe_content"],
      creator_note: "Approved.",
      private_note: null,
    })),
    dependencies(database, {
      authenticate: () =>
        Promise.resolve({
          actorID: "00000000-0000-4000-8000-000000000004",
          assuranceLevel: "aal2",
          accessToken: "valid.token.signature",
          expiresAt: 2_000_000_000,
        }),
    }),
  );
  assertEquals(response.status, 400);
  assertEquals(database.calls.length, 0);
});

Deno.test("security state is public while unsigned mutations authenticate explicitly", async () => {
  const database = new FakeDatabase({
    wali_edge_catalog_security_state_v1: {
      trust_transition: null,
      revocations: {
        revision: 1,
        body: "e30",
        signature: "c2ln",
        key_id: "catalog-local-1",
      },
    },
  });
  const unsigned = new Request("https://edge.example/function", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      api_version: "catalog.v1",
      request_id: "90000000-0000-4000-8000-000000000001",
    }),
  });
  const publicResponse = await handleCatalogSecurityState(
    unsigned,
    dependencies(database),
  );
  assertEquals(publicResponse.status, 200);
  assert(publicResponse.headers.get("cache-control")?.startsWith("public,"));

  const mutationDatabase = new FakeDatabase({});
  const unsignedMutation = new Request("https://edge.example/function", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      api_version: "catalog.v1",
      request_id: "90000000-0000-4000-8000-000000000001",
      idempotency_key: "request_install_00000000000001",
      wallpaper_id: "30000000-0000-4000-8000-000000000001",
      release_id: "40000000-0000-4000-8000-000000000001",
      expected_wallpaper_revision: 1,
    }),
  });
  const mutationResponse = await handleRequestInstall(
    unsignedMutation,
    dependencies(mutationDatabase, {
      authenticate: (request) =>
        authenticate(request, {
          supabaseURL: "https://catalog.example",
          publishableKey: "public-key",
        }),
    }),
  );
  assertEquals(mutationResponse.status, 401);
  assertEquals((await responseJSON(mutationResponse)).error, {
    code: "authentication_required",
    message: "Sign in to continue.",
    retryable: false,
  });
  assertEquals(mutationDatabase.calls.length, 0);
});
