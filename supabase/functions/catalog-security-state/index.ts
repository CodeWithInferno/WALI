import { EdgeError } from "../_shared/errors.ts";
import {
  type EndpointDependencies,
  productionDependencies,
  safeFailure,
  UNKNOWN_REQUEST_ID,
} from "../_shared/runtime.ts";
import { isObject, readExactJSON, requireUUID } from "../_shared/validation.ts";

const API_VERSION = "catalog.v1";

export async function handleCatalogSecurityState(
  request: Request,
  dependencies: EndpointDependencies,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    const body = await readExactJSON(request, 4_096, [
      "api_version",
      "request_id",
    ]);
    if (body.api_version !== API_VERSION) {
      throw new EdgeError("unsupported_api_version", 400);
    }
    requestID = requireUUID(body.request_id);
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_catalog_security_state_v1",
      {},
    );
    validateSecurityState(data);
    const state = data as Record<string, unknown>;
    const revocations = state.revocations as Record<string, unknown>;
    const transition = state.trust_transition as Record<string, unknown> | null;
    const etag = `W/"wali-security-t${
      transition?.revision ?? 0
    }-r${revocations.revision}"`;
    const headers = new Headers({
      "cache-control": "public, max-age=60, stale-if-error=300",
      "content-type": "application/json; charset=utf-8",
      etag,
      "x-content-type-options": "nosniff",
    });
    if (request.headers.get("if-none-match") === etag) {
      return new Response(null, { status: 304, headers });
    }
    return new Response(
      JSON.stringify({ api_version: API_VERSION, request_id: requestID, data }),
      { status: 200, headers },
    );
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}

function validateSecurityState(value: unknown): void {
  if (!isObject(value) || !isObject(value.revocations)) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  validateSignedDocument(value.revocations);
  if (value.trust_transition !== null) {
    if (!isObject(value.trust_transition)) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    validateSignedDocument(value.trust_transition);
  }
}

function validateSignedDocument(value: Record<string, unknown>): void {
  if (
    !Number.isSafeInteger(value.revision) || (value.revision as number) < 0 ||
    typeof value.body !== "string" || value.body.length > 1_398_102 ||
    !/^[A-Za-z0-9_-]+$/.test(value.body) ||
    typeof value.signature !== "string" || value.signature.length > 86 ||
    !/^[A-Za-z0-9_-]+$/.test(value.signature) ||
    typeof value.key_id !== "string" || value.key_id.length < 3 ||
    value.key_id.length > 128
  ) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
}

if (import.meta.main) {
  Deno.serve((request) =>
    handleCatalogSecurityState(request, productionDependencies())
  );
}
