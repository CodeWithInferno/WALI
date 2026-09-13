import { EdgeError } from "./errors.ts";
import { buildSignedPublication, unpaddedBase64URL } from "./manifest.ts";
import { isObject } from "./validation.ts";
export type PublicationSignature = {
  manifest_body: string;
  metadata_body: string;
  manifest_digest: string;
  metadata_digest: string;
  manifest_signature: string;
  signing_key_id: string;
};
export async function signPublication(
  prepared: unknown,
): Promise<PublicationSignature> {
  const keyID = Deno.env.get("WALI_CATALOG_SIGNING_KEY_ID");
  const privateKey = Deno.env.get("WALI_CATALOG_SIGNING_PRIVATE_KEY_PKCS8");
  const host = Deno.env.get("WALI_APPROVED_CDN_HOST");
  if (!keyID || !privateKey || !host) {
    throw new EdgeError("signing_key_unavailable", 503, true);
  }
  const signed = await buildSignedPublication(
    prepared,
    keyID,
    privateKey,
    host,
  );
  return {
    manifest_body: unpaddedBase64URL(signed.manifestBody),
    metadata_body: unpaddedBase64URL(signed.metadataBody),
    manifest_digest: signed.manifestDigest,
    metadata_digest: signed.metadataDigest,
    manifest_signature: unpaddedBase64URL(signed.signature),
    signing_key_id: keyID,
  };
}
export function validPublicationResponse(
  value: unknown,
): value is Record<string, unknown> {
  const uuid =
    /^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
  return isObject(value) && typeof value.wallpaper_id === "string" &&
    uuid.test(value.wallpaper_id) &&
    typeof value.release_id === "string" && uuid.test(value.release_id) &&
    Number.isSafeInteger(value.edition) && Number(value.edition) > 0 &&
    Number.isSafeInteger(value.wallpaper_revision) &&
    Number(value.wallpaper_revision) > 0 &&
    typeof value.manifest_digest === "string" &&
    /^[a-f0-9]{64}$/.test(value.manifest_digest) &&
    typeof value.key_id === "string" &&
    /^[A-Za-z0-9_-]{1,96}$/.test(value.key_id) &&
    typeof value.published_at === "string" &&
    Number.isFinite(Date.parse(value.published_at));
}
