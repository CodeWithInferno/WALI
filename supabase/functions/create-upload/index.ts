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
  requireInteger,
  requirePlainText,
  requireRevision,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "creator.v1";

export async function handleCreateUpload(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readExactJSON(request, 16_384, [
      "api_version",
      "request_id",
      "idempotency_key",
      "declared_byte_count",
      "container_hint",
      "original_filename",
      "target",
    ]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    const byteCount = requireInteger(
      body.declared_byte_count,
      1,
      1_073_741_824,
    );
    const container = requireEnum(
      body.container_hint,
      ["video/mp4", "video/quicktime"] as const,
    );
    const filename = singleFilename(
      requirePlainText(body.original_filename, 1, 255),
    );
    const target = parseTarget(body.target);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "create_upload",
      10,
      86_400,
    );
    const reservation = await dependencies.database.rpc<unknown>(
      "wali_edge_create_upload_v1",
      {
        actor_id: auth.actorID,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        declared_byte_count: byteCount,
        container_hint: container,
        original_filename: filename,
        target_kind: target.kind,
        target_wallpaper_id: target.wallpaperID,
        expected_wallpaper_revision: target.expectedRevision,
      },
    );
    if (
      !isObject(reservation) ||
      typeof reservation.upload_session_id !== "string" ||
      typeof reservation.storage_path !== "string" ||
      typeof reservation.expires_at !== "string" ||
      typeof reservation.revision !== "number"
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    let sessionRevision = reservation.revision;
    let uploadEndpoint = typeof reservation.upload_endpoint === "string"
      ? reservation.upload_endpoint
      : null;
    if (uploadEndpoint === null) {
      uploadEndpoint = await createTUSResource(
        dependencies,
        auth.accessToken,
        reservation.storage_path,
        byteCount,
        container,
      );
      const binding = await dependencies.database.rpc<unknown>(
        "wali_edge_bind_upload_endpoint_v1",
        {
          actor_id: auth.actorID,
          upload_session_id: reservation.upload_session_id,
          expected_session_revision: reservation.revision,
          upload_endpoint: uploadEndpoint,
        },
      );
      if (!isObject(binding) || typeof binding.revision !== "number") {
        throw new EdgeError("temporarily_unavailable", 503, true);
      }
      sessionRevision = binding.revision;
    }
    return success(API_VERSION, requestID, {
      upload_session_id: reservation.upload_session_id,
      revision: sessionRevision,
      expires_at: reservation.expires_at,
      upload_endpoint: uploadEndpoint,
      required_headers: { "Tus-Resumable": "1.0.0" },
      scoped_upload_token: auth.accessToken,
    }, 201);
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

function parseTarget(
  value: unknown,
): {
  kind: "new" | "wallpaper_update";
  wallpaperID: string | null;
  expectedRevision: number | null;
} {
  if (!isObject(value)) throw new EdgeError("invalid_request", 400);
  if (value.kind === "new" && Object.keys(value).length === 1) {
    return { kind: "new", wallpaperID: null, expectedRevision: null };
  }
  if (
    value.kind === "wallpaper_update" &&
    Object.keys(value).sort().join(",") ===
      "expected_revision,kind,wallpaper_id"
  ) {
    return {
      kind: "wallpaper_update",
      wallpaperID: requireUUID(value.wallpaper_id),
      expectedRevision: requireRevision(value.expected_revision),
    };
  }
  throw new EdgeError("invalid_request", 400);
}

function singleFilename(value: string): string {
  if (
    value.includes("/") || value.includes("\\") || value === "." ||
    value === ".."
  ) throw new EdgeError("invalid_request", 400);
  return value;
}

async function createTUSResource(
  dependencies: EndpointDependencies,
  accessToken: string,
  path: string,
  byteCount: number,
  container: string,
): Promise<string> {
  const endpoint = new URL(
    "/storage/v1/upload/resumable",
    dependencies.supabaseURL,
  );
  const metadata = [
    ["bucketName", "uploads-private"],
    ["objectName", path],
    ["contentType", container],
    ["cacheControl", "no-cache"],
  ].map(([key, value]) => `${key} ${btoa(value)}`).join(",");
  let response: Response;
  try {
    response = await dependencies.fetcher(endpoint, {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        apikey: dependencies.publishableKey,
        "Tus-Resumable": "1.0.0",
        "Upload-Length": String(byteCount),
        "Upload-Metadata": metadata,
        "x-upsert": "false",
      },
      redirect: "error",
    });
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const location = response.headers.get("location");
  if (response.status !== 201 || !location) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const resolved = new URL(location, endpoint);
  if (
    resolved.origin !== endpoint.origin ||
    resolved.protocol !== endpoint.protocol || resolved.username ||
    resolved.password
  ) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  return resolved.href;
}

if (import.meta.main) {
  Deno.serve((request) =>
    handleCreateUpload(request, productionDependencies())
  );
}
