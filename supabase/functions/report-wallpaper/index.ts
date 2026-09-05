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
  requirePlainText,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "catalog.v1";
const KINDS = [
  "copyright",
  "trademark",
  "unsafe_content",
  "misleading_metadata",
  "technical_issue",
  "other",
] as const;

export async function handleReportWallpaper(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readExactJSON(request, 16_384, [
      "api_version",
      "request_id",
      "idempotency_key",
      "wallpaper_id",
      "release_id",
      "kind",
      "detail",
    ]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    const wallpaperID = requireUUID(body.wallpaper_id);
    const releaseID = body.release_id === null
      ? null
      : requireUUID(body.release_id);
    const kind = requireEnum(body.kind, KINDS);
    const detail = requirePlainText(body.detail, 1, 2_000);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "report_wallpaper",
      5,
      3_600,
    );
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_report_wallpaper_v1",
      {
        actor_id: auth.actorID,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        wallpaper_id: wallpaperID,
        release_id: releaseID,
        report_kind: kind === "unsafe_content"
          ? "unsafe"
          : kind === "misleading_metadata"
          ? "misleading"
          : kind,
        detail,
      },
    );
    if (
      !isObject(data) || typeof data.report_id !== "string" ||
      data.status !== "open" || typeof data.created_at !== "string"
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
    handleReportWallpaper(request, productionDependencies())
  );
}
