import {
  databaseEnvironment,
  type DatabaseGateway,
  PostgRESTDatabase,
} from "../_shared/database.ts";
import { EdgeError, success } from "../_shared/errors.ts";
import {
  type PublicationSignature,
  signPublication,
  validPublicationResponse,
} from "../_shared/publication-signing.ts";
import { safeFailure } from "../_shared/runtime.ts";
import { isObject, readExactJSON, requireUUID } from "../_shared/validation.ts";
const API_VERSION = "publication_worker.v1";
export type AutomaticPublicationDependencies = {
  database: DatabaseGateway;
  dispatchToken: string | undefined;
  sign: (prepared: unknown) => Promise<PublicationSignature>;
  now: () => Date;
};

async function validScheduler(
  request: Request,
  expected: string | undefined,
): Promise<boolean> {
  const supplied = request.headers.get("x-wali-publication-token");
  if (
    !expected || !/^[a-f0-9]{64}$/.test(expected) || !supplied ||
    !/^[a-f0-9]{64}$/.test(supplied)
  ) return false;
  const encoder = new TextEncoder();
  const [left, right] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
    crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
  ]);
  const a = new Uint8Array(left), b = new Uint8Array(right);
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}
export async function handleAutomaticPublication(
  request: Request,
  deps: AutomaticPublicationDependencies,
): Promise<Response> {
  const requestID = crypto.randomUUID();
  try {
    if (request.method !== "POST") throw new EdgeError("invalid_request", 405);
    if (!await validScheduler(request, deps.dispatchToken)) {
      throw new EdgeError("authentication_required", 401);
    }
    const body = await readExactJSON(request, 1024, ["api_version"]);
    if (body.api_version !== API_VERSION) {
      throw new EdgeError("unsupported_api_version", 400);
    }
    const counts = { processed: 0, published: 0, retrying: 0, failed: 0 };
    const deadline = deps.now().getTime() + 45_000;
    for (let index = 0; index < 4 && deps.now().getTime() < deadline; index++) {
      const claimed = await deps.database.rpc<unknown>(
        "wali_edge_claim_automatic_publication_v1",
        {},
      );
      if (!isObject(claimed) || !("job" in claimed)) {
        throw new EdgeError("temporarily_unavailable", 503, true);
      }
      if (claimed.job === null) break;
      if (!isObject(claimed.job)) {
        throw new EdgeError("temporarily_unavailable", 503, true);
      }
      const job = {
        job_id: requireUUID(claimed.job.id),
        lease_token: requireUUID(claimed.job.lease_token),
      };
      counts.processed++;
      try {
        const prepared = await deps.database.rpc<unknown>(
          "wali_edge_prepare_automatic_publication_v1",
          job,
        );
        if (isObject(prepared) && prepared.status === "promotion_pending") {
          await deps.database.rpc("wali_edge_finish_automatic_publication_v1", {
            ...job,
            outcome: "retry",
            safe_error_code: null,
          });
          counts.retrying++;
          continue;
        }
        if (isObject(prepared) && prepared.replayed === true) {
          if (!validPublicationResponse(prepared.response)) {
            throw new EdgeError("temporarily_unavailable", 503, true);
          }
        } else {
          const signature = await deps.sign(prepared);
          const finalized = await deps.database.rpc<unknown>(
            "wali_edge_finalize_automatic_publication_v1",
            { ...job, ...signature },
          );
          if (
            !validPublicationResponse(finalized) || !isObject(prepared) ||
            finalized.wallpaper_id !== prepared.wallpaper_id ||
            finalized.release_id !== prepared.release_id ||
            finalized.edition !== prepared.edition ||
            finalized.manifest_digest !== signature.manifest_digest ||
            finalized.key_id !== signature.signing_key_id
          ) throw new EdgeError("temporarily_unavailable", 503, true);
        }
        const finished = await deps.database.rpc<unknown>(
          "wali_edge_finish_automatic_publication_v1",
          { ...job, outcome: "completed", safe_error_code: null },
        );
        if (finished !== true) {
          throw new EdgeError("temporarily_unavailable", 503, true);
        }
        counts.published++;
      } catch (error) {
        if (
          error instanceof EdgeError && error.code === "publication_lease_lost"
        ) {
          counts.retrying++;
          continue;
        }
        const permanent = error instanceof EdgeError &&
          error.code === "publication_not_eligible";
        await deps.database.rpc("wali_edge_finish_automatic_publication_v1", {
          ...job,
          outcome: permanent ? "failed" : "retry",
          safe_error_code: permanent
            ? "WALI_PUBLICATION_NOT_ELIGIBLE"
            : "WALI_PUBLICATION_RETRYING",
        });
        if (permanent) counts.failed++;
        else counts.retrying++;
      }
    }
    return success(API_VERSION, requestID, counts);
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}
if (import.meta.main) {
  Deno.serve((request) => {
    const database = new PostgRESTDatabase(
      databaseEnvironment(),
      (input, init) =>
        fetch(input, { ...init, signal: AbortSignal.timeout(10_000) }),
    );
    return handleAutomaticPublication(request, {
      database,
      dispatchToken: Deno.env.get("WALI_AUTOMATIC_PUBLICATION_TOKEN"),
      sign: signPublication,
      now: () => new Date(),
    });
  });
}
