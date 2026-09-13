import { creatorUploadDraft } from "../_shared/creator-upload-draft.ts";
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
  readExactJSON,
  requireEnvelope,
  requireRevision,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "creator.v1";

export async function handleCompleteUpload(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readExactJSON(request, 32_768, [
      "api_version",
      "request_id",
      "idempotency_key",
      "upload_session_id",
      "expected_session_revision",
      "draft",
    ]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    const draft = creatorUploadDraft(body.draft);
    const sessionID = requireUUID(body.upload_session_id);
    const expectedRevision = requireRevision(body.expected_session_revision);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "complete_upload",
      20,
      3_600,
    );
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_complete_upload_v1",
      {
        actor_id: auth.actorID,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        upload_session_id: sessionID,
        expected_session_revision: expectedRevision,
        draft,
      },
    );
    if (
      !isObject(data) || typeof data.submission_id !== "string" ||
      data.state !== "processing" ||
      typeof data.revision !== "number" ||
      typeof data.generation !== "number" ||
      typeof data.processing_status_key !== "string"
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    return success(API_VERSION, requestID, data);
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

if (import.meta.main) {
  Deno.serve((request) =>
    handleCompleteUpload(request, productionDependencies())
  );
}
