export type ErrorBody = {
  code: string;
  message?: string;
  retryable: boolean;
};

const SAFE_MESSAGES: Readonly<Record<string, string>> = {
  invalid_request: "The request could not be completed.",
  unsupported_api_version: "This client version is not supported.",
  authentication_required: "Sign in to continue.",
  forbidden: "You do not have access to this action.",
  mfa_required: "Two-factor authentication is required.",
  reauthentication_required:
    "Reauthenticate with two-factor authentication to continue.",
  stale_revision: "This item changed. Refresh and try again.",
  idempotency_conflict: "This request key was already used.",
  rate_limited: "Too many requests. Try again shortly.",
  rights_workflow_unavailable: "Licensed proof review is not available yet.",
  catalog_admission_unavailable: "Staff catalog uploads are unavailable.",
  catalog_attestation_required:
    "Accept the current Catalog License Attestation to continue.",
  revocation_stale: "The revocation list changed. Refresh and try again.",
  revocation_signing_unavailable: "The revocation could not be signed.",
  temporarily_unavailable: "The service is temporarily unavailable.",
};

export class EdgeError extends Error {
  constructor(
    readonly code: string,
    readonly status: number,
    readonly retryable = false,
    readonly retryAfterSeconds?: number,
  ) {
    super(code);
  }
}

export function success(
  apiVersion: string,
  requestID: string,
  data: unknown,
  status = 200,
): Response {
  return jsonResponse(
    { api_version: apiVersion, request_id: requestID, data },
    status,
  );
}

export function failure(
  apiVersion: string,
  requestID: string,
  error: EdgeError,
): Response {
  const headers = new Headers({
    "content-type": "application/json; charset=utf-8",
  });
  if (error.retryAfterSeconds !== undefined) {
    headers.set("retry-after", String(error.retryAfterSeconds));
  }
  const body: ErrorBody = {
    code: error.code,
    message: SAFE_MESSAGES[error.code],
    retryable: error.retryable,
  };
  return new Response(
    JSON.stringify({
      api_version: apiVersion,
      request_id: requestID,
      error: body,
    }),
    { status: error.status, headers },
  );
}

export function jsonResponse(value: unknown, status: number): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

export function mapDatabaseError(message: string): EdgeError {
  const mappings: ReadonlyArray<readonly [string, string, number, boolean]> = [
    ["WALI_IDEMPOTENCY_CONFLICT", "idempotency_conflict", 409, false],
    ["WALI_REVISION_MISMATCH", "stale_revision", 409, false],
    ["WALI_REPORT_NOT_FOUND", "not_found", 404, false],
    ["WALI_REPORT_ASSIGNED_ELSEWHERE", "stale_revision", 409, false],
    ["WALI_SELF_REVIEW_FORBIDDEN", "self_review_forbidden", 403, false],
    ["WALI_AUTH_REQUIRED", "authentication_required", 401, false],
    ["WALI_AUTH_SUBJECT_CHANGED", "authentication_required", 401, false],
    ["WALI_ACCOUNT_INACTIVE", "account_suspended", 403, false],
    ["WALI_CREATOR_ROLE_REVOKED", "creator_role_required", 403, false],
    ["WALI_CREATOR_ROLE_REQUIRED", "creator_role_required", 403, false],
    ["WALI_CREATOR_TERMS_REQUIRED", "creator_terms_required", 403, false],
    [
      "WALI_RIGHTS_WORKFLOW_UNAVAILABLE",
      "rights_workflow_unavailable",
      409,
      false,
    ],
    ["WALI_SECURITY_RESPONSE_AAL2_REQUIRED", "forbidden", 403, false],
    ["WALI_REVOCATION_STALE", "revocation_stale", 409, false],
    ["WALI_RELEASE_ALREADY_REVOKED", "release_revoked", 409, false],
    ["WALI_RELEASE_NOT_PUBLISHED", "release_not_published", 409, false],
    ["WALI_EXPORT_NOT_FOUND", "not_found", 404, false],
    ["WALI_DELETION_NOT_FOUND", "not_found", 404, false],
    ["WALI_DELETION_NOT_READY", "stale_revision", 409, false],
    ["WALI_MODERATOR_AAL2_REQUIRED", "mfa_required", 403, false],
    ["WALI_ADMIN_AAL2_REQUIRED", "mfa_required", 403, false],
    ["WALI_RELEASE_NOT_CURRENT", "release_not_current", 409, false],
    ["WALI_RELEASE_NOT_AVAILABLE", "release_revoked", 409, false],
    ["WALI_INSTALL_RECEIPT_EXPIRED", "install_receipt_expired", 409, false],
    ["WALI_INSTALL_RECEIPT_CONSUMED", "install_receipt_consumed", 409, false],
    ["WALI_INSTALL_RECEIPT_INVALID", "install_receipt_invalid", 400, false],
    ["WALI_MANIFEST_INVALID", "manifest_unavailable", 409, false],
    [
      "WALI_CATALOG_ADMISSION_UNAVAILABLE",
      "catalog_admission_unavailable",
      403,
      false,
    ],
    [
      "WALI_CATALOG_ATTESTATION_REQUIRED",
      "catalog_attestation_required",
      403,
      false,
    ],
    ["WALI_CATALOG_UPLOAD_QUOTA_EXCEEDED", "rate_limited", 429, false],
    ["WALI_ADMISSION_MISMATCH", "forbidden", 403, false],
    ["WALI_ATTESTATION_BINDING_INVALID", "forbidden", 403, false],
    ["WALI_ADMISSION_IMMUTABLE", "forbidden", 403, false],
    ["WALI_RIGHTS_INCOMPLETE", "rights_incomplete", 400, false],
    ["WALI_UPLOAD_TARGET_INVALID", "invalid_request", 400, false],
    ["WALI_UPLOAD_ALREADY_BOUND", "stale_revision", 409, false],
    ["WALI_UPLOAD_EXPIRED", "upload_expired", 409, false],
    ["WALI_UPLOAD_INCOMPLETE", "upload_incomplete", 409, true],
    ["WALI_UPLOAD_CHANGED", "upload_changed", 409, false],
    ["WALI_STALE_PROCESSING_GENERATION", "stale_revision", 409, false],
    ["WALI_SUBMISSION_NOT_READY", "submission_not_ready", 409, false],
    [
      "WALI_PROCESSING_CAPACITY_UNAVAILABLE",
      "processing_capacity_unavailable",
      429,
      true,
    ],
    ["WALI_REQUEST_INVALID", "invalid_request", 400, false],
  ];
  for (const [marker, code, status, retryable] of mappings) {
    if (message.includes(marker)) return new EdgeError(code, status, retryable);
  }
  return new EdgeError("temporarily_unavailable", 503, true);
}
