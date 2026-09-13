import {
  appleBindings,
  type AppleDeletionBinding,
  exactResult,
  leaseFrom,
  unavailable,
  validRevision,
} from "../_shared/account-deletion.ts";
import {
  appleAuthorizationConfigurationFromEnvironment,
  revokeAppleAuthorization,
} from "../_shared/apple-authorization.ts";
import {
  databaseEnvironment,
  type DatabaseGateway,
  PostgRESTDatabase,
} from "../_shared/database.ts";
import { EdgeError, success } from "../_shared/errors.ts";
import { softDeleteAndVerifyIdentity } from "../_shared/identity-deletion.ts";
import { safeFailure } from "../_shared/runtime.ts";
import { readExactJSON, requireUUID } from "../_shared/validation.ts";

const API_VERSION = "account_deletion_worker.v1";
export type AutomaticAccountDeletionDependencies = {
  database: DatabaseGateway;
  dispatchToken: string | undefined;
  now: () => Date;
  revokeApple: (binding: AppleDeletionBinding) => Promise<void>;
  deleteIdentity: (actorID: string) => Promise<void>;
};

async function validScheduler(
  request: Request,
  expected: string | undefined,
): Promise<boolean> {
  const supplied = request.headers.get("x-wali-account-deletion-token");
  if (
    !expected || !/^[a-f0-9]{64}$/.test(expected) || !supplied ||
    !/^[a-f0-9]{64}$/.test(supplied)
  ) return false;
  const bytes = new TextEncoder();
  const [left, right] = await Promise.all(
    [expected, supplied].map((value) =>
      crypto.subtle.digest("SHA-256", bytes.encode(value))
    ),
  );
  const a = new Uint8Array(left), b = new Uint8Array(right);
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

export async function handleAutomaticAccountDeletion(
  request: Request,
  dependencies: AutomaticAccountDeletionDependencies,
): Promise<Response> {
  const requestID = crypto.randomUUID();
  const deadline = dependencies.now().getTime() + 45_000;
  let runToken: string | null = null;
  const counts = { processed: 0, completed: 0, retrying: 0 };
  const enoughTime = () => dependencies.now().getTime() + 8_000 <= deadline;
  async function bounded<T>(operation: () => Promise<T>): Promise<T> {
    if (!enoughTime()) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        operation(),
        new Promise<never>((_, reject) => {
          timer = setTimeout(
            () => reject(new EdgeError("temporarily_unavailable", 503, true)),
            8_000,
          );
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  }
  const rpc = <T>(name: string, parameters: Record<string, unknown>) =>
    bounded(() => dependencies.database.rpc<T>(name, parameters));
  try {
    if (request.method !== "POST") throw new EdgeError("invalid_request", 405);
    if (!await validScheduler(request, dependencies.dispatchToken)) {
      throw new EdgeError("authentication_required", 401);
    }
    const body = await readExactJSON(request, 1024, ["api_version"]);
    if (body.api_version !== API_VERSION) {
      throw new EdgeError("unsupported_api_version", 400);
    }
    const begun = await rpc<unknown>(
      "wali_edge_begin_account_deletion_dispatch_v1",
      {},
    );
    if (!exactResult(begun, ["run_token"])) unavailable();
    if (begun.run_token === null) {
      return success(API_VERSION, requestID, counts);
    }
    try {
      runToken = requireUUID(begun.run_token);
    } catch {
      unavailable();
    }
    for (let index = 0; index < 4 && enoughTime(); index++) {
      const claimed = await rpc<unknown>(
        "wali_edge_claim_account_deletion_v1",
        { run_token: runToken },
      );
      if (!exactResult(claimed, ["job"])) unavailable();
      if (claimed.job === null) break;
      const lease = leaseFrom(claimed.job, runToken);
      counts.processed++;
      try {
        const prepared = await rpc<unknown>(
          "wali_edge_prepare_automatic_account_deletion_v1",
          lease,
        );
        if (
          !exactResult(prepared, [
            "user_id",
            "deletion_id",
            "revision",
            "apple_authorizations",
          ]) || !validRevision(prepared.revision)
        ) unavailable();
        let actorID: string;
        try {
          actorID = requireUUID(prepared.user_id);
          requireUUID(prepared.deletion_id);
        } catch {
          unavailable();
        }
        lease.expected_revision = prepared.revision;
        for (
          const binding of appleBindings(prepared.apple_authorizations, actorID)
        ) {
          await bounded(() => dependencies.revokeApple(binding));
          const checkpoint = await rpc<unknown>(
            "wali_edge_checkpoint_account_apple_revocation_v1",
            {
              ...lease,
              client_id: binding.clientID,
              expected_binding_revision: binding.revision,
            },
          );
          if (
            !exactResult(checkpoint, ["revision"]) ||
            !validRevision(checkpoint.revision)
          ) unavailable();
          lease.expected_revision = checkpoint.revision;
        }
        const authorization = await rpc<unknown>(
          "wali_edge_authorize_account_identity_deletion_v1",
          lease,
        );
        if (
          !exactResult(authorization, ["user_id", "revision"]) ||
          authorization.user_id !== actorID ||
          !validRevision(authorization.revision)
        ) unavailable();
        lease.expected_revision = authorization.revision;
        await bounded(() => dependencies.deleteIdentity(actorID));
        const completed = await rpc<unknown>(
          "wali_edge_finalize_automatic_account_deletion_v1",
          lease,
        );
        if (
          !exactResult(completed, ["completed", "revision"]) ||
          completed.completed !== true || !validRevision(completed.revision)
        ) unavailable();
        counts.completed++;
      } catch {
        // A timed-out provider may already have completed. Preserve the same job
        // and binding; the next claim reconciles it instead of selecting a user.
        if (enoughTime()) {
          await rpc("wali_edge_retry_account_deletion_v1", {
            ...lease,
            safe_error_code: "WALI_ACCOUNT_DELETION_RETRYING",
          }).catch(() => undefined);
        }
        counts.retrying++;
      }
    }
    return success(API_VERSION, requestID, counts);
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  } finally {
    if (runToken !== null && enoughTime()) {
      await rpc("wali_edge_end_account_deletion_dispatch_v1", {
        run_token: runToken,
      }).catch(() => undefined);
    }
  }
}

if (import.meta.main) {
  Deno.serve((request) => {
    const config = databaseEnvironment();
    return handleAutomaticAccountDeletion(request, {
      database: new PostgRESTDatabase(
        config,
        (input, init) =>
          fetch(input, { ...init, signal: AbortSignal.timeout(8_000) }),
      ),
      dispatchToken: Deno.env.get("WALI_ACCOUNT_DELETION_DISPATCH_TOKEN"),
      now: () => new Date(),
      revokeApple: (binding) =>
        revokeAppleAuthorization(
          binding,
          appleAuthorizationConfigurationFromEnvironment(binding.clientID),
        ),
      deleteIdentity: (actorID) =>
        softDeleteAndVerifyIdentity(actorID, { ...config, fetcher: fetch }),
    });
  });
}
