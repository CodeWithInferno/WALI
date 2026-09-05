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
  readBoundedJSON,
  requireEnum,
  requireEnvelope,
  requireExactKeys,
  requirePlainText,
  requireRevision,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "moderation.v1";

export async function handleResolveReport(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readBoundedJSON(request, 16_384);
    requireExactKeys(body, [
      "api_version",
      "request_id",
      "idempotency_key",
      "report_id",
      "expected_revision",
      "expected_wallpaper_revision",
      "action",
      "reason_code",
      "private_note",
    ]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    if (auth.assuranceLevel !== "aal2") {
      throw new EdgeError("mfa_required", 403);
    }
    const reportID = requireUUID(body.report_id);
    const revision = requireRevision(body.expected_revision);
    const wallpaperRevision = requireRevision(body.expected_wallpaper_revision);
    const action = requireEnum(
      body.action,
      [
        "close_no_action",
        "hide_pending_review",
        "delist",
      ] as const,
    );
    const reason = requireEnum(
      body.reason_code,
      [
        "no_violation",
        "copyright",
        "impersonation",
        "unsafe",
        "sexual",
        "hate",
        "violence",
        "spam",
        "misleading",
        "other",
      ] as const,
    );
    if (
      revision < 1 || wallpaperRevision < 1 ||
      ((action === "close_no_action") !== (reason === "no_violation"))
    ) {
      throw new EdgeError("invalid_request", 400);
    }
    const note = requirePlainText(body.private_note, 1, 2_000);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "resolve_report",
      120,
      3_600,
    );
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_resolve_report_v1",
      {
        actor_id: auth.actorID,
        actor_aal: auth.assuranceLevel,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        report_id: reportID,
        expected_revision: revision,
        expected_wallpaper_revision: wallpaperRevision,
        resolution_action: action,
        reason_code: reason,
        private_note: note,
      },
    );
    if (
      !isObject(data) || data.report_id !== reportID ||
      data.action !== action ||
      data.status !==
        (action === "hide_pending_review" ? "triaged" : "closed") ||
      !Number.isSafeInteger(data.revision) ||
      Number(data.revision) <= revision ||
      !Number.isSafeInteger(data.wallpaper_revision) ||
      Number(data.wallpaper_revision) < wallpaperRevision ||
      typeof data.wallpaper_id !== "string" ||
      !["draft", "published", "hidden", "suspended", "removed"].includes(
        String(data.wallpaper_status),
      )
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    requireUUID(data.wallpaper_id);
    return success(API_VERSION, requestID, data);
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

if (import.meta.main) {
  Deno.serve((request) =>
    handleResolveReport(request, productionDependencies())
  );
}
