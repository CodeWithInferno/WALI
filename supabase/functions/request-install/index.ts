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
  requireEnum,
  requireEnvelope,
  requireRevision,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "catalog.v1";
const KEYS = [
  "api_version",
  "request_id",
  "idempotency_key",
  "wallpaper_id",
  "release_id",
  "expected_wallpaper_revision",
];

export async function handleRequestInstall(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  let apiVersion: "catalog.v1" | "catalog.v2" = API_VERSION;
  try {
    const body = await readExactJSON(request, 16_384, KEYS);
    apiVersion = requireEnum(
      body.api_version,
      ["catalog.v1", "catalog.v2"] as const,
    );
    const envelope = requireEnvelope(body, apiVersion);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    const wallpaperID = requireUUID(body.wallpaper_id);
    const releaseID = requireUUID(body.release_id);
    const expectedRevision = requireRevision(body.expected_wallpaper_revision);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "request_install",
      30,
      60,
    );
    const data = await dependencies.database.rpc<unknown>(
      apiVersion === "catalog.v2"
        ? "wali_edge_request_install_v2"
        : "wali_edge_request_install_v1",
      {
        actor_id: auth.actorID,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        wallpaper_id: wallpaperID,
        release_id: releaseID,
        expected_wallpaper_revision: expectedRevision,
      },
    );
    validateGrant(data, wallpaperID, releaseID);
    if (
      apiVersion === "catalog.v2" &&
      (!isObject(data) ||
        (data.media_kind !== "video" && data.media_kind !== "still"))
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    return success(apiVersion, requestID, data);
  } catch (error) {
    return safeFailure(apiVersion, requestID, error);
  }
}

function validateGrant(
  value: unknown,
  wallpaperID: string,
  releaseID: string,
): asserts value is Record<string, unknown> {
  if (
    !isObject(value) || value.wallpaper_id !== wallpaperID ||
    value.release_id !== releaseID ||
    !boundedBase64URL(value.manifest_body, 87_382) ||
    !boundedBase64URL(value.metadata_body, 87_382) ||
    !boundedBase64URL(value.signature, 86) ||
    typeof value.key_id !== "string" || value.key_id.length > 128 ||
    typeof value.install_receipt !== "string" ||
    value.install_receipt.length > 512 ||
    typeof value.expires_at !== "string"
  ) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
}

function boundedBase64URL(value: unknown, maximum: number): boolean {
  return typeof value === "string" && value.length > 0 &&
    value.length <= maximum && /^[A-Za-z0-9_-]+$/.test(value);
}

if (import.meta.main) {
  Deno.serve((request) =>
    handleRequestInstall(request, productionDependencies())
  );
}
