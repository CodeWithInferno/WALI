import { EdgeError, mapDatabaseError } from "./errors.ts";

export type DatabaseEnvironment = {
  supabaseURL: string;
  serviceRoleKey: string;
};

export interface DatabaseGateway {
  rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T>;
}

export class PostgRESTDatabase implements DatabaseGateway {
  constructor(
    private readonly environment: DatabaseEnvironment,
    private readonly fetcher: typeof fetch = fetch,
  ) {}

  async rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T> {
    if (!/^[a-z][a-z0-9_]{2,95}$/.test(name)) {
      throw new EdgeError("invalid_request", 400);
    }
    const endpoint = new URL(
      `/rest/v1/rpc/${name}`,
      this.environment.supabaseURL,
    );
    let response: Response;
    try {
      response = await this.fetcher(endpoint, {
        method: "POST",
        headers: {
          apikey: this.environment.serviceRoleKey,
          authorization: `Bearer ${this.environment.serviceRoleKey}`,
          "content-type": "application/json",
          accept: "application/json",
        },
        body: JSON.stringify(parameters),
        redirect: "error",
      });
    } catch {
      throw new EdgeError("temporarily_unavailable", 503, true);
    }
    if (!response.ok) {
      const error = await response.json().catch(() => null) as {
        message?: unknown;
      } | null;
      throw mapDatabaseError(
        typeof error?.message === "string" ? error.message : "",
      );
    }
    return await response.json() as T;
  }
}

export function databaseEnvironment(): DatabaseEnvironment {
  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseURL || !serviceRoleKey) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  let parsed: URL;
  try {
    parsed = new URL(supabaseURL);
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const isLocalHTTP = parsed.protocol === "http:" &&
    (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost");
  if (
    (parsed.protocol !== "https:" && !isLocalHTTP) || parsed.username ||
    parsed.password || parsed.search || parsed.hash || parsed.pathname !== "/"
  ) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  return { supabaseURL: parsed.origin, serviceRoleKey };
}
