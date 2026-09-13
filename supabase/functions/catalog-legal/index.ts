import { catalogLegalDocuments } from "./documents.generated.ts";

/** Public immutable policy text only; no authentication, secrets or database. */
export function handleCatalogLegal(request: Request): Response {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", {
      status: 405,
      headers: { allow: "GET, HEAD" },
    });
  }
  const path = new URL(request.url).pathname;
  const match = path.match(
    /^(?:\/functions\/v1)?\/catalog-legal\/([a-z-]+\/[0-9]{4}-[0-9]{2}-[0-9]{2})$/,
  );
  const document = match ? catalogLegalDocuments[match[1]] : undefined;
  if (!document) {
    return new Response("Document version not found", { status: 404 });
  }
  const etag = `"${document.sha256}"`;
  const headers = {
    "content-type": "text/plain; charset=utf-8",
    "x-content-type-options": "nosniff",
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    "cache-control": "public, max-age=31536000, immutable",
    etag,
  };
  if (request.headers.get("if-none-match") === etag) {
    return new Response(null, { status: 304, headers });
  }
  return new Response(request.method === "HEAD" ? null : document.body, {
    status: 200,
    headers,
  });
}

if (import.meta.main) Deno.serve(handleCatalogLegal);
