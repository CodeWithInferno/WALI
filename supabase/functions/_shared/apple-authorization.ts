import { EdgeError } from "./errors.ts";
import { isObject, requireUUID } from "./validation.ts";

const APPLE_ORIGIN = "https://appleid.apple.com";
const TEAM_ID = "UH5Z2K4G9H";
export const APPLE_CLIENT_IDS = [
  "com.wali.store.WALI",
  "com.wali.store.development.WALI",
] as const;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export type AppleAuthorizationConfiguration = {
  clientID: string;
  keyID: string;
  privateKeyP8: string;
  encryptionKeyVersion: string;
  encryptionKey: Uint8Array;
};
export type AppleAuthorizationBinding = {
  actorID: string;
  clientID: string;
  appleSubject: string;
  encryptedRefreshToken: string;
  keyVersion: string;
};
export function appleAuthorizationConfigurationFromEnvironment(
  clientID: string,
): AppleAuthorizationConfiguration {
  requireAppleClientID(clientID);
  try {
    const prefix = clientID === "com.wali.store.WALI"
      ? "WALI_APPLE_STORE"
      : "WALI_APPLE_DEVELOPMENT";
    const config = {
      clientID,
      keyID: Deno.env.get(`${prefix}_KEY_ID`) ?? "",
      privateKeyP8: Deno.env.get(`${prefix}_PRIVATE_KEY_P8`) ?? "",
      encryptionKeyVersion: Deno.env.get("WALI_APPLE_CREDENTIAL_KEY_VERSION") ??
        "",
      encryptionKey: decodeBase64(
        Deno.env.get("WALI_APPLE_CREDENTIAL_KEY_BASE64") ?? "",
      ),
    };
    validateConfiguration(config);
    return config;
  } catch {
    throw unavailable();
  }
}
export function requireAppleClientID(value: unknown): string {
  if (
    typeof value !== "string" ||
    !(APPLE_CLIENT_IDS as readonly string[]).includes(value)
  ) {
    throw new EdgeError("invalid_request", 400);
  }
  return value;
}
export async function appleSHA256(value: string): Promise<string> {
  return [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(value)),
    ),
  ].map((v) => v.toString(16).padStart(2, "0")).join("");
}

/** Only fixed Apple keys and an exact native audience can authorize code custody. */
export async function verifyAppleIdentityToken(
  token: string,
  clientID: string,
  rawNonce: string,
  fetcher: typeof fetch = fetch,
  now: Date = new Date(),
): Promise<{ subject: string }> {
  requireAppleClientID(clientID);
  if (
    typeof token !== "string" || token.length > 16384 || rawNonce.length < 16 ||
    rawNonce.length > 256
  ) throw invalidIdentity();
  try {
    const parts = token.split(".");
    if (parts.length !== 3) throw invalidIdentity();
    const header: unknown = JSON.parse(decoder.decode(decodeURL(parts[0])));
    const claims: unknown = JSON.parse(decoder.decode(decodeURL(parts[1])));
    if (
      !isObject(header) || header.alg !== "RS256" ||
      typeof header.kid !== "string" || header.kid.length > 128 ||
      header.crit !== undefined || !isObject(claims)
    ) throw invalidIdentity();
    const seconds = Math.floor(now.getTime() / 1000);
    if (
      claims.iss !== APPLE_ORIGIN || claims.aud !== clientID ||
      !validSubject(claims.sub) ||
      claims.nonce !== await appleSHA256(rawNonce) ||
      !Number.isSafeInteger(claims.exp) || !Number.isSafeInteger(claims.iat) ||
      (claims.exp as number) <= seconds ||
      (claims.iat as number) > seconds + 30 ||
      (claims.iat as number) < seconds - 600 ||
      (claims.exp as number) <= (claims.iat as number)
    ) throw invalidIdentity();
    const { body, status } = await providerRequest(
      "/auth/keys",
      undefined,
      fetcher,
      32768,
    );
    const document: unknown = JSON.parse(body);
    if (
      status !== 200 || !isObject(document) || !Array.isArray(document.keys) ||
      document.keys.length < 1 || document.keys.length > 10
    ) throw unavailable();
    const matches = document.keys.filter((key) =>
      isObject(key) && key.kid === header.kid && key.kty === "RSA" &&
      key.alg === "RS256" && key.use === "sig"
    );
    if (matches.length !== 1) throw invalidIdentity();
    const key = await crypto.subtle.importKey(
      "jwk",
      matches[0] as JsonWebKey,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    if (
      !await crypto.subtle.verify(
        "RSASSA-PKCS1-v1_5",
        key,
        decodeURL(parts[2]),
        encoder.encode(`${parts[0]}.${parts[1]}`),
      )
    ) throw invalidIdentity();
    return { subject: claims.sub as string };
  } catch (error) {
    if (error instanceof EdgeError) throw error;
    throw invalidIdentity();
  }
}

export async function exchangeAppleAuthorization(
  input: {
    actorID: string;
    clientID: string;
    appleSubject: string;
    authorizationCode: string;
    nonce: string;
  },
  config: AppleAuthorizationConfiguration,
  fetcher: typeof fetch = fetch,
  now: Date = new Date(),
): Promise<AppleAuthorizationBinding> {
  validateBindingIdentity(input);
  validateConfiguration(config);
  if (config.clientID !== input.clientID) throw unavailable();
  if (!validCredential(input.authorizationCode, 4096)) {
    throw new EdgeError("invalid_request", 400);
  }
  const form = new URLSearchParams({
    client_id: input.clientID,
    client_secret: await clientSecret(input.clientID, config, now),
    code: input.authorizationCode,
    grant_type: "authorization_code",
  });
  // Native requests have no redirect URI. Never introduce a web callback here.
  const response = await providerRequest("/auth/token", form, fetcher, 32768);
  let body: unknown;
  try {
    body = JSON.parse(response.body);
  } catch {
    throw unavailable();
  }
  if (
    response.status !== 200 || !isObject(body) ||
    !validCredential(body.refresh_token, 8192) ||
    typeof body.id_token !== "string" || typeof body.token_type !== "string" ||
    body.token_type.toLowerCase() !== "bearer"
  ) throw unavailable();
  const refreshToken = body.refresh_token as string;
  try {
    const identity = await verifyAppleIdentityToken(
      body.id_token,
      input.clientID,
      input.nonce,
      fetcher,
      now,
    );
    if (identity.subject !== input.appleSubject) throw invalidIdentity();
    const binding = {
      actorID: input.actorID,
      clientID: input.clientID,
      appleSubject: input.appleSubject,
      keyVersion: config.encryptionKeyVersion,
    };
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const encrypted = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: aad(binding), tagLength: 128 },
      await encryptionKey(config),
      encoder.encode(refreshToken),
    );
    return {
      ...binding,
      encryptedRefreshToken: `v1.${encodeURL(iv)}.${
        encodeURL(new Uint8Array(encrypted))
      }`,
    };
  } catch (error) {
    // If a response cannot be safely retained, attempt to revoke the newly acquired credential.
    await revokeToken(refreshToken, input.clientID, config, fetcher).catch(
      () => {},
    );
    throw error instanceof EdgeError ? error : unavailable();
  }
}

export async function revokeAppleAuthorization(
  binding: AppleAuthorizationBinding,
  config: AppleAuthorizationConfiguration,
  fetcher: typeof fetch = fetch,
): Promise<void> {
  validateBindingIdentity(binding);
  validateConfiguration(config);
  if (
    binding.clientID !== config.clientID ||
    binding.keyVersion !== config.encryptionKeyVersion ||
    binding.encryptedRefreshToken.length > 12000
  ) throw unavailable();
  let token: string;
  try {
    const parts = binding.encryptedRefreshToken.split(".");
    if (parts.length !== 3 || parts[0] !== "v1") throw unavailable();
    const iv = decodeURL(parts[1]);
    if (iv.length !== 12) throw unavailable();
    token = decoder.decode(
      await crypto.subtle.decrypt(
        { name: "AES-GCM", iv, additionalData: aad(binding), tagLength: 128 },
        await encryptionKey(config),
        decodeURL(parts[2]),
      ),
    );
    if (!validCredential(token, 8192)) throw unavailable();
  } catch {
    throw unavailable();
  }
  await revokeToken(token, binding.clientID, config, fetcher);
}
async function revokeToken(
  token: string,
  clientID: string,
  config: AppleAuthorizationConfiguration,
  fetcher: typeof fetch,
): Promise<void> {
  const form = new URLSearchParams({
    client_id: clientID,
    client_secret: await clientSecret(clientID, config, new Date()),
    token,
    token_type_hint: "refresh_token",
  });
  const response = await providerRequest("/auth/revoke", form, fetcher, 16384);
  // Apple returns the same empty 200 for a previously revoked token, permitting safe replay.
  if (response.status !== 200 || response.body.trim() !== "") {
    throw unavailable();
  }
}
async function clientSecret(
  clientID: string,
  config: AppleAuthorizationConfiguration,
  now: Date,
): Promise<string> {
  requireAppleClientID(clientID);
  if (clientID !== config.clientID) throw unavailable();
  const seconds = Math.floor(now.getTime() / 1000);
  try {
    const pem = config.privateKeyP8.trim();
    const base64 = pem.replace(/^-----BEGIN PRIVATE KEY-----\s*/, "").replace(
      /\s*-----END PRIVATE KEY-----$/,
      "",
    ).replaceAll(/\s/g, "");
    const key = await crypto.subtle.importKey(
      "pkcs8",
      decodeBase64(base64),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
    const header = encodeURL(
      encoder.encode(
        JSON.stringify({ alg: "ES256", kid: config.keyID, typ: "JWT" }),
      ),
    );
    const payload = encodeURL(
      encoder.encode(
        JSON.stringify({
          iss: TEAM_ID,
          iat: seconds,
          exp: seconds + 300,
          aud: APPLE_ORIGIN,
          sub: clientID,
        }),
      ),
    );
    const input = `${header}.${payload}`;
    return `${input}.${
      encodeURL(
        new Uint8Array(
          await crypto.subtle.sign(
            { name: "ECDSA", hash: "SHA-256" },
            key,
            encoder.encode(input),
          ),
        ),
      )
    }`;
  } catch {
    throw unavailable();
  }
}
async function providerRequest(
  path: "/auth/keys" | "/auth/token" | "/auth/revoke",
  form: URLSearchParams | undefined,
  fetcher: typeof fetch,
  maximumBytes: number,
): Promise<{ status: number; body: string }> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  try {
    const response = await fetcher(`${APPLE_ORIGIN}${path}`, {
      method: form ? "POST" : "GET",
      redirect: "error",
      signal: controller.signal,
      headers: form
        ? {
          "content-type": "application/x-www-form-urlencoded",
          "accept": "application/json",
        }
        : { "accept": "application/json" },
      body: form?.toString(),
    });
    if (response.status >= 300 && response.status < 400) throw unavailable();
    if (Number(response.headers.get("content-length") ?? 0) > maximumBytes) {
      throw unavailable();
    }
    reader = response.body?.getReader();
    const chunks: Uint8Array[] = [];
    let length = 0;
    if (reader) {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        length += next.value.length;
        if (length > maximumBytes) throw unavailable();
        chunks.push(next.value);
      }
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return { status: response.status, body: decoder.decode(bytes) };
  } catch {
    throw unavailable();
  } finally {
    clearTimeout(timeout);
    await reader?.cancel().catch(() => {});
    reader?.releaseLock();
  }
}
function validateConfiguration(config: AppleAuthorizationConfiguration): void {
  requireAppleClientID(config.clientID);
  if (
    !/^[A-Z0-9]{10}$/.test(config.keyID) ||
    !/^[a-zA-Z0-9_-]{1,32}$/.test(config.encryptionKeyVersion) ||
    config.encryptionKey.length !== 32 || config.privateKeyP8.length > 4096 ||
    !config.privateKeyP8.trim().startsWith("-----BEGIN PRIVATE KEY-----")
  ) throw unavailable();
}
function validateBindingIdentity(
  binding: { actorID: string; clientID: string; appleSubject: string },
): void {
  requireUUID(binding.actorID);
  requireAppleClientID(binding.clientID);
  if (!validSubject(binding.appleSubject)) throw invalidIdentity();
}
function validSubject(value: unknown): boolean {
  return typeof value === "string" && /^[A-Za-z0-9._-]{1,256}$/.test(value);
}
function validCredential(value: unknown, limit: number): boolean {
  return typeof value === "string" && value.length > 0 &&
    value.length <= limit && /^[\x21-\x7e]+$/.test(value);
}
function aad(
  binding: {
    actorID: string;
    clientID: string;
    appleSubject: string;
    keyVersion: string;
  },
): Uint8Array<ArrayBuffer> {
  return encoder.encode(
    JSON.stringify([
      "wali.apple_authorization.v1",
      binding.actorID,
      binding.clientID,
      binding.appleSubject,
      binding.keyVersion,
    ]),
  );
}
function encryptionKey(
  config: AppleAuthorizationConfiguration,
): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    config.encryptionKey as Uint8Array<ArrayBuffer>,
    "AES-GCM",
    false,
    ["encrypt", "decrypt"],
  );
}
function encodeURL(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll(
    "/",
    "_",
  ).replaceAll("=", "");
}
function decodeURL(value: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw invalidIdentity();
  const decoded = decodeBase64(
    value.replaceAll("-", "+").replaceAll("_", "/") +
      "=".repeat((4 - value.length % 4) % 4),
  );
  if (encodeURL(decoded) !== value) throw invalidIdentity();
  return decoded;
}
function decodeBase64(value: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
}
function unavailable(): EdgeError {
  return new EdgeError("temporarily_unavailable", 503, true);
}
function invalidIdentity(): EdgeError {
  return new EdgeError("authentication_required", 401);
}
