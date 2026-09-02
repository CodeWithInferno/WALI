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
  requirePlainText,
  requireRevision,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "moderation.v1";

export async function handleAdminRoleGrant(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readExactJSON(request, 16_384, [
      "api_version",
      "request_id",
      "idempotency_key",
      "target_user_id",
      "role",
      "desired_active",
      "reason_code",
      "reason_text",
      "expected_role_revision",
    ]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    if (auth.assuranceLevel !== "aal2") {
      throw new EdgeError("mfa_required", 403);
    }
    const targetUserID = requireUUID(body.target_user_id);
    const role = requireEnum(
      body.role,
      ["creator", "moderator", "admin"] as const,
    );
    if (typeof body.desired_active !== "boolean") {
      throw new EdgeError("invalid_request", 400);
    }
    const reasonCode = requirePlainText(body.reason_code, 3, 96);
    if (!/^[a-z][a-z0-9_.-]+$/.test(reasonCode)) {
      throw new EdgeError("invalid_request", 400);
    }
    const reasonText = optionalPlainText(body.reason_text, 500);
    const expectedRevision = requireRevision(body.expected_role_revision);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "admin_role_grant",
      60,
      3_600,
    );
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_admin_role_grant_v1",
      {
        actor_id: auth.actorID,
        actor_aal: auth.assuranceLevel,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        target_user_id: targetUserID,
        target_role: role,
        desired_active: body.desired_active,
        reason_code: reasonCode,
        reason_text: reasonText,
        expected_role_revision: expectedRevision,
      },
    );
    if (
      !isObject(data) || data.target_user_id !== targetUserID ||
      data.role !== role ||
      data.active !== body.desired_active || typeof data.revision !== "number"
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
    handleAdminRoleGrant(request, productionDependencies())
  );
}
