import { authenticate } from "../_shared/auth.ts";
import { databaseEnvironment, PostgRESTDatabase } from "../_shared/database.ts";
import {
  type AppleAuthorizationBinding,
  type AppleAuthorizationConfiguration,
  appleAuthorizationConfigurationFromEnvironment,
  appleSHA256,
  exchangeAppleAuthorization,
  requireAppleClientID,
  revokeAppleAuthorization,
  verifyAppleIdentityToken,
} from "../_shared/apple-authorization.ts";
import { EdgeError, success } from "../_shared/errors.ts";
import { enforceRateLimit } from "../_shared/rate-limit.ts";
import {
  type EndpointDependencies,
  safeFailure,
  UNKNOWN_REQUEST_ID,
} from "../_shared/runtime.ts";
import {
  isObject,
  readExactJSON,
  requirePlainText,
  requireUUID,
} from "../_shared/validation.ts";

const API_VERSION = "apple_authorization.v1";
export async function handleBindAppleAuthorization(
  request: Request,
  dependencies: EndpointDependencies,
  configuration: (clientID: string) => AppleAuthorizationConfiguration =
    appleAuthorizationConfigurationFromEnvironment,
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  let pending:
    | { actorID: string; clientID: string; leaseToken: string }
    | undefined;
  let exchanged: AppleAuthorizationBinding | undefined;
  let commitStarted = false;
  try {
    const body = await readExactJSON(request, 24576, [
      "api_version",
      "request_id",
      "client_id",
      "id_token",
      "nonce",
      "authorization_code",
    ]);
    if (body.api_version !== API_VERSION) {
      throw new EdgeError("unsupported_api_version", 400);
    }
    requestID = requireUUID(body.request_id);
    const clientID = requireAppleClientID(body.client_id);
    const idToken = requirePlainText(body.id_token, 1, 16384);
    const nonce = requirePlainText(body.nonce, 16, 256);
    const authorizationCode = requirePlainText(
      body.authorization_code,
      1,
      4096,
    );
    const auth = await dependencies.authenticate(request);
    await enforceRateLimit(
      dependencies.database,
      auth.actorID,
      "apple_authorization",
      12,
      3600,
    );
    const identity = await verifyAppleIdentityToken(
      idToken,
      clientID,
      nonce,
      dependencies.fetcher,
      dependencies.now(),
    );
    const codeHash = await appleSHA256(authorizationCode);
    const begun = await dependencies.database.rpc<unknown>(
      "wali_edge_begin_apple_authorization_v1",
      {
        actor_id: auth.actorID,
        client_id: clientID,
        apple_subject: identity.subject,
        code_sha256: codeHash,
      },
    );
    if (
      !isObject(begun) ||
      Object.keys(begun).sort().join(",") !== "lease_token,revision,status" ||
      !Number.isSafeInteger(begun.revision) || (begun.revision as number) < 1
    ) throw new EdgeError("temporarily_unavailable", 503, true);
    if (begun.status === "bound" && begun.lease_token === null) {
      return success(API_VERSION, requestID, {
        bound: true,
        subject_id: auth.actorID,
      });
    }
    if (begun.status === "busy" && begun.lease_token === null) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    if (begun.status !== "exchange") {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    pending = {
      actorID: auth.actorID,
      clientID,
      leaseToken: requireUUID(begun.lease_token),
    };
    const config = configuration(clientID);
    exchanged = await exchangeAppleAuthorization(
      {
        actorID: auth.actorID,
        clientID,
        appleSubject: identity.subject,
        authorizationCode,
        nonce,
      },
      config,
      dependencies.fetcher,
      dependencies.now(),
    );
    commitStarted = true;
    const parameters = {
      actor_id: auth.actorID,
      client_id: clientID,
      apple_subject: identity.subject,
      code_sha256: codeHash,
      lease_token: pending.leaseToken,
      encrypted_refresh_token: exchanged.encryptedRefreshToken,
      encryption_key_version: exchanged.keyVersion,
    };
    // Replay the same ciphertext after an uncertain reply. Never revoke material
    // that may already be committed and needed by account deletion.
    let completed: unknown;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        completed = await dependencies.database.rpc<unknown>(
          "wali_edge_complete_apple_authorization_v1",
          parameters,
        );
        break;
      } catch (error) {
        if (attempt === 1) throw error;
      }
    }
    if (!isObject(completed) || Object.keys(completed).length !== 1) {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    if (completed.status === "retained") {
      // A prior commit succeeded before deletion froze this account. Its token
      // remains in finalization custody; do not revoke it from the sign-in path.
      throw new EdgeError("authentication_required", 401);
    }
    if (completed.status === "rejected") {
      await revokeAppleAuthorization(exchanged, config, dependencies.fetcher);
      throw new EdgeError("authentication_required", 401);
    }
    if (completed.status !== "bound") {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    return success(API_VERSION, requestID, {
      bound: true,
      subject_id: auth.actorID,
    });
  } catch (error) {
    // Cancel only before commit; after an uncertain commit the durable state or
    // ninety-second lease is reconciled by the same request/finalizer.
    if (pending && !commitStarted) {
      await dependencies.database.rpc(
        "wali_edge_cancel_apple_authorization_v1",
        {
          actor_id: pending.actorID,
          client_id: pending.clientID,
          lease_token: pending.leaseToken,
        },
      ).catch(() => {});
    }
    return safeFailure(API_VERSION, requestID, error);
  }
}
if (import.meta.main) {
  Deno.serve((request) => {
    try {
      return handleBindAppleAuthorization(
        request,
        productionAppleDependencies(),
      );
    } catch (error) {
      return Promise.resolve(
        safeFailure(API_VERSION, UNKNOWN_REQUEST_ID, error),
      );
    }
  });
}

function productionAppleDependencies(): EndpointDependencies {
  const environment = databaseEnvironment();
  if (environment.supabaseURL !== "https://afgxvhhubqzgpijcstsv.supabase.co") {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const publishableKey = Deno.env.get("SUPABASE_ANON_KEY") ??
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!publishableKey) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const boundedFetch: typeof fetch = (input, init) => {
    const timeout = AbortSignal.timeout(8000);
    return fetch(input, {
      ...init,
      signal: init?.signal ? AbortSignal.any([init.signal, timeout]) : timeout,
    });
  };
  return {
    database: new PostgRESTDatabase(environment, boundedFetch),
    authenticate: (request) =>
      authenticate(request, {
        supabaseURL: environment.supabaseURL,
        publishableKey,
      }, boundedFetch),
    now: () => new Date(),
    fetcher: boundedFetch,
    supabaseURL: environment.supabaseURL,
    serviceRoleKey: environment.serviceRoleKey,
    publishableKey,
  };
}
