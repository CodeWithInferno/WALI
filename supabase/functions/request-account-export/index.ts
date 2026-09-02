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
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "account.v1";

export async function handleRequestAccountExport(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readBoundedJSON(request, 4_096);
    if (body.operation === "status") {
      requestID = requireEnvelope(body, API_VERSION).requestID;
      return await handleAccountExportStatus(
        request,
        dependencies,
        requireExactKeys(body, [
          "api_version",
          "request_id",
          "idempotency_key",
          "operation",
          "export_id",
        ]),
      );
    }
    requireExactKeys(body, ["api_version", "request_id", "idempotency_key"]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "account_export",
      2,
      86_400,
    );
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_request_account_export_v1",
      {
        actor_id: auth.actorID,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
      },
    );
    if (
      !isObject(data) || typeof data.export_id !== "string" ||
      data.status !== "queued" || typeof data.expires_at !== "string"
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    return success(API_VERSION, requestID, data, 202);
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

async function handleAccountExportStatus(
  request: Request,
  dependencies: EndpointDependencies,
  body: Record<string, unknown>,
): Promise<Response> {
  const envelope = requireEnvelope(body, API_VERSION);
  const auth = await dependencies.authenticate(request);
  const exportID = requireUUID(body.export_id);
  await enforceRateLimit(
    dependencies.database,
    auth.actorID,
    "account_export_status",
    120,
    3_600,
  );
  const status = await dependencies.database.rpc<unknown>(
    "wali_edge_account_export_status_v1",
    { actor_id: auth.actorID, export_id: exportID },
  );
  if (
    !isObject(status) || status.export_id !== exportID ||
    !["queued", "processing", "ready", "expired", "failed"].includes(
      String(status.status),
    ) || typeof status.expires_at !== "string"
  ) throw new EdgeError("temporarily_unavailable", 503, true);
  let downloadURL: string | null = null;
  let downloadExpiresAt: string | null = null;
  if (status.status === "ready") {
    if (
      typeof status.download_path !== "string" ||
      status.download_path !==
        `exports/${auth.actorID}/${exportID}/account.json` ||
      typeof status.byte_count !== "number" || status.byte_count < 2 ||
      typeof status.digest !== "string" ||
      !/^[0-9a-f]{64}$/.test(status.digest)
    ) throw new EdgeError("temporarily_unavailable", 503, true);
    const grant = await createExportDownloadGrant(
      status.download_path,
      auth.accessToken,
      dependencies,
    );
    downloadURL = grant.url;
    downloadExpiresAt = new Date(
      dependencies.now().getTime() + 300_000,
    ).toISOString().replace(".000Z", "Z");
  }
  return success(API_VERSION, envelope.requestID, {
    export_id: exportID,
    status: status.status,
    expires_at: status.expires_at,
    completed_at: status.completed_at ?? null,
    byte_count: status.status === "ready" ? status.byte_count : null,
    digest: status.status === "ready" ? status.digest : null,
    download_url: downloadURL,
    download_expires_at: downloadExpiresAt,
  });
}

async function createExportDownloadGrant(
  storagePath: string,
  accessToken: string,
  dependencies: EndpointDependencies,
): Promise<{ url: string }> {
  const encodedPath = storagePath.split("/").map(encodeURIComponent).join("/");
  const endpoint = new URL(
    `/storage/v1/object/sign/exports-private/${encodedPath}`,
    dependencies.supabaseURL,
  );
  let response: Response;
  try {
    response = await dependencies.fetcher(endpoint, {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        apikey: dependencies.publishableKey,
        "content-type": "application/json",
      },
      body: JSON.stringify({ expiresIn: 300 }),
      redirect: "error",
    });
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  if (!response.ok) throw new EdgeError("temporarily_unavailable", 503, true);
  const value = await response.json().catch(() => null);
  if (!isObject(value) || typeof value.signedURL !== "string") {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  let signed: URL;
  try {
    signed = new URL(value.signedURL, dependencies.supabaseURL);
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const expectedOrigin = new URL(dependencies.supabaseURL).origin;
  if (
    signed.origin !== expectedOrigin || signed.username || signed.password ||
    signed.hash ||
    !signed.pathname.startsWith(
      `/storage/v1/object/sign/exports-private/${encodedPath}`,
    ) || signed.href.length > 4_096
  ) throw new EdgeError("temporarily_unavailable", 503, true);
  return { url: signed.href };
}

if (import.meta.main) {
  Deno.serve((request) =>
    handleRequestAccountExport(request, productionDependencies())
  );
}
