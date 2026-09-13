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
  requireEnvelope,
  requireExactKeys,
  requirePlainText,
  requireRevision,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "account.v1";

export async function handleRequestAccountDeletion(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readBoundedJSON(request, 8_192);
    if (body.operation === "status") {
      requireExactKeys(body, [
        "api_version",
        "request_id",
        "idempotency_key",
        "operation",
        "deletion_id",
      ]);
      const envelope = requireEnvelope(body, API_VERSION);
      requestID = envelope.requestID;
      const auth = await dependencies.authenticate(request);
      const deletionID = requireUUID(body.deletion_id);
      await enforceRateLimit(
        dependencies.database,
        auth.actorID,
        "account_deletion_status",
        120,
        3_600,
      );
      const data = await dependencies.database.rpc<unknown>(
        "wali_edge_account_deletion_status_v1",
        { actor_id: auth.actorID, deletion_id: deletionID },
      );
      if (!validDeletionStatus(data, deletionID)) {
        throw new EdgeError("temporarily_unavailable", 503, true);
      }
      return success(API_VERSION, requestID, data);
    }
    if (body.operation === "finalize_identity") {
      requireExactKeys(body, [
        "api_version",
        "request_id",
        "idempotency_key",
        "operation",
        "deletion_id",
        "expected_revision",
      ]);
      const envelope = requireEnvelope(body, API_VERSION);
      requestID = envelope.requestID;
      const auth = await dependencies.authenticate(request);
      requireFreshAAL2(auth, dependencies.now());
      const deletionID = requireUUID(body.deletion_id);
      const expectedRevision = requireRevision(body.expected_revision);
      await enforceRateLimit(
        dependencies.database,
        auth.actorID,
        "account_identity_finalize",
        20,
        3_600,
      );
      const prepared = await dependencies.database.rpc<unknown>(
        "wali_edge_prepare_account_identity_deletion_v1",
        {
          actor_id: auth.actorID,
          actor_aal: auth.assuranceLevel,
          deletion_id: deletionID,
          expected_revision: expectedRevision,
        },
      );
      if (
        !isObject(prepared) || prepared.deletion_id !== deletionID ||
        typeof prepared.user_id !== "string" ||
        typeof prepared.completed !== "boolean"
      ) throw new EdgeError("temporarily_unavailable", 503, true);
      if (!prepared.completed) {
        await softDeleteAndVerifyIdentity(
          requireUUID(prepared.user_id),
          dependencies,
        );
      }
      const data = await dependencies.database.rpc<unknown>(
        "wali_edge_finalize_account_identity_deletion_v1",
        {
          actor_id: auth.actorID,
          actor_aal: auth.assuranceLevel,
          request_id: requestID,
          deletion_id: deletionID,
          expected_revision: expectedRevision,
        },
      );
      if (
        !validDeletionStatus(data, deletionID) || data.status !== "completed"
      ) {
        throw new EdgeError("temporarily_unavailable", 503, true);
      }
      return success(API_VERSION, requestID, data);
    }
    requireExactKeys(body, [
      "api_version",
      "request_id",
      "idempotency_key",
      "expected_profile_revision",
      "confirmation",
    ]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    requireFreshAAL2(auth, dependencies.now());
    const expectedRevision = requireRevision(body.expected_profile_revision);
    if (requirePlainText(body.confirmation, 14, 14) !== "DELETE MY WALI") {
      throw new EdgeError("invalid_request", 400);
    }
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "account_deletion",
      2,
      86_400,
    );
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_request_account_deletion_v1",
      {
        actor_id: auth.actorID,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        expected_profile_revision: expectedRevision,
      },
    );
    if (
      !isObject(data) || data.status !== "deletion_pending" ||
      typeof data.revision !== "number"
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    const marked = await dependencies.database.rpc<unknown>(
      "wali_edge_mark_account_deletion_sessions_revoked_v1",
      {
        actor_id: auth.actorID,
        deletion_id: data.deletion_id,
        provider_operation_id: requestID,
      },
    );
    if (
      !isObject(marked) || marked.deletion_id !== data.deletion_id ||
      marked.status !== "deletion_pending" ||
      marked.auth_identity_status !== "sessions_revoked" ||
      typeof marked.revision !== "number"
    ) throw new EdgeError("temporarily_unavailable", 503, true);
    return success(API_VERSION, requestID, marked, 202);
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

function requireFreshAAL2(
  auth: { assuranceLevel: string; authenticatedAt?: number },
  now: Date,
): void {
  const current = Math.floor(now.getTime() / 1_000);
  if (
    auth.assuranceLevel !== "aal2" ||
    !Number.isSafeInteger(auth.authenticatedAt) ||
    (auth.authenticatedAt as number) > current + 30 ||
    current - (auth.authenticatedAt as number) > 300
  ) throw new EdgeError("reauthentication_required", 403);
}

function validDeletionStatus(
  value: unknown,
  deletionID: string,
): value is Record<string, unknown> {
  return isObject(value) && value.deletion_id === deletionID &&
    typeof value.status === "string" &&
    [
      "pending",
      "processing",
      "held",
      "awaiting_auth_cleanup",
      "completed",
      "failed",
      "cancelled",
    ]
      .includes(value.status) &&
    typeof value.auth_identity_status === "string" &&
    Number.isSafeInteger(value.revision);
}

async function softDeleteAndVerifyIdentity(
  userID: string,
  dependencies: EndpointDependencies,
): Promise<void> {
  const endpoint = new URL(
    `/auth/v1/admin/users/${userID}`,
    dependencies.supabaseURL,
  );
  const headers = {
    authorization: `Bearer ${dependencies.serviceRoleKey}`,
    apikey: dependencies.serviceRoleKey,
  };
  let deletion: Response;
  try {
    deletion = await dependencies.fetcher(endpoint, {
      method: "DELETE",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify({ should_soft_delete: true }),
      redirect: "error",
    });
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  if (!(deletion.ok || deletion.status === 404)) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const verificationEndpoint = new URL(
    `/auth/v1/admin/users/${userID}`,
    dependencies.supabaseURL,
  );
  let verification: Response;
  try {
    verification = await dependencies.fetcher(verificationEndpoint, {
      method: "GET",
      headers,
      redirect: "error",
    });
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  if (verification.status === 404) return;
  if (!verification.ok) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const user = await verification.json().catch(() => null);
  if (
    !isObject(user) || typeof user.deleted_at !== "string" || !user.deleted_at
  ) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
}

if (import.meta.main) {
  Deno.serve((request) =>
    handleRequestAccountDeletion(request, productionDependencies())
  );
}
