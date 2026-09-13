import { EdgeError } from "./errors.ts";
import { isObject } from "./validation.ts";

const ARTIFACT_ROLES = [
  "thumbnail",
  "poster",
  "preview",
  "video_default",
  "video_1080p",
  "video_1440p",
  "video_2160p",
  "image_default",
] as const;

export type PreparedPublication = {
  media_kind?: "still";
  wallpaper_id: string;
  release_id: string;
  edition: number;
  issued_at: string;
  key_id: string;
  public_key: string;
  title: string;
  creator: { id: string; handle: string; display_name: string };
  rights_holder: string;
  attribution: { text: string; source_url: string; license_code: string };
  artifacts: Array<{
    role: typeof ARTIFACT_ROLES[number];
    url: string;
    sha256: string;
    byte_count: number;
    media_type: string;
    width: number;
    height: number;
    duration_ms: number;
  }>;
};

export async function buildSignedPublication(
  preparedValue: unknown,
  expectedKeyID: string,
  privateKeyPKCS8: string,
  approvedCDNHost: string,
): Promise<
  {
    manifestBody: Uint8Array;
    metadataBody: Uint8Array;
    manifestDigest: string;
    metadataDigest: string;
    signature: Uint8Array;
  }
> {
  const prepared = parsePrepared(preparedValue, approvedCDNHost);
  if (prepared.key_id !== expectedKeyID) {
    throw new EdgeError("signing_key_unavailable", 503, true);
  }
  const metadata = {
    schema: "wali.catalog.install-metadata.v1",
    wallpaper_id: prepared.wallpaper_id,
    release_id: prepared.release_id,
    edition: prepared.edition,
    title: prepared.title,
    creator_name: prepared.creator.display_name,
    creator_handle: prepared.creator.handle,
    attribution_text: prepared.attribution.text,
    rights_holder: prepared.rights_holder,
  };
  const metadataBody = new TextEncoder().encode(orderedMetadataJSON(metadata));
  const metadataDigest = await sha256Hex(metadataBody);
  const manifest = {
    schema: { epoch: prepared.media_kind === "still" ? 2 : 1, revision: 0 },
    ...(prepared.media_kind === "still"
      ? { media_kind: "still" as const }
      : {}),
    key_id: prepared.key_id,
    wallpaper_id: prepared.wallpaper_id,
    release_id: prepared.release_id,
    edition: prepared.edition,
    issued_at: prepared.issued_at,
    artifacts: [...prepared.artifacts].sort((left, right) =>
      ARTIFACT_ROLES.indexOf(left.role) - ARTIFACT_ROLES.indexOf(right.role)
    ),
    metadata_digest: metadataDigest,
  };
  const manifestBody = new TextEncoder().encode(orderedManifestJSON(manifest));
  if (manifestBody.length > 65_536 || metadataBody.length > 16_384) {
    throw new EdgeError("artifact_set_invalid", 409);
  }
  const manifestDigest = await sha256Hex(manifestBody);
  const key = await importEd25519PrivateKey(privateKeyPKCS8);
  const signature = new Uint8Array(
    await crypto.subtle.sign("Ed25519", key, ownedArrayBuffer(manifestBody)),
  );
  if (signature.length !== 64) {
    throw new EdgeError("manifest_signing_failed", 503, true);
  }
  const publicKeyBytes = decodeBase64URL(prepared.public_key);
  if (publicKeyBytes.length !== 32) {
    throw new EdgeError("signing_key_unavailable", 503, true);
  }
  const publicKey = await crypto.subtle.importKey(
    "raw",
    ownedArrayBuffer(publicKeyBytes),
    { name: "Ed25519" },
    false,
    ["verify"],
  )
    .catch(() => {
      throw new EdgeError("signing_key_unavailable", 503, true);
    });
  if (
    !await crypto.subtle.verify(
      "Ed25519",
      publicKey,
      ownedArrayBuffer(signature),
      ownedArrayBuffer(manifestBody),
    )
  ) {
    throw new EdgeError("signing_key_unavailable", 503, true);
  }
  return {
    manifestBody,
    metadataBody,
    manifestDigest,
    metadataDigest,
    signature,
  };
}

export function unpaddedBase64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll(
    "=",
    "",
  );
}

export async function signCanonicalDocument(
  body: Uint8Array,
  expectedKeyID: string,
  preparedKeyID: string,
  privateKeyPKCS8: string,
  publicKeyBase64URL: string,
): Promise<{ digest: string; signature: Uint8Array }> {
  if (
    expectedKeyID !== preparedKeyID || body.length < 2 ||
    body.length > 1_048_576 || !/^[A-Za-z0-9_-]{43}$/.test(publicKeyBase64URL)
  ) throw new EdgeError("signing_key_unavailable", 503, true);
  const key = await importEd25519PrivateKey(privateKeyPKCS8);
  const signature = new Uint8Array(
    await crypto.subtle.sign("Ed25519", key, ownedArrayBuffer(body)),
  );
  const publicKey = await crypto.subtle.importKey(
    "raw",
    ownedArrayBuffer(decodeBase64URL(publicKeyBase64URL)),
    { name: "Ed25519" },
    false,
    ["verify"],
  ).catch(() => {
    throw new EdgeError("signing_key_unavailable", 503, true);
  });
  if (
    signature.length !== 64 ||
    !await crypto.subtle.verify(
      "Ed25519",
      publicKey,
      ownedArrayBuffer(signature),
      ownedArrayBuffer(body),
    )
  ) throw new EdgeError("signing_key_unavailable", 503, true);
  return { digest: await sha256Hex(body), signature };
}

async function importEd25519PrivateKey(value: string): Promise<CryptoKey> {
  if (!/^[A-Za-z0-9_-]+$/.test(value) || value.length > 512) {
    throw new EdgeError("signing_key_unavailable", 503, true);
  }
  try {
    const raw = decodeBase64URL(value);
    return await crypto.subtle.importKey(
      "pkcs8",
      ownedArrayBuffer(raw),
      { name: "Ed25519" },
      false,
      ["sign"],
    );
  } catch {
    throw new EdgeError("signing_key_unavailable", 503, true);
  }
}

function parsePrepared(
  value: unknown,
  approvedCDNHost: string,
): PreparedPublication {
  const still = isObject(value) && value.media_kind === "still";
  const required = still
    ? ["thumbnail", "poster", "image_default"]
    : ["thumbnail", "poster", "preview", "video_default"];
  if (
    !isObject(value) || !Array.isArray(value.artifacts) ||
    (still
      ? value.artifacts.length !== 3
      : value.artifacts.length < 4 || value.artifacts.length > 7) ||
    !isObject(value.creator) || !isObject(value.attribution) ||
    Object.keys(value).sort().join(",") !==
      (still
        ? "artifacts,attribution,creator,edition,issued_at,key_id,media_kind,public_key,release_id,rights_holder,title,wallpaper_id"
        : "artifacts,attribution,creator,edition,issued_at,key_id,public_key,release_id,rights_holder,title,wallpaper_id") ||
    Object.keys(value.creator).sort().join(",") !== "display_name,handle,id" ||
    Object.keys(value.attribution).sort().join(",") !==
      "license_code,source_url,text"
  ) {
    throw new EdgeError("artifact_set_invalid", 409);
  }
  const prepared = value as unknown as PreparedPublication;
  if (
    !uuid(prepared.wallpaper_id) || !uuid(prepared.release_id) ||
    !Number.isSafeInteger(prepared.edition) || prepared.edition < 1 ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$/.test(prepared.key_id) ||
    !/^[A-Za-z0-9_-]{43}$/.test(prepared.public_key) ||
    !rfc3339Seconds(prepared.issued_at) || !plain(prepared.title, 1, 120) ||
    !uuid(prepared.creator.id) ||
    !/^[a-z0-9][a-z0-9_]{2,31}$/.test(prepared.creator.handle) ||
    !plain(prepared.creator.display_name, 1, 80) ||
    !plain(prepared.rights_holder, 1, 160) ||
    !plain(prepared.attribution.text, 0, 1_000) ||
    !/^[A-Za-z0-9._-]{2,64}$/.test(prepared.attribution.license_code) ||
    (prepared.attribution.source_url !== "" &&
      !safeHTTPS(prepared.attribution.source_url))
  ) {
    throw new EdgeError("artifact_set_invalid", 409);
  }
  const roles = new Set<string>();
  for (const artifact of prepared.artifacts) {
    if (
      !isObject(artifact) ||
      Object.keys(artifact).sort().join(",") !==
        "byte_count,duration_ms,height,media_type,role,sha256,url,width" ||
      !ARTIFACT_ROLES.includes(artifact.role) || roles.has(artifact.role) ||
      (still
        ? !required.includes(artifact.role)
        : artifact.role === "image_default") ||
      !safeCDNURL(artifact.url, approvedCDNHost) ||
      !/^[0-9a-f]{64}$/.test(artifact.sha256) ||
      !Number.isSafeInteger(artifact.byte_count) || artifact.byte_count <= 0 ||
      artifact.byte_count >
        (still
          ? artifact.role === "image_default" ? 134_217_728 : 16_777_216
          : 2_147_483_648) ||
      !Number.isSafeInteger(artifact.width) || artifact.width < 1 ||
      artifact.width > 7_680 ||
      !Number.isSafeInteger(artifact.height) || artifact.height < 1 ||
      artifact.height > (still ? 7_680 : 4_320) ||
      (still && artifact.width * artifact.height > 33_177_600) ||
      !Number.isSafeInteger(artifact.duration_ms) || artifact.duration_ms < 0 ||
      artifact.duration_ms > 600_000 ||
      (still
        ? (artifact.duration_ms !== 0 ||
          (artifact.role === "image_default"
            ? artifact.media_type !== "image/png"
            : artifact.media_type !== "image/jpeg") ||
          (artifact.role === "thumbnail" &&
            (artifact.width !== 512 || artifact.height !== 512)) ||
          (artifact.role === "poster" &&
            (artifact.width > 1920 || artifact.height > 1920)))
        : ((artifact.role === "thumbnail" || artifact.role === "poster")
          ? (!(artifact.media_type === "image/jpeg" ||
            artifact.media_type === "image/png") || artifact.duration_ms !== 0)
          : (artifact.media_type !== "video/mp4" ||
            artifact.duration_ms === 0)))
    ) {
      throw new EdgeError("artifact_set_invalid", 409);
    }
    roles.add(artifact.role);
  }
  for (const role of required) {
    if (!roles.has(role)) throw new EdgeError("artifact_set_invalid", 409);
  }
  return prepared;
}

function orderedMetadataJSON(
  value: {
    schema: string;
    wallpaper_id: string;
    release_id: string;
    edition: number;
    title: string;
    creator_name: string;
    creator_handle: string;
    attribution_text: string;
    rights_holder: string;
  },
): string {
  return `{${
    [
      pair("schema", value.schema),
      pair("wallpaper_id", value.wallpaper_id),
      pair("release_id", value.release_id),
      pair("edition", value.edition),
      pair("title", value.title),
      pair("creator_name", value.creator_name),
      pair("creator_handle", value.creator_handle),
      pair("attribution_text", value.attribution_text),
      pair("rights_holder", value.rights_holder),
    ].join(",")
  }}`;
}

function orderedManifestJSON(value: {
  schema: { epoch: number; revision: number };
  media_kind?: "still";
  key_id: string;
  wallpaper_id: string;
  release_id: string;
  edition: number;
  issued_at: string;
  artifacts: PreparedPublication["artifacts"];
  metadata_digest: string;
}): string {
  const artifacts = value.artifacts.map((artifact) =>
    `{${
      [
        pair("role", artifact.role),
        pair("url", artifact.url),
        pair("sha256", artifact.sha256),
        pair("byte_count", artifact.byte_count),
        pair("media_type", artifact.media_type),
        pair("width", artifact.width),
        pair("height", artifact.height),
        pair("duration_ms", artifact.duration_ms),
      ].join(",")
    }}`
  ).join(",");
  return `{${
    [
      `"schema":{${pair("epoch", value.schema.epoch)},${
        pair("revision", value.schema.revision)
      }}`,
      ...(value.media_kind === "still" ? [pair("media_kind", "still")] : []),
      pair("key_id", value.key_id),
      pair("wallpaper_id", value.wallpaper_id),
      pair("release_id", value.release_id),
      pair("edition", value.edition),
      pair("issued_at", value.issued_at),
      `"artifacts":[${artifacts}]`,
      pair("metadata_digest", value.metadata_digest),
    ].join(",")
  }}`;
}

function pair(key: string, value: string | number): string {
  if (
    typeof value === "string" &&
    (value !== value.normalize("NFC") || hasControlCharacter(value))
  ) {
    throw new EdgeError("artifact_set_invalid", 409);
  }
  if (
    typeof value === "number" && (!Number.isSafeInteger(value) || value < 0)
  ) throw new EdgeError("artifact_set_invalid", 409);
  return `${JSON.stringify(key)}:${JSON.stringify(value)}`;
}

async function sha256Hex(value: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", ownedArrayBuffer(value));
  return [...new Uint8Array(digest)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

function ownedArrayBuffer(value: Uint8Array): ArrayBuffer {
  return Uint8Array.from(value).buffer;
}

function decodeBase64URL(value: string): Uint8Array {
  const binary = atob(
    value.replaceAll("-", "+").replaceAll("_", "/") +
      "=".repeat((4 - value.length % 4) % 4),
  );
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function uuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(value);
}

function plain(
  value: unknown,
  minimum: number,
  maximum: number,
): value is string {
  return typeof value === "string" && value === value.normalize("NFC") &&
    value.length >= minimum && value.length <= maximum &&
    !hasControlCharacter(value);
}

function rfc3339Seconds(value: unknown): value is string {
  return typeof value === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value) &&
    !Number.isNaN(Date.parse(value));
}

function safeHTTPS(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password &&
      !url.port && !url.search && !url.hash;
  } catch {
    return false;
  }
}

function safeCDNURL(value: unknown, approvedHost: string): boolean {
  if (typeof value !== "string" || !/^[a-z0-9.-]+$/.test(approvedHost)) {
    return false;
  }
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname === approvedHost &&
      !url.username && !url.password && !url.port && !url.search && !url.hash;
  } catch {
    return false;
  }
}

function hasControlCharacter(value: string): boolean {
  return [...value].some((character) => {
    const code = character.codePointAt(0) ?? 0;
    return code <= 0x1f || (code >= 0x7f && code <= 0x9f);
  });
}
