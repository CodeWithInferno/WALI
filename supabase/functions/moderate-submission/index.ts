import { EdgeError, success } from "../_shared/errors.ts";
import { enforceRateLimit } from "../_shared/rate-limit.ts";
import { normalizeStorageGrant } from "../_shared/storage-grant.ts";
import {
  type EndpointDependencies,
  productionDependencies,
  safeFailure,
  UNKNOWN_REQUEST_ID,
} from "../_shared/runtime.ts";
import {
  isObject,
  optionalPlainText,
  readBoundedJSON,
  requireEnum,
  requireEnvelope,
  requireExactKeys,
  requireInteger,
  requirePlainText,
  requireRevision,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "moderation.v1";

export async function handleModerateSubmission(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readBoundedJSON(request, 32_768);
    if (body.operation === "queue" || body.operation === "reports") {
      requestID = requireEnvelope(body, API_VERSION).requestID;
      return await handleReadOperation(request, body, dependencies);
    }
    requireExactKeys(body, [
      "api_version",
      "request_id",
      "idempotency_key",
      "submission_id",
      "expected_revision",
      "expected_generation",
      "decision",
      "checklist_revision",
      "reason_codes",
      "creator_note",
      "private_note",
    ]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    if (auth.assuranceLevel !== "aal2") {
      throw new EdgeError("mfa_required", 403);
    }
    const submissionID = requireUUID(body.submission_id);
    const expectedRevision = requireRevision(body.expected_revision);
    const expectedGeneration = requireRevision(body.expected_generation);
    const decision = requireEnum(
      body.decision,
      ["approved", "changes_requested", "rejected"] as const,
    );
    const checklistRevision = requireInteger(
      body.checklist_revision,
      1,
      2_147_483_647,
    );
    const creatorNote = requirePlainText(body.creator_note, 1, 2_000);
    // An untouched optional native text field encodes as an empty string.
    // Keep the database's optional-note representation canonical.
    const privateNote = body.private_note === ""
      ? null
      : optionalPlainText(body.private_note, 4_000);
    if (
      !Array.isArray(body.reason_codes) || body.reason_codes.length > 20 ||
      body.reason_codes.some((code) =>
        typeof code !== "string" || !/^[a-z][a-z0-9_.-]{2,95}$/.test(code)
      ) ||
      new Set(body.reason_codes).size !== body.reason_codes.length ||
      body.reason_codes.length === 0 ||
      body.reason_codes.some((code) => !moderationReasonAllowed(decision, code))
    ) {
      throw new EdgeError("invalid_request", 400);
    }
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "moderate_submission",
      120,
      3_600,
    );
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_moderate_submission_v1",
      {
        actor_id: auth.actorID,
        actor_aal: auth.assuranceLevel,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        submission_id: submissionID,
        expected_revision: expectedRevision,
        expected_generation: expectedGeneration,
        decision,
        checklist_revision: checklistRevision,
        reason_codes: body.reason_codes,
        creator_note: creatorNote,
        private_note: privateNote,
      },
    );
    if (
      !isObject(data) || data.submission_id !== submissionID ||
      data.decision !== decision ||
      typeof data.revision !== "number" ||
      data.generation !== expectedGeneration
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    return success(API_VERSION, requestID, data);
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

function moderationReasonAllowed(decision: string, reason: unknown): boolean {
  if (reason === "policy_pass") return decision === "approved";
  if (
    ["rights_incomplete", "technical_quality", "duplicate_content"].includes(
      String(reason),
    )
  ) {
    return decision === "changes_requested" || decision === "rejected";
  }
  if (reason === "metadata_inaccurate") return decision === "changes_requested";
  return reason === "unsafe_content" && decision === "rejected";
}

async function handleReadOperation(
  request: Request,
  body: Record<string, unknown>,
  dependencies: EndpointDependencies,
): Promise<Response> {
  const envelope = requireEnvelope(body, API_VERSION);
  const auth = await dependencies.authenticate(request);
  if (auth.assuranceLevel !== "aal2") {
    throw new EdgeError("mfa_required", 403);
  }
  if (body.operation === "reports") {
    requireExactKeys(body, [
      "api_version",
      "request_id",
      "idempotency_key",
      "operation",
      "cursor",
      "limit",
    ]);
    const cursor = optionalCursor(body.cursor);
    const limit = requireInteger(body.limit, 1, 50);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "moderation_reports",
      120,
      3_600,
    );
    const data = await dependencies.database.rpc<unknown>(
      "moderation_reports_v1",
      {
        actor_id: auth.actorID,
        actor_aal: auth.assuranceLevel,
        cursor,
        page_limit: limit,
      },
    );
    if (!validPage(data)) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    return success(
      API_VERSION,
      envelope.requestID,
      await signCanonicalArtifacts(data, auth.accessToken, dependencies),
    );
  }
  requireExactKeys(body, [
    "api_version",
    "request_id",
    "idempotency_key",
    "operation",
    "status",
    "sort",
    "cursor",
    "limit",
  ]);
  const status = requireEnum(
    body.status,
    ["pending", "under_review", "approved"] as const,
  );
  const sort = requireEnum(
    body.sort,
    ["oldest_submitted", "newest_submitted", "risk_priority"] as const,
  );
  const cursor = optionalCursor(body.cursor);
  const limit = requireInteger(body.limit, 1, 50);
  await enforceRateLimit(
    dependencies.database,
    auth.actorID,
    "moderation_queue",
    120,
    3_600,
  );
  const data = await dependencies.database.rpc<unknown>("moderation_queue_v1", {
    actor_id: auth.actorID,
    actor_aal: auth.assuranceLevel,
    queue_status: status,
    queue_sort: sort,
    cursor,
    page_limit: limit,
  });
  if (!validPage(data)) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const signed = await signCanonicalArtifacts(
    data,
    auth.accessToken,
    dependencies,
  );
  return success(API_VERSION, envelope.requestID, signed);
}

function optionalCursor(value: unknown): string | null {
  if (value === null) return null;
  if (
    typeof value !== "string" || value.length < 1 || value.length > 1024 ||
    !/^[A-Za-z0-9_-]+$/.test(value)
  ) {
    throw new EdgeError("invalid_request", 400);
  }
  return value;
}

function validPage(
  value: unknown,
): value is { items: unknown[]; next_cursor: string | null } {
  return isObject(value) && Array.isArray(value.items) &&
    value.items.length <= 50 &&
    (value.next_cursor === null ||
      (typeof value.next_cursor === "string" &&
        value.next_cursor.length <= 1024));
}

async function signCanonicalArtifacts(
  page: { items: unknown[]; next_cursor: string | null },
  accessToken: string,
  dependencies: EndpointDependencies,
): Promise<Record<string, unknown>> {
  const paths: string[] = [];
  for (const item of page.items) {
    if (
      !isObject(item) || !Array.isArray(item.canonical_artifacts) ||
      item.canonical_artifacts.length > 12
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    for (const artifact of item.canonical_artifacts) {
      const expectedExtension = isObject(artifact) &&
          artifact.media_type === "image/jpeg"
        ? "jpg"
        : isObject(artifact) && artifact.media_type === "image/png"
        ? "png"
        : isObject(artifact) && artifact.media_type === "video/mp4"
        ? "mp4"
        : null;
      if (
        !isObject(artifact) || typeof artifact.storage_path !== "string" ||
        !/^sha256\/[0-9a-f]{2}\/[0-9a-f]{2}\/[0-9a-f]{64}\/[a-z0-9-]+[.](jpg|jpeg|png|mp4)$/
          .test(artifact.storage_path) ||
        typeof artifact.sha256 !== "string" ||
        !/^[0-9a-f]{64}$/.test(artifact.sha256) ||
        !artifact.storage_path.includes(`/${artifact.sha256}/`) ||
        typeof artifact.byte_count !== "number" ||
        !Number.isSafeInteger(artifact.byte_count) || artifact.byte_count < 1 ||
        artifact.byte_count > 2_147_483_648 ||
        expectedExtension === null ||
        !artifact.storage_path.endsWith(`.${expectedExtension}`) ||
        (artifact.role !== "poster" && artifact.role !== "preview" &&
          artifact.role !== "video_default") ||
        (artifact.role === "poster" &&
          !String(artifact.media_type).startsWith("image/")) ||
        (artifact.role !== "poster" && artifact.media_type !== "video/mp4") ||
        typeof artifact.width !== "number" ||
        !Number.isInteger(artifact.width) ||
        artifact.width < 1 || artifact.width > 7_680 ||
        typeof artifact.height !== "number" ||
        !Number.isInteger(artifact.height) ||
        artifact.height < 1 || artifact.height > 4_320 ||
        typeof artifact.duration_ms !== "number" ||
        !Number.isSafeInteger(artifact.duration_ms) ||
        (artifact.role === "poster" && artifact.duration_ms !== 0) ||
        (artifact.role !== "poster" &&
          (artifact.duration_ms < 1 || artifact.duration_ms > 600_000))
      ) {
        throw new EdgeError("temporarily_unavailable", 503, true);
      }
      if (!paths.includes(artifact.storage_path)) {
        paths.push(artifact.storage_path);
      }
    }
  }
  if (paths.length === 0) return page;
  if (paths.length > 200) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const endpoint = new URL(
    "/storage/v1/object/sign/processing-private",
    dependencies.supabaseURL,
  );
  let response: Response;
  try {
    response = await dependencies.fetcher(endpoint, {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        apikey: dependencies.publishableKey,
        "content-type": "application/json",
      },
      body: JSON.stringify({ paths, expiresIn: 300 }),
      redirect: "error",
    });
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  if (!response.ok) throw new EdgeError("temporarily_unavailable", 503, true);
  const grants = await response.json().catch(() => null);
  if (!Array.isArray(grants) || grants.length !== paths.length) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const urls = new Map<string, string>();
  for (const grant of grants) {
    if (
      !isObject(grant) || typeof grant.path !== "string" ||
      typeof grant.signedURL !== "string" || !paths.includes(grant.path) ||
      urls.has(grant.path)
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    urls.set(
      grant.path,
      normalizeStorageGrant(
        grant.signedURL,
        dependencies.supabaseURL,
        "processing-private",
        grant.path,
      ),
    );
  }
  return {
    items: page.items.map((raw) => {
      const item = raw as Record<string, unknown>;
      return {
        ...item,
        canonical_artifacts: (item.canonical_artifacts as unknown[]).map(
          (rawArtifact) => {
            const artifact = rawArtifact as Record<string, unknown>;
            const path = artifact.storage_path as string;
            const url = urls.get(path);
            if (!url) throw new EdgeError("temporarily_unavailable", 503, true);
            const { storage_path: _, ...safe } = artifact;
            return { ...safe, url };
          },
        ),
      };
    }),
    next_cursor: page.next_cursor,
  };
}

if (import.meta.main) {
  Deno.serve((request) =>
    handleModerateSubmission(request, productionDependencies())
  );
}
