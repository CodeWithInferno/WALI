import { EdgeError, success } from "../_shared/errors.ts";
import { enforceRateLimit } from "../_shared/rate-limit.ts";
import {
  type EndpointDependencies,
  productionDependencies,
  safeFailure,
  UNKNOWN_REQUEST_ID,
} from "../_shared/runtime.ts";
import {
  isObject,
  optionalPlainText,
  readExactJSON,
  requireEnum,
  requireEnvelope,
  requireHTTPSURL,
  requirePlainText,
  requireRevision,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "creator.v1";
type Action =
  | "accept_terms"
  | "save_draft"
  | "withdraw"
  | "retry_publication"
  | "retry_processing";

export async function handleCreatorCommand(
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
    const action = requireEnum(
      body.action,
      [
        "accept_terms",
        "save_draft",
        "withdraw",
        "retry_publication",
        "retry_processing",
      ] as const,
    );
    if (!isObject(body.payload)) throw new EdgeError("invalid_request", 400);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      `creator_command_${action}`,
      action === "save_draft" ? 120 : 20,
      3_600,
    );
    const data = await execute(
      action,
      body.payload,
      auth.actorID,
      requestID,
      envelope.idempotencyKey,
      dependencies,
    );
    if (!isObject(data)) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    return success(
      API_VERSION,
      requestID,
      data,
      action === "accept_terms" ? 201 : 200,
    );
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

async function execute(
  action: Action,
  payload: Record<string, unknown>,
  actorID: string,
  requestID: string,
  idempotencyKey: string,
  dependencies: EndpointDependencies,
): Promise<unknown> {
  if (action === "accept_terms") {
    exactKeys(payload, ["expected_subject_id", "creator_terms_version"]);
    const expectedSubjectID = requireUUID(payload.expected_subject_id);
    if (expectedSubjectID !== actorID) {
      throw new EdgeError("authentication_required", 401);
    }
    return await dependencies.database.rpc(
      "wali_edge_accept_creator_terms_v1",
      {
        actor_id: actorID,
        expected_subject_id: expectedSubjectID,
        request_id: requestID,
        idempotency_key: idempotencyKey,
        creator_terms_version: requirePlainText(
          payload.creator_terms_version,
          10,
          32,
        ),
      },
    );
  }
  if (action === "retry_processing") {
    exactKeys(payload, ["submission_id", "expected_revision"]);
    const submissionID = requireUUID(payload.submission_id);
    const expectedRevision = requireRevision(payload.expected_revision);
    if (expectedRevision < 1) throw new EdgeError("invalid_request", 400);
    const result = await dependencies.database.rpc(
      "wali_edge_retry_processing_v1",
      {
        actor_id: actorID,
        request_id: requestID,
        idempotency_key: idempotencyKey,
        submission_id: submissionID,
        expected_revision: expectedRevision,
      },
    );
    if (
      !isObject(result) ||
      ![
        "generation,revision,state,submission_id",
        "generation,replayed,revision,state,submission_id",
      ].includes(Object.keys(result).sort().join(",")) ||
      ("replayed" in result && result.replayed !== true) ||
      result.submission_id !== submissionID || result.state !== "processing" ||
      !Number.isSafeInteger(result.revision) ||
      (result.revision as number) <= expectedRevision ||
      !Number.isSafeInteger(result.generation) ||
      (result.generation as number) < 2
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    return result;
  }
  if (action === "withdraw" || action === "retry_publication") {
    exactKeys(payload, ["submission_id", "expected_revision"]);
    return await dependencies.database.rpc(
      action === "withdraw"
        ? "wali_edge_withdraw_submission_v1"
        : "wali_edge_retry_publication_v1",
      {
        actor_id: actorID,
        request_id: requestID,
        idempotency_key: idempotencyKey,
        submission_id: requireUUID(payload.submission_id),
        expected_revision: requireRevision(payload.expected_revision),
      },
    );
  }

  exactKeys(payload, [
    "submission_id",
    "expected_revision",
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
    "creator_terms_version",
  ]);
  if (typeof payload.attests_rights !== "boolean") {
    throw new EdgeError("invalid_request", 400);
  }
  return await dependencies.database.rpc("wali_edge_save_submission_draft_v1", {
    actor_id: actorID,
    request_id: requestID,
    idempotency_key: idempotencyKey,
    submission_id: requireUUID(payload.submission_id),
    expected_revision: requireRevision(payload.expected_revision),
    title: requirePlainText(payload.title, 1, 120),
    description: requirePlainText(payload.description, 1, 2_000),
    primary_category_id: requireUUID(payload.primary_category_id),
    suggested_tag_ids: uuidArray(payload.suggested_tag_ids, 20),
    content_warning: optionalPlainText(payload.content_warning, 500),
    rights_basis: requireEnum(
      payload.rights_basis,
      ["original", "licensed", "public_domain", "other"] as const,
    ),
    rights_holder: requirePlainText(payload.rights_holder, 1, 160),
    license_id: requireUUID(payload.license_id),
    source_url: payload.source_url === null
      ? null
      : requireHTTPSURL(payload.source_url),
    attribution_text: optionalPlainText(payload.attribution_text, 500),
    proof_object_ids: uuidArray(payload.proof_object_ids, 5),
    attests_rights: payload.attests_rights,
    creator_terms_version: requirePlainText(
      payload.creator_terms_version,
      10,
      32,
    ),
  });
}

function exactKeys(value: Record<string, unknown>, expected: string[]): void {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (
    actual.length !== wanted.length ||
    actual.some((key, index) => key !== wanted[index])
  ) throw new EdgeError("invalid_request", 400);
}

function uuidArray(value: unknown, maximum: number): string[] {
  if (!Array.isArray(value) || value.length > maximum) {
    throw new EdgeError("invalid_request", 400);
  }
  const result = value.map(requireUUID);
  if (new Set(result).size !== result.length) {
    throw new EdgeError("invalid_request", 400);
  }
  return result;
}

if (import.meta.main) {
  Deno.serve((request) =>
    handleCreatorCommand(request, productionDependencies())
  );
}
