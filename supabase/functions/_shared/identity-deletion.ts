import { EdgeError } from "./errors.ts";
import { isObject, requireUUID } from "./validation.ts";

/** Existing Auth-admin adapter. It never chooses an identity or grants authority. */
export async function softDeleteAndVerifyIdentity(
  userID: string,
  dependencies: {
    supabaseURL: string;
    serviceRoleKey: string;
    fetcher: typeof fetch;
  },
): Promise<void> {
  requireUUID(userID);
  const endpoint = new URL(
    `/auth/v1/admin/users/${userID}`,
    dependencies.supabaseURL,
  );
  const headers = {
    authorization: `Bearer ${dependencies.serviceRoleKey}`,
    apikey: dependencies.serviceRoleKey,
  };
  const signal = AbortSignal.timeout(8_000);
  try {
    const deletion = await dependencies.fetcher(endpoint, {
      method: "DELETE",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify({ should_soft_delete: true }),
      redirect: "error",
      signal,
    });
    await deletion.body?.cancel();
    if (!(deletion.ok || deletion.status === 404)) {
      throw new Error("provider deletion failed");
    }
    const verification = await dependencies.fetcher(endpoint, {
      method: "GET",
      headers,
      redirect: "error",
      signal,
    });
    if (verification.status === 404) {
      await verification.body?.cancel();
      return;
    }
    if (!verification.ok || !verification.body) {
      throw new Error("provider verification failed");
    }
    const reader = verification.body.getReader();
    let bytes = new Uint8Array();
    try {
      while (true) {
        const part = await reader.read();
        if (part.done) break;
        if (bytes.length + part.value.length > 65536) {
          throw new Error("provider response oversized");
        }
        const next = new Uint8Array(bytes.length + part.value.length);
        next.set(bytes);
        next.set(part.value, bytes.length);
        bytes = next;
      }
    } finally {
      await reader.cancel();
    }
    const user = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    );
    if (
      !isObject(user) || user.id !== userID ||
      typeof user.deleted_at !== "string" ||
      !Number.isFinite(Date.parse(user.deleted_at))
    ) {
      throw new Error("provider identity verification failed");
    }
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
}
