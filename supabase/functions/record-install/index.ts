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
  requireDigest,
  requireEnum,
  requireEnvelope,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "catalog.v1";
const KEYS = [
  "api_version",
  "request_id",
  "idempotency_key",
  "install_receipt",
  "manifest_digest",
  "release_id",
  "result",
];

export async function handleRecordInstall(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readExactJSON(request, 16_384, KEYS);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    const receipt = requireUUID(body.install_receipt);
    const releaseID = requireUUID(body.release_id);
    const digest = requireDigest(body.manifest_digest);
    const result = requireEnum(body.result, ["verified_installed"] as const);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "record_install",
      60,
      60,
    );
    const data = await dependencies.database.rpc<unknown>("record_install_v1", {
      actor_id: auth.actorID,
      request_id: requestID,
      idempotency_key: envelope.idempotencyKey,
      install_receipt: receipt,
      release_id: releaseID,
      manifest_digest: digest,
      result,
    });
    if (
      !isObject(data) || data.release_id !== releaseID ||
      data.result !== "verified_installed" || data.recorded !== true
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    return success(API_VERSION, requestID, {
      release_id: releaseID,
      result: "verified_installed",
      recorded: true,
    });
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

if (import.meta.main) {
  Deno.serve((request) =>
    handleRecordInstall(request, productionDependencies())
  );
}
