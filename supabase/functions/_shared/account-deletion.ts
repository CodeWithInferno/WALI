import { EdgeError } from "./errors.ts";
import { isObject, requireUUID } from "./validation.ts";

export const DELETION_POLICY_VERSION = "2026-09-13";
export type AppleDeletionBinding = {
  actorID: string;
  clientID: string;
  appleSubject: string;
  encryptedRefreshToken: string;
  keyVersion: string;
  revision: number;
};
export type DeletionLease = {
  run_token: string;
  job_id: string;
  lease_token: string;
  expected_revision: number;
};

export function unavailable(): never {
  throw new EdgeError("temporarily_unavailable", 503, true);
}
export function exactResult(
  value: unknown,
  keys: readonly string[],
): value is Record<string, unknown> {
  return isObject(value) && Object.keys(value).length === keys.length &&
    keys.every((key) => Object.hasOwn(value, key));
}
export function validRevision(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) > 0;
}
function validTime(value: unknown): value is string {
  return typeof value === "string" && value.length <= 40 &&
    /^\d{4}-\d{2}-\d{2}T/.test(value) && Number.isFinite(Date.parse(value));
}
export function validReceipt(value: unknown): value is Record<string, unknown> {
  if (
    !exactResult(value, [
      "status",
      "stage",
      "requested_at",
      "completed_at",
      "status_expires_at",
      "retained_categories",
      "apple_action_required",
    ])
  ) return false;
  if (
    ![
      "pending",
      "processing",
      "held",
      "awaiting_auth_cleanup",
      "completed",
      "failed",
      "cancelled",
    ].includes(value.status as string) ||
    ![
      "cleanup",
      "held",
      "apple_revocation",
      "identity_deletion",
      "retrying",
      "completed",
    ].includes(value.stage as string) ||
    !validTime(value.requested_at) ||
    typeof value.apple_action_required !== "boolean" ||
    !Array.isArray(value.retained_categories) ||
    value.retained_categories.length > 8 ||
    !value.retained_categories.every((item) =>
      typeof item === "string" && /^[a-z][a-z0-9_]{0,47}$/.test(item)
    )
  ) return false;
  if (value.status === "completed") {
    return value.stage === "completed" && validTime(value.completed_at) &&
      validTime(value.status_expires_at) &&
      Date.parse(value.status_expires_at) - Date.parse(value.completed_at) ===
        30 * 86400_000;
  }
  return value.completed_at === null && value.status_expires_at === null &&
    value.stage !== "completed";
}

export async function capabilityHash(capability: unknown): Promise<string> {
  if (typeof capability !== "string" || !/^[a-f0-9]{64}$/.test(capability)) {
    throw new EdgeError("invalid_request", 400);
  }
  const bytes = Uint8Array.from(
    capability.match(/../g)!,
    (part) => Number.parseInt(part, 16),
  );
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
    .map((value) => value.toString(16).padStart(2, "0")).join("");
}

export function leaseFrom(value: unknown, runToken: string): DeletionLease {
  if (
    !exactResult(value, ["job_id", "lease_token", "revision"]) ||
    !validRevision(value.revision)
  ) unavailable();
  try {
    return {
      run_token: runToken,
      job_id: requireUUID(value.job_id),
      lease_token: requireUUID(value.lease_token),
      expected_revision: value.revision,
    };
  } catch {
    unavailable();
  }
}

export function appleBindings(
  value: unknown,
  actorID: string,
): AppleDeletionBinding[] {
  if (!Array.isArray(value) || value.length > 2) unavailable();
  const clients = new Set<string>();
  return value.map((row) => {
    if (
      !exactResult(row, [
        "actor_id",
        "client_id",
        "apple_subject",
        "encrypted_refresh_token",
        "encryption_key_version",
        "revision",
      ]) ||
      row.actor_id !== actorID ||
      !["com.wali.store.WALI", "com.wali.store.development.WALI"].includes(
        row.client_id as string,
      ) ||
      clients.has(row.client_id as string) || !validRevision(row.revision) ||
      typeof row.apple_subject !== "string" || row.apple_subject.length > 256 ||
      !/^[A-Za-z0-9._-]+$/.test(row.apple_subject) ||
      typeof row.encrypted_refresh_token !== "string" ||
      row.encrypted_refresh_token.length < 42 ||
      row.encrypted_refresh_token.length > 11020 ||
      !/^v1\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]+$/.test(
        row.encrypted_refresh_token,
      ) ||
      typeof row.encryption_key_version !== "string" ||
      !/^[A-Za-z0-9_-]{1,32}$/.test(row.encryption_key_version)
    ) unavailable();
    clients.add(row.client_id as string);
    return {
      actorID,
      clientID: row.client_id as string,
      appleSubject: row.apple_subject,
      encryptedRefreshToken: row.encrypted_refresh_token,
      keyVersion: row.encryption_key_version,
      revision: row.revision,
    };
  });
}
