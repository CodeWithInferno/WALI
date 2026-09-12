import { CATALOG_LICENSE_ATTESTATION } from "../_shared/curated-license-attestation.ts";
import { EdgeError, success } from "../_shared/errors.ts";
import {
  type EndpointDependencies,
  productionDependencies,
  safeFailure,
  UNKNOWN_REQUEST_ID,
} from "../_shared/runtime.ts";
import { createTUSResource } from "../_shared/upload.ts";
import {
  isObject,
  type JSONObject,
  optionalPlainText,
  readExactJSON,
  requireEnum,
  requireEnvelope,
  requireExactKeys,
  requireHTTPSURL,
  requireInteger,
  requirePlainText,
  requireRevision,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "curated_catalog.v1";
const RPC = "wali_edge_curated_catalog_command_v1";
const ACTIONS = [
  "accept_attestation",
  "create_upload",
  "complete_upload",
  "save_draft",
  "submit",
  "status",
  "withdraw",
] as const;
type Action = typeof ACTIONS[number];
const SUBMISSION_STATES = [
  "draft",
  "uploading",
  "uploaded",
  "processing",
  "processing_failed",
  "ready_for_submission",
  "submitted",
  "under_review",
  "changes_requested",
  "approved",
  "rejected",
  "published",
  "withdrawn",
] as const;

export async function handleCuratedCatalogCommand(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readExactJSON(request, 32_768, [
      "api_version",
      "request_id",
      "idempotency_key",
      "action",
      "payload",
    ]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    if (auth.assuranceLevel !== "aal2") {
      throw new EdgeError("mfa_required", 403);
    }
    const action = requireEnum(body.action, ACTIONS);
    const payload = parsePayload(action, body.payload, auth.actorID);
    const command = (name: Action | "bind_upload", value: JSONObject) =>
      dependencies.database.rpc<unknown>(RPC, {
        actor_id: auth.actorID,
        actor_aal: auth.assuranceLevel,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        command: name,
        payload: value,
      });
    // The RPC checks the current active administrator for every action. Its
    // 24/day quota counts new reservations only, so retries use no Edge counter.
    const raw = await command(action, payload);
    let data: JSONObject;
    if (action === "create_upload") {
      const reservation = serverValue(() =>
        parseReservation(raw, auth.actorID, dependencies.supabaseURL)
      );
      let revision = reservation.revision;
      let uploadEndpoint = reservation.upload_endpoint;
      if (uploadEndpoint === null) {
        uploadEndpoint = await createTUSResource(
          dependencies,
          auth.accessToken,
          reservation.storage_path,
          payload.declared_byte_count as number,
          payload.container_hint as string,
        );
        uploadEndpoint = serverValue(() =>
          uploadURL(uploadEndpoint, dependencies.supabaseURL)
        );
        try {
          const binding = await command("bind_upload", {
            upload_session_id: reservation.upload_session_id,
            expected_session_revision: reservation.revision,
            upload_endpoint: uploadEndpoint,
          });
          revision = serverValue(() => {
            const value = responseObject(binding, ["revision"]);
            return positiveRevision(value.revision);
          });
        } catch (error) {
          if (
            !(error instanceof EdgeError) ||
            !["idempotency_conflict", "stale_revision"].includes(error.code)
          ) throw error;
          // Another same-key create may bind first. Keep the original request
          // identity and return only its current, validated canonical endpoint.
          try {
            const refreshed = parseReservation(
              await command("create_upload", payload),
              auth.actorID,
              dependencies.supabaseURL,
            );
            if (
              refreshed.upload_session_id !== reservation.upload_session_id ||
              refreshed.expires_at !== reservation.expires_at ||
              refreshed.revision < reservation.revision ||
              refreshed.upload_endpoint === null
            ) throw error;
            uploadEndpoint = refreshed.upload_endpoint;
            revision = refreshed.revision;
          } catch {
            throw error;
          }
        }
      }
      data = {
        upload_session_id: reservation.upload_session_id,
        revision,
        expires_at: reservation.expires_at,
        upload_endpoint: uploadEndpoint,
        required_headers: { "Tus-Resumable": "1.0.0" },
        scoped_upload_token: auth.accessToken,
      };
    } else {
      data = serverValue(() => parseResponse(action, raw, payload));
    }
    return success(
      API_VERSION,
      requestID,
      data,
      action === "accept_attestation" || action === "create_upload" ? 201 : 200,
    );
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

function object(value: unknown, keys: readonly string[]): JSONObject {
  if (!isObject(value)) throw new EdgeError("invalid_request", 400);
  return requireExactKeys(value, keys);
}

function nonblank(value: unknown, maximum: number): string {
  const text = requirePlainText(value, 1, maximum);
  if (!text.trim()) throw new EdgeError("invalid_request", 400);
  return text;
}

function attestationVersion(value: unknown): string {
  return requireEnum(value, [CATALOG_LICENSE_ATTESTATION.version]);
}

function parseDraft(value: unknown): JSONObject {
  const draft = object(value, [
    "title",
    "description",
    "primary_category_id",
    "suggested_tag_ids",
    "content_warning",
    "rights_basis",
    "rights_holder",
    "license_id",
    "source_url",
    "attribution_text",
    "proof_object_ids",
    "attests_rights",
    "attestation_version",
  ]);
  if (
    draft.attests_rights !== true || !Array.isArray(draft.proof_object_ids) ||
    draft.proof_object_ids.length !== 0
  ) throw new EdgeError("invalid_request", 400);
  const tags = boundedArray(draft.suggested_tag_ids, 20).map(requireUUID);
  if (new Set(tags).size !== tags.length) {
    throw new EdgeError("invalid_request", 400);
  }
  return {
    title: nonblank(draft.title, 120),
    description: nonblank(draft.description, 2_000),
    primary_category_id: requireUUID(draft.primary_category_id),
    suggested_tag_ids: tags,
    content_warning: optionalPlainText(draft.content_warning, 500),
    rights_basis: requireEnum(draft.rights_basis, ["licensed"]),
    rights_holder: nonblank(draft.rights_holder, 160),
    license_id: requireUUID(draft.license_id),
    source_url: requireHTTPSURL(draft.source_url),
    attribution_text: nonblank(draft.attribution_text, 500),
    proof_object_ids: [],
    attests_rights: true,
    attestation_version: attestationVersion(draft.attestation_version),
  };
}

function parsePayload(
  action: Action,
  value: unknown,
  actorID: string,
): JSONObject {
  switch (action) {
    case "accept_attestation": {
      const payload = object(value, [
        "expected_subject_id",
        "attestation_version",
      ]);
      const subject = requireUUID(payload.expected_subject_id);
      if (subject !== actorID) {
        throw new EdgeError("authentication_required", 401);
      }
      return {
        expected_subject_id: subject,
        attestation_version: attestationVersion(payload.attestation_version),
      };
    }
    case "create_upload": {
      const payload = object(value, [
        "declared_byte_count",
        "container_hint",
        "original_filename",
        "target",
      ]);
      const filename = nonblank(payload.original_filename, 255);
      if (filename === "." || filename === ".." || /[/\\]/.test(filename)) {
        throw new EdgeError("invalid_request", 400);
      }
      const target = payload.target;
      if (!isObject(target)) throw new EdgeError("invalid_request", 400);
      let parsedTarget: JSONObject;
      if (target.kind === "new") {
        object(target, ["kind"]);
        parsedTarget = { kind: "new" };
      } else {
        object(target, ["kind", "wallpaper_id", "expected_revision"]);
        parsedTarget = {
          kind: requireEnum(target.kind, ["wallpaper_update"]),
          wallpaper_id: requireUUID(target.wallpaper_id),
          expected_revision: requireRevision(target.expected_revision),
        };
      }
      return {
        declared_byte_count: requireInteger(
          payload.declared_byte_count,
          1,
          1_073_741_824,
        ),
        container_hint: requireEnum(payload.container_hint, [
          "video/mp4",
          "video/quicktime",
        ]),
        original_filename: filename,
        target: parsedTarget,
      };
    }
    case "complete_upload": {
      const payload = object(value, [
        "upload_session_id",
        "expected_session_revision",
        "draft",
      ]);
      return {
        upload_session_id: requireUUID(payload.upload_session_id),
        expected_session_revision: requireRevision(
          payload.expected_session_revision,
        ),
        draft: parseDraft(payload.draft),
      };
    }
    case "save_draft": {
      const payload = object(value, [
        "submission_id",
        "expected_revision",
        "draft",
      ]);
      return {
        submission_id: requireUUID(payload.submission_id),
        expected_revision: requireRevision(payload.expected_revision),
        draft: parseDraft(payload.draft),
      };
    }
    case "submit": {
      const payload = object(value, [
        "submission_id",
        "expected_revision",
        "expected_generation",
        "attestation_version",
      ]);
      return {
        submission_id: requireUUID(payload.submission_id),
        expected_revision: requireRevision(payload.expected_revision),
        expected_generation: requireRevision(payload.expected_generation),
        attestation_version: attestationVersion(payload.attestation_version),
      };
    }
    case "withdraw": {
      const payload = object(value, ["submission_id", "expected_revision"]);
      return {
        submission_id: requireUUID(payload.submission_id),
        expected_revision: requireRevision(payload.expected_revision),
      };
    }
    case "status": {
      const payload = object(value, ["upload_session_id"]);
      return { upload_session_id: requireUUID(payload.upload_session_id) };
    }
  }
}

// Database output is untrusted. Exact bounded shapes also stop accidental private
// columns from appearing in API responses. Invalid server output is a safe 503.
function serverValue<T>(parse: () => T): T {
  try {
    return parse();
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
}
function responseObject(
  value: unknown,
  keys: readonly string[],
  allowReplay = true,
): JSONObject {
  if (!isObject(value)) throw new EdgeError("invalid_request", 400);
  const replay = allowReplay && Object.hasOwn(value, "replayed");
  object(value, replay ? [...keys, "replayed"] : keys);
  if (replay && value.replayed !== true) {
    throw new EdgeError("invalid_request", 400);
  }
  return value;
}
function positiveRevision(value: unknown): number {
  const revision = requireRevision(value);
  if (revision < 1) throw new EdgeError("invalid_request", 400);
  return revision;
}
function timestamp(value: unknown): string {
  const text = requirePlainText(value, 20, 40);
  if (
    !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)$/.test(
      text,
    ) || !Number.isFinite(Date.parse(text))
  ) throw new EdgeError("invalid_request", 400);
  return text;
}
function uploadURL(value: unknown, origin: string): string {
  const text = requirePlainText(value, 1, 2_048);
  const base = new URL(origin);
  const url = new URL(text);
  const prefix = "/storage/v1/upload/resumable/";
  if (
    url.origin !== base.origin || url.protocol !== base.protocol ||
    url.username || url.password || url.search || url.hash ||
    !url.pathname.startsWith(prefix) || url.pathname.length === prefix.length
  ) throw new EdgeError("invalid_request", 400);
  return url.href;
}
function parseReservation(value: unknown, actorID: string, origin: string) {
  const data = responseObject(value, [
    "upload_session_id",
    "storage_path",
    "expires_at",
    "revision",
    "upload_endpoint",
  ]);
  const sessionID = requireUUID(data.upload_session_id);
  if (data.storage_path !== `${actorID}/${sessionID}/source`) {
    throw new EdgeError("invalid_request", 400);
  }
  return {
    upload_session_id: sessionID,
    storage_path: data.storage_path as string,
    expires_at: timestamp(data.expires_at),
    revision: positiveRevision(data.revision),
    upload_endpoint: data.upload_endpoint === null
      ? null
      : uploadURL(data.upload_endpoint, origin),
  };
}
function boundedArray(value: unknown, maximum: number): unknown[] {
  if (!Array.isArray(value) || value.length > maximum) {
    throw new EdgeError("invalid_request", 400);
  }
  return value;
}
function finiteNumber(
  value: unknown,
  minimum: number,
  maximum: number,
): number {
  if (
    typeof value !== "number" || !Number.isFinite(value) || value < minimum ||
    value > maximum
  ) throw new EdgeError("invalid_request", 400);
  return value;
}
function safeCode(value: unknown): string | null {
  if (value === null) return null;
  const code = requirePlainText(value, 7, 101);
  if (!/^WALI_[A-Z0-9_]{2,96}$/.test(code)) {
    throw new EdgeError("invalid_request", 400);
  }
  return code;
}
function submissionIdentity(
  value: JSONObject,
  expectedID?: unknown,
  expectedGeneration?: unknown,
) {
  const id = requireUUID(value.submission_id);
  const generation = positiveRevision(value.generation);
  if (
    (expectedID !== undefined && id !== expectedID) ||
    (expectedGeneration !== undefined && generation !== expectedGeneration)
  ) throw new EdgeError("invalid_request", 400);
  return {
    submission_id: id,
    revision: positiveRevision(value.revision),
    generation,
    state: requireEnum(value.state, SUBMISSION_STATES),
  };
}
function parseProcessing(
  value: unknown,
  identity: ReturnType<typeof submissionIdentity>,
): JSONObject {
  const data = responseObject(value, [
    "submission_id",
    "revision",
    "generation",
    "state",
    "progress",
    "safe_error_code",
    "media_facts",
    "generated_variants",
    "duplicate_warning",
    "suggestions",
    "findings",
  ], false);
  const result = submissionIdentity(
    data,
    identity.submission_id,
    identity.generation,
  );
  if (
    result.revision !== identity.revision || result.state !== identity.state ||
    typeof data.duplicate_warning !== "boolean"
  ) throw new EdgeError("invalid_request", 400);
  let media: JSONObject | null = null;
  if (data.media_facts !== null) {
    const value = object(data.media_facts, [
      "container",
      "codec",
      "width",
      "height",
      "frame_rate",
      "duration_ms",
    ]);
    media = {
      container: nonblank(value.container, 128),
      codec: nonblank(value.codec, 128),
      width: requireInteger(value.width, 1, 32_768),
      height: requireInteger(value.height, 1, 32_768),
      frame_rate: value.frame_rate === null
        ? null
        : finiteNumber(value.frame_rate, 0.001, 1_000),
      duration_ms: requireInteger(value.duration_ms, 1, 86_400_000),
    };
  }
  const variants = boundedArray(data.generated_variants, 7).map((item) => {
    const variant = object(item, ["role", "width", "height"]);
    return {
      role: requireEnum(variant.role, [
        "thumbnail",
        "poster",
        "preview",
        "video_default",
        "video_1080p",
        "video_1440p",
        "video_2160p",
      ]),
      width: requireInteger(variant.width, 1, 32_768),
      height: requireInteger(variant.height, 1, 32_768),
    };
  });
  if (new Set(variants.map((v) => v.role)).size !== variants.length) {
    throw new EdgeError("invalid_request", 400);
  }
  const suggestions = boundedArray(data.suggestions, 100).map((item) => {
    const suggestion = object(item, [
      "kind",
      "value",
      "confidence",
      "model_id",
      "model_revision",
    ]);
    return {
      kind: requireEnum(suggestion.kind, ["tag"]),
      value: nonblank(suggestion.value, 160),
      confidence: suggestion.confidence === null
        ? null
        : finiteNumber(suggestion.confidence, 0, 1),
      model_id: nonblank(suggestion.model_id, 128),
      model_revision: nonblank(suggestion.model_revision, 128),
    };
  });
  const findings = boundedArray(data.findings, 20).map((item) => {
    const finding = object(item, ["code", "message", "severity"]);
    const code = safeCode(finding.code);
    if (code === null) throw new EdgeError("invalid_request", 400);
    return {
      code,
      message: requireEnum(finding.message, [
        "Processing could not complete safely.",
      ]),
      severity: requireEnum(finding.severity, ["blocking"]),
    };
  });
  return {
    ...result,
    progress: data.progress === null ? null : finiteNumber(data.progress, 0, 1),
    safe_error_code: safeCode(data.safe_error_code),
    media_facts: media,
    generated_variants: variants,
    duplicate_warning: data.duplicate_warning,
    suggestions,
    findings,
  };
}
function parseResponse(
  action: Exclude<Action, "create_upload">,
  value: unknown,
  payload: JSONObject,
): JSONObject {
  let data: JSONObject;
  let result: JSONObject;
  if (action === "accept_attestation") {
    data = responseObject(value, [
      "document_kind",
      "accepted_attestation_version",
      "current_attestation_version",
    ]);
    result = {
      document_kind: requireEnum(data.document_kind, [
        CATALOG_LICENSE_ATTESTATION.documentKind,
      ]),
      accepted_attestation_version: attestationVersion(
        data.accepted_attestation_version,
      ),
      current_attestation_version: attestationVersion(
        data.current_attestation_version,
      ),
    };
  } else if (action === "status") {
    data = responseObject(value, [
      "upload_session_id",
      "revision",
      "upload_state",
      "expires_at",
      "submission",
    ]);
    const sessionID = requireUUID(data.upload_session_id);
    if (sessionID !== payload.upload_session_id) {
      throw new EdgeError("invalid_request", 400);
    }
    let submission: JSONObject | null = null;
    if (data.submission !== null) {
      const inner = responseObject(data.submission, [
        "submission_id",
        "revision",
        "generation",
        "state",
        "processing",
      ], false);
      const identity = submissionIdentity(inner);
      submission = {
        ...identity,
        processing: parseProcessing(inner.processing, identity),
      };
    }
    result = {
      upload_session_id: sessionID,
      revision: positiveRevision(data.revision),
      upload_state: requireEnum(data.upload_state, [
        "issued",
        "uploading",
        "completed",
        "expired",
        "cancelled",
      ]),
      expires_at: timestamp(data.expires_at),
      submission,
    };
  } else {
    const extra = action === "complete_upload"
      ? ["processing_status_key"]
      : action === "save_draft" || action === "withdraw"
      ? ["field_errors"]
      : [];
    data = responseObject(value, [
      "submission_id",
      "revision",
      "generation",
      "state",
      ...extra,
    ]);
    const identity = submissionIdentity(
      data,
      action === "complete_upload" ? undefined : payload.submission_id,
      action === "submit" ? payload.expected_generation : undefined,
    );
    if (
      (action === "complete_upload" && identity.state !== "processing") ||
      (action === "submit" && identity.state !== "submitted") ||
      (action === "withdraw" && identity.state !== "withdrawn")
    ) throw new EdgeError("invalid_request", 400);
    result = { ...identity };
    if (action === "complete_upload") {
      const key = `${identity.submission_id}:${identity.generation}`;
      if (data.processing_status_key !== key) {
        throw new EdgeError("invalid_request", 400);
      }
      result.processing_status_key = key;
    } else if (action === "save_draft" || action === "withdraw") {
      boundedArray(data.field_errors, 0);
      result.field_errors = [];
    }
  }
  if (data.replayed === true) result.replayed = true;
  return result;
}

if (import.meta.main) {
  Deno.serve((request) =>
    handleCuratedCatalogCommand(request, productionDependencies())
  );
}
