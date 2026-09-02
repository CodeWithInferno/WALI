import {
  type AuthContext,
  authenticate,
  type AuthEnvironment,
} from "./auth.ts";
import {
  databaseEnvironment,
  type DatabaseGateway,
  PostgRESTDatabase,
} from "./database.ts";
import { EdgeError, failure } from "./errors.ts";

export const UNKNOWN_REQUEST_ID = "00000000-0000-4000-8000-000000000000";

export type EndpointDependencies = {
  database: DatabaseGateway;
  authenticate: (request: Request) => Promise<AuthContext>;
  now: () => Date;
  fetcher: typeof fetch;
  supabaseURL: string;
  publishableKey: string;
  serviceRoleKey: string;
};

export function productionDependencies(): EndpointDependencies {
  const databaseConfig = databaseEnvironment();
  const publishableKey = Deno.env.get("SUPABASE_ANON_KEY") ??
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!publishableKey) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const authEnvironment: AuthEnvironment = {
    supabaseURL: databaseConfig.supabaseURL,
    publishableKey,
  };
  return {
    database: new PostgRESTDatabase(databaseConfig),
    authenticate: (request) => authenticate(request, authEnvironment),
    now: () => new Date(),
    fetcher: fetch,
    supabaseURL: databaseConfig.supabaseURL,
    publishableKey,
    serviceRoleKey: databaseConfig.serviceRoleKey,
  };
}

export function safeFailure(
  apiVersion: string,
  requestID: string,
  error: unknown,
): Response {
  const safe = error instanceof EdgeError
    ? error
    : new EdgeError("temporarily_unavailable", 503, true);
  return failure(apiVersion, requestID, safe);
}
