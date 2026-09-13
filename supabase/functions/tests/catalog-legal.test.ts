import { handleCatalogLegal } from "../catalog-legal/index.ts";
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
const url =
  "https://example.supabase.co/functions/v1/catalog-legal/wallpaper-use-license/2026-09-12";
Deno.test("effective license is readable without a bearer and version-bound", async () => {
  const response = handleCatalogLegal(new Request(url));
  assert(
    response.status === 200,
    "The effective license must be publicly readable",
  );
  assert(
    (await response.text()).includes("WALI Wallpaper Use License"),
    "Serve the reviewed title",
  );
  assert(
    response.headers.get("x-content-type-options") === "nosniff",
    "Do not sniff markdown as executable content",
  );
  assert(
    handleCatalogLegal(new Request(url.replace("2026-09-12", "2026-09-13")))
      .status === 404,
    "Unknown versions must not alias to current terms",
  );
});
Deno.test("legal delivery is read-only and supports exact cached copies", async () => {
  const first = handleCatalogLegal(new Request(url));
  const etag = first.headers.get("etag");
  assert(etag !== null, "Versioned document must expose its content digest");
  const cached = handleCatalogLegal(
    new Request(url, { headers: { "if-none-match": etag } }),
  );
  assert(
    cached.status === 304 && await cached.text() === "",
    "Exact cached copy returns304",
  );
  assert(
    handleCatalogLegal(new Request(url, { method: "POST", body: "change" }))
      .status === 405,
    "No writes allowed",
  );
  const head = handleCatalogLegal(new Request(url, { method: "HEAD" }));
  assert(
    head.status === 200 && await head.text() === "",
    "HEAD exposes metadata only",
  );
});
