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
  requirePlainText,
  requireRevision,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "creator.v1";

export async function handleSubmitWallpaper(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readExactJSON(request, 16_384, [
      "api_version",
      "request_id",
      "idempotency_key",
      "submission_id",
      "expected_revision",
      "expected_generation",
      "creator_terms_version",
    ]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    const submissionID = requireUUID(body.submission_id);
    const expectedRevision = requireRevision(body.expected_revision);
    const expectedGeneration = requireRevision(body.expected_generation);
    const termsVersion = requirePlainText(body.creator_terms_version, 10, 32);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "submit_wallpaper",
      20,
      3_600,
    );
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_submit_wallpaper_v1",
      {
        actor_id: auth.actorID,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        submission_id: submissionID,
        expected_revision: expectedRevision,
        expected_generation: expectedGeneration,
        creator_terms_version: termsVersion,
      },
    );
    if (
      !isObject(data) || data.submission_id !== submissionID ||
      data.state !== "submitted" ||
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

if (import.meta.main) {
  Deno.serve((request) =>
    handleSubmitWallpaper(request, productionDependencies())
  );
}
