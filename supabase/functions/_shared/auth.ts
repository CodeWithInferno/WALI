import { EdgeError } from "./errors.ts";

export type AuthContext = {
  actorID: string;
  assuranceLevel: "aal1" | "aal2";
  accessToken: string;
  expiresAt: number;
  authenticatedAt?: number;
};

export type AuthEnvironment = {
  supabaseURL: string;
  publishableKey: string;
};

export async function authenticate(
  request: Request,
  environment: AuthEnvironment,
  fetcher: typeof fetch = fetch,
): Promise<AuthContext> {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ") || authorization.length > 8192) {
    throw new EdgeError("authentication_required", 401);
  }
  const accessToken = authorization.slice(7);
  if (!/^[A-Za-z0-9._-]+$/.test(accessToken)) {
    throw new EdgeError("authentication_required", 401);
  }
  let response: Response;
  try {
    response = await fetcher(
      new URL("/auth/v1/user", environment.supabaseURL),
      {
        method: "GET",
        headers: { authorization, apikey: environment.publishableKey },
        redirect: "error",
      },
    );
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  if (response.status === 401 || response.status === 403) {
    throw new EdgeError("authentication_required", 401);
  }
  if (!response.ok) throw new EdgeError("temporarily_unavailable", 503, true);
  const user = await response.json().catch(() => null) as
    | { id?: unknown }
    | null;
  const claims = verifiedClaims(accessToken);
  if (!user || typeof user.id !== "string" || user.id !== claims.sub) {
    throw new EdgeError("authentication_required", 401);
  }
  const now = Math.floor(Date.now() / 1000);
  if (!Number.isSafeInteger(claims.exp) || claims.exp <= now) {
    throw new EdgeError("authentication_required", 401);
  }
  return {
    actorID: user.id,
    assuranceLevel: claims.aal === "aal2" ? "aal2" : "aal1",
    accessToken,
    expiresAt: claims.exp,
    authenticatedAt: latestAuthenticationTime(claims.authTime, claims.amr),
  };
}

function verifiedClaims(
  token: string,
): {
  sub: string;
  exp: number;
  aal: unknown;
  authTime: number | undefined;
  amr: unknown;
} {
  const pieces = token.split(".");
  if (pieces.length !== 3) throw new EdgeError("authentication_required", 401);
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder().decode(decodeBase64URL(pieces[1])));
  } catch {
    throw new EdgeError("authentication_required", 401);
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new EdgeError("authentication_required", 401);
  }
  const claims = value as Record<string, unknown>;
  if (typeof claims.sub !== "string" || typeof claims.exp !== "number") {
    throw new EdgeError("authentication_required", 401);
  }
  return {
    sub: claims.sub,
    exp: claims.exp,
    aal: claims.aal,
    authTime: typeof claims.auth_time === "number"
      ? claims.auth_time
      : undefined,
    amr: claims.amr,
  };
}

function latestAuthenticationTime(
  authTime: number | undefined,
  rawAMR: unknown,
): number | undefined {
  const candidates: number[] = [];
  if (Number.isSafeInteger(authTime) && (authTime as number) > 0) {
    candidates.push(authTime as number);
  }
  if (Array.isArray(rawAMR) && rawAMR.length <= 16) {
    for (const entry of rawAMR) {
      if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
        continue;
      }
      const value = entry as Record<string, unknown>;
      if (
        ["totp", "mfa", "webauthn"].includes(String(value.method)) &&
        Number.isSafeInteger(value.timestamp) && (value.timestamp as number) > 0
      ) candidates.push(value.timestamp as number);
    }
  }
  return candidates.length === 0 ? undefined : Math.max(...candidates);
}

function decodeBase64URL(value: string): Uint8Array {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/") +
    "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(base64);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
