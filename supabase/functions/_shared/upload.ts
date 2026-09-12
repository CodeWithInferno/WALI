import { EdgeError } from "./errors.ts";
import type { EndpointDependencies } from "./runtime.ts";

export async function createTUSResource(
  dependencies: EndpointDependencies,
  accessToken: string,
  path: string,
  byteCount: number,
  container: string,
): Promise<string> {
  const endpoint = new URL(
    "/storage/v1/upload/resumable",
    dependencies.supabaseURL,
  );
  const metadata = [
    ["bucketName", "uploads-private"],
    ["objectName", path],
    ["contentType", container],
    ["cacheControl", "no-cache"],
  ].map(([key, value]) => `${key} ${btoa(value)}`).join(",");
  let response: Response;
  try {
    response = await dependencies.fetcher(endpoint, {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        apikey: dependencies.publishableKey,
        "Tus-Resumable": "1.0.0",
        "Upload-Length": String(byteCount),
        "Upload-Metadata": metadata,
        "x-upsert": "false",
      },
      redirect: "error",
    });
  } catch {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const location = response.headers.get("location");
  if (response.status !== 201 || !location) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  const resolved = new URL(location, endpoint);
  if (
    resolved.origin !== endpoint.origin ||
    resolved.protocol !== endpoint.protocol || resolved.username ||
    resolved.password
  ) {
    throw new EdgeError("temporarily_unavailable", 503, true);
  }
  return resolved.href;
}
