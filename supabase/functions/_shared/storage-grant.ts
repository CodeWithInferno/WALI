import { EdgeError } from "./errors.ts";

/** Storage returns paths relative to /storage/v1, including a leading slash. */
export function normalizeStorageGrant(
  raw: string,
  supabaseURL: string,
  bucket: string,
  objectPath: string,
): string {
  let signed: URL;
  try {
    const path = raw.startsWith("/object/sign/") ? `/storage/v1${raw}` : raw;
    signed = new URL(path, supabaseURL);
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const expectedPath = `/storage/v1/object/sign/${bucket}/${
    objectPath.split("/").map(encodeURIComponent).join("/")
  }`;
  const query = [...signed.searchParams.entries()];
  if (
    signed.origin !== new URL(supabaseURL).origin || signed.username ||
    signed.password || signed.hash || signed.href.length > 4_096 ||
    signed.pathname !== expectedPath || query.length !== 1 ||
    query[0][0] !== "token" || !/^[A-Za-z0-9._~-]{1,3500}$/.test(query[0][1])
  ) throw new EdgeError("temporarily_unavailable", 503, true);
  return signed.href;
}
