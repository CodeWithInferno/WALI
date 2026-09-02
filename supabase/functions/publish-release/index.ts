import { EdgeError, success } from "../_shared/errors.ts";
import {
  buildSignedPublication,
  signCanonicalDocument,
  unpaddedBase64URL,
} from "../_shared/manifest.ts";
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
  requireRevision,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "moderation.v1";

export async function handlePublishRelease(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let body: Record<string, unknown>;
  try {
    body = await readBoundedJSON(request, 16_384);
  } catch (error) {
    return safeFailure(API_VERSION, UNKNOWN_REQUEST_ID, error);
  }
  if (body.operation === "issue_catalog_revocation") {
    return handleIssueCatalogRevocation(request, dependencies, body);
  }
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    requireExactKeys(body, [
      "api_version",
      "request_id",
      "idempotency_key",
      "submission_id",
      "expected_revision",
      "expected_generation",
      "expected_wallpaper_revision",
      "manifest_schema",
    ]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    const auth = await dependencies.authenticate(request);
    if (auth.assuranceLevel !== "aal2") {
      throw new EdgeError("mfa_required", 403);
    }
    const submissionID = requireUUID(body.submission_id);
    const expectedRevision = requireRevision(body.expected_revision);
    const expectedGeneration = requireRevision(body.expected_generation);
    const expectedWallpaperRevision = requireRevision(
      body.expected_wallpaper_revision,
    );
    if (
      !isObject(body.manifest_schema) ||
      Object.keys(body.manifest_schema).sort().join(",") !== "epoch,revision" ||
      body.manifest_schema.epoch !== 1 || body.manifest_schema.revision !== 0
    ) throw new EdgeError("invalid_request", 400);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "publish_release",
      30,
      3_600,
    );
    const prepared = await dependencies.database.rpc<unknown>(
      "wali_edge_prepare_publication_v1",
      {
        actor_id: auth.actorID,
        actor_aal: auth.assuranceLevel,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        submission_id: submissionID,
        expected_revision: expectedRevision,
        expected_generation: expectedGeneration,
        expected_wallpaper_revision: expectedWallpaperRevision,
      },
    );
    if (isObject(prepared) && prepared.replayed === true) {
      const replayed = prepared.response;
      if (!validPublicationResponse(replayed)) {
        throw new EdgeError("temporarily_unavailable", 503, true);
      }
      return success(API_VERSION, requestID, replayed);
    }
    if (isObject(prepared) && prepared.status === "promotion_pending") {
      throw new EdgeError("publication_promotion_pending", 409, true, 2);
    }
    const keyID = Deno.env.get("WALI_CATALOG_SIGNING_KEY_ID");
    const privateKey = Deno.env.get("WALI_CATALOG_SIGNING_PRIVATE_KEY_PKCS8");
    const approvedCDNHost = Deno.env.get("WALI_APPROVED_CDN_HOST");
    if (!keyID || !privateKey || !approvedCDNHost) {
      throw new EdgeError("signing_key_unavailable", 503, true);
    }
    const signed = await buildSignedPublication(
      prepared,
      keyID,
      privateKey,
      approvedCDNHost,
    );
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_finalize_publication_v1",
      {
        actor_id: auth.actorID,
        actor_aal: auth.assuranceLevel,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        submission_id: submissionID,
        expected_revision: expectedRevision,
        expected_generation: expectedGeneration,
        expected_wallpaper_revision: expectedWallpaperRevision,
        manifest_body: unpaddedBase64URL(signed.manifestBody),
        metadata_body: unpaddedBase64URL(signed.metadataBody),
        manifest_digest: signed.manifestDigest,
        metadata_digest: signed.metadataDigest,
        manifest_signature: unpaddedBase64URL(signed.signature),
        signing_key_id: keyID,
      },
    );
    if (
      !isObject(data) || typeof data.wallpaper_id !== "string" ||
      typeof data.release_id !== "string" ||
      typeof data.edition !== "number" ||
      data.manifest_digest !== signed.manifestDigest || data.key_id !== keyID ||
      typeof data.wallpaper_revision !== "number" ||
      typeof data.published_at !== "string"
    ) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    return success(API_VERSION, requestID, data);
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

async function handleIssueCatalogRevocation(
  request: Request,
  dependencies: EndpointDependencies,
  body: Record<string, unknown>,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    requireExactKeys(body, [
      "api_version",
      "request_id",
      "idempotency_key",
      "operation",
      "release_id",
      "artifact_digest",
      "expected_list_revision",
      "expected_keyset_revision",
      "reason",
    ]);
    const envelope = requireEnvelope(body, API_VERSION);
    requestID = envelope.requestID;
    if (body.operation !== "issue_catalog_revocation") {
      throw new EdgeError("invalid_request", 400);
    }
    const auth = await dependencies.authenticate(request);
    if (auth.assuranceLevel !== "aal2") {
      throw new EdgeError("mfa_required", 403);
    }
    const releaseID = requireUUID(body.release_id);
    if (
      typeof body.artifact_digest !== "string" ||
      !/^[0-9a-f]{64}$/.test(body.artifact_digest)
    ) throw new EdgeError("invalid_request", 400);
    const expectedListRevision = requireRevision(body.expected_list_revision);
    const expectedKeysetRevision = requireRevision(
      body.expected_keyset_revision,
    );
    const reason = requireEnum(
      body.reason,
      [
        "critical_security",
        "corrupt_artifact",
        "signing_compromise",
      ] as const,
    );
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "issue_catalog_revocation",
      10,
      3_600,
    );
    const prepared = await dependencies.database.rpc<unknown>(
      "wali_edge_prepare_catalog_revocation_v1",
      {
        actor_id: auth.actorID,
        actor_aal: auth.assuranceLevel,
        idempotency_key: envelope.idempotencyKey,
        release_id: releaseID,
        artifact_digest: body.artifact_digest,
        expected_list_revision: expectedListRevision,
        expected_keyset_revision: expectedKeysetRevision,
        reason,
      },
    );
    if (isObject(prepared) && prepared.replayed === true) {
      const replayed = prepared.response;
      if (
        !validRevocationResponse(
          replayed,
          releaseID,
          String(body.artifact_digest),
          reason,
          expectedListRevision + 1,
        )
      ) throw new EdgeError("temporarily_unavailable", 503, true);
      return success(API_VERSION, requestID, replayed);
    }
    const canonicalBody = canonicalRevocationBody(prepared);
    const keyID = Deno.env.get("WALI_CATALOG_SIGNING_KEY_ID");
    const privateKey = Deno.env.get(
      "WALI_CATALOG_SIGNING_PRIVATE_KEY_PKCS8",
    );
    if (!keyID || !privateKey || !isObject(prepared)) {
      throw new EdgeError("signing_key_unavailable", 503, true);
    }
    const signed = await signCanonicalDocument(
      canonicalBody,
      keyID,
      String(prepared.key_id),
      privateKey,
      String(prepared.public_key),
    );
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_finalize_catalog_revocation_v1",
      {
        actor_id: auth.actorID,
        actor_aal: auth.assuranceLevel,
        request_id: requestID,
        idempotency_key: envelope.idempotencyKey,
        release_id: releaseID,
        artifact_digest: body.artifact_digest,
        expected_list_revision: expectedListRevision,
        expected_keyset_revision: expectedKeysetRevision,
        reason,
        canonical_body: unpaddedBase64URL(canonicalBody),
        detached_signature: unpaddedBase64URL(signed.signature),
        signing_key_id: keyID,
      },
    );
    if (
      !isObject(data) || data.release_id !== releaseID ||
      data.artifact_digest !== body.artifact_digest || data.reason !== reason ||
      data.revision !== expectedListRevision + 1 || data.key_id !== keyID ||
      data.body_digest !== signed.digest
    ) throw new EdgeError("temporarily_unavailable", 503, true);
    return success(API_VERSION, requestID, data);
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

function validPublicationResponse(value: unknown): boolean {
  return isObject(value) &&
    typeof value.wallpaper_id === "string" &&
    typeof value.release_id === "string" &&
    Number.isSafeInteger(value.edition) && (value.edition as number) > 0 &&
    typeof value.manifest_digest === "string" &&
    /^[0-9a-f]{64}$/.test(value.manifest_digest) &&
    typeof value.key_id === "string" &&
    /^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$/.test(value.key_id) &&
    Number.isSafeInteger(value.wallpaper_revision) &&
    (value.wallpaper_revision as number) > 0 &&
    typeof value.published_at === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value.published_at);
}

function validRevocationResponse(
  value: unknown,
  releaseID: string,
  artifactDigest: string,
  reason: string,
  revision: number,
): boolean {
  return isObject(value) && value.release_id === releaseID &&
    value.artifact_digest === artifactDigest && value.reason === reason &&
    value.revision === revision && typeof value.key_id === "string" &&
    /^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$/.test(value.key_id) &&
    typeof value.body_digest === "string" &&
    /^[0-9a-f]{64}$/.test(value.body_digest);
}

function canonicalRevocationBody(value: unknown): Uint8Array {
  if (
    !isObject(value) ||
    Object.keys(value).sort().join(",") !==
      "issued_at,key_id,keyset_revision,public_key,revision,revocations" ||
    !Number.isSafeInteger(value.revision) || (value.revision as number) < 1 ||
    !Number.isSafeInteger(value.keyset_revision) ||
    (value.keyset_revision as number) < 0 ||
    typeof value.key_id !== "string" ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$/.test(value.key_id) ||
    typeof value.public_key !== "string" ||
    !/^[A-Za-z0-9_-]{43}$/.test(value.public_key) ||
    typeof value.issued_at !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value.issued_at) ||
    !Array.isArray(value.revocations) || value.revocations.length < 1 ||
    value.revocations.length > 4_096
  ) throw new EdgeError("revocation_signing_unavailable", 503, true);
  let previous = "";
  const entries = value.revocations.map((entry) => {
    if (
      !isObject(entry) ||
      Object.keys(entry).sort().join(",") !==
        "artifact_sha256,issued_at,reason,release_id" ||
      typeof entry.release_id !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
        .test(
          entry.release_id,
        ) ||
      typeof entry.artifact_sha256 !== "string" ||
      !/^[0-9a-f]{64}$/.test(entry.artifact_sha256) ||
      !["critical_security", "corrupt_artifact", "signing_compromise"].includes(
        String(entry.reason),
      ) || typeof entry.issued_at !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(entry.issued_at)
    ) throw new EdgeError("revocation_signing_unavailable", 503, true);
    const sortKey = `${entry.release_id}:${entry.artifact_sha256}`;
    if (sortKey <= previous) {
      throw new EdgeError("revocation_signing_unavailable", 503, true);
    }
    previous = sortKey;
    return `{"release_id":${
      JSON.stringify(entry.release_id)
    },"artifact_sha256":${JSON.stringify(entry.artifact_sha256)},"reason":${
      JSON.stringify(entry.reason)
    },"issued_at":${JSON.stringify(entry.issued_at)}}`;
  });
  const text = `{"schema":{"epoch":1,"revision":0},"key_id":${
    JSON.stringify(value.key_id)
  },"revision":${value.revision},"issued_at":${
    JSON.stringify(value.issued_at)
  },"revocations":[${entries.join(",")}]}`;
  const encoded = new TextEncoder().encode(text);
  if (encoded.length > 1_048_576) {
    throw new EdgeError("revocation_signing_unavailable", 503, true);
  }
  return encoded;
}

if (import.meta.main) {
  Deno.serve((request) =>
    handlePublishRelease(request, productionDependencies())
  );
}
