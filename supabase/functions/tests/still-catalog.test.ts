import goldenStill from "../../../Fixtures/Catalog/manifest-still-v2.json" with {
  type: "json",
};
import { handleModerateSubmission } from "../moderate-submission/index.ts";
import {
  buildSignedPublication,
  unpaddedBase64URL,
} from "../_shared/manifest.ts";
import { handleCreateUpload } from "../create-upload/index.ts";
import { handleRequestInstall } from "../request-install/index.ts";
import type { EndpointDependencies } from "../_shared/runtime.ts";
import type { DatabaseGateway } from "../_shared/database.ts";
const ID = "70000000-0000-4000-8000-000000000001";
function assert(v: unknown, m = "assertion failed"): asserts v {
  if (!v) throw new Error(m);
}
function eq(a: unknown, b: unknown) {
  assert(
    JSON.stringify(a) === JSON.stringify(b),
    `${JSON.stringify(a)} != ${JSON.stringify(b)}`,
  );
}
async function fixture(still = true) {
  const key = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ]) as CryptoKeyPair;
  const prepared = {
    wallpaper_id: ID,
    release_id: ID,
    edition: 1,
    issued_at: "2026-09-13T00:00:00Z",
    key_id: "catalog-test",
    public_key: unpaddedBase64URL(
      new Uint8Array(await crypto.subtle.exportKey("raw", key.publicKey)),
    ),
    title: "A real image",
    creator: { id: ID, handle: "artist", display_name: "Artist" },
    rights_holder: "Artist",
    attribution: {
      text: "Artist",
      source_url: "https://example.test/artist",
      license_code: "licensed-v1",
    },
    ...(still ? { media_kind: "still" } : {}),
    artifacts:
      (still
        ? ["image_default", "poster", "thumbnail"]
        : ["video_default", "preview", "poster", "thumbnail"]).map((role) => ({
          role,
          url: `https://catalog.example/sha256/${"a".repeat(64)}/${role}`,
          sha256: "a".repeat(64),
          byte_count: 1234,
          media_type: role === "image_default"
            ? "image/png"
            : role === "poster" || role === "thumbnail"
            ? "image/jpeg"
            : "video/mp4",
          width: role === "thumbnail" ? 512 : 1920,
          height: role === "thumbnail" ? 512 : 1080,
          duration_ms: role.startsWith("video") || role === "preview"
            ? 1000
            : 0,
        })),
  };
  return {
    prepared,
    key,
    privateKey: unpaddedBase64URL(
      new Uint8Array(await crypto.subtle.exportKey("pkcs8", key.privateKey)),
    ),
  };
}
Deno.test("still manifest has exact epoch/kind/order and verified signature", async () => {
  const f = await fixture();
  const signed = await buildSignedPublication(
    f.prepared,
    "catalog-test",
    f.privateKey,
    "catalog.example",
  );
  const text = new TextDecoder().decode(signed.manifestBody),
    m = JSON.parse(text);
  eq(Object.keys(m), [
    "schema",
    "media_kind",
    "key_id",
    "wallpaper_id",
    "release_id",
    "edition",
    "issued_at",
    "artifacts",
    "metadata_digest",
  ]);
  eq(m.schema, { epoch: 2, revision: 0 });
  eq(m.media_kind, "still");
  eq(m.artifacts.map((a: { role: string }) => a.role), [
    "thumbnail",
    "poster",
    "image_default",
  ]);
  assert(
    await crypto.subtle.verify(
      "Ed25519",
      f.key.publicKey,
      signed.signature as BufferSource,
      signed.manifestBody as BufferSource,
    ),
  );
});
Deno.test("video manifest retains exact canonical field and role order", async () => {
  const f = await fixture(false);
  const signed = await buildSignedPublication(
    f.prepared,
    "catalog-test",
    f.privateKey,
    "catalog.example",
  );
  const m = JSON.parse(new TextDecoder().decode(signed.manifestBody));
  eq(m.schema, { epoch: 1, revision: 0 });
  assert(!("media_kind" in m));
  eq(Object.keys(m), [
    "schema",
    "key_id",
    "wallpaper_id",
    "release_id",
    "edition",
    "issued_at",
    "artifacts",
    "metadata_digest",
  ]);
  eq(m.artifacts.map((a: { role: string }) => a.role), [
    "thumbnail",
    "poster",
    "preview",
    "video_default",
  ]);
  const expected = JSON.stringify({
    schema: { epoch: 1, revision: 0 },
    key_id: "catalog-test",
    wallpaper_id: ID,
    release_id: ID,
    edition: 1,
    issued_at: f.prepared.issued_at,
    artifacts: [...f.prepared.artifacts].reverse(),
    metadata_digest: signed.metadataDigest,
  });
  eq(new TextDecoder().decode(signed.manifestBody), expected);
});
for (
  const mutation of [
    "video role",
    "missing kind",
    "wrong kind",
    "extra role",
    "excess bytes",
    "excess poster bytes",
    "excess thumbnail bytes",
    "excess pixels",
    "duration",
    "alpha MIME",
  ]
) {
  Deno.test(`still signer rejects ${mutation}`, async () => {
    const f = await fixture();
    const v: Record<string, unknown> = structuredClone(f.prepared);
    const a = v.artifacts as Array<Record<string, unknown>>;
    if (mutation === "video role") a[0].role = "video_default";
    if (mutation === "missing kind") delete v.media_kind;
    if (mutation === "wrong kind") v.media_kind = "video";
    if (mutation === "extra role") a.push(a[0]);
    if (mutation === "excess bytes") a[0].byte_count = 134217729;
    if (mutation === "excess poster bytes") a[1].byte_count = 16777217;
    if (mutation === "excess thumbnail bytes") a[2].byte_count = 16777217;
    if (mutation === "excess pixels") {
      a[0].width = 7680;
      a[0].height = 7680;
    }
    if (mutation === "duration") a[0].duration_ms = 1;
    if (mutation === "alpha MIME") a[0].media_type = "image/webp";
    let failed = false;
    try {
      await buildSignedPublication(
        v,
        "catalog-test",
        f.privateKey,
        "catalog.example",
      );
    } catch {
      failed = true;
    }
    assert(failed);
  });
}
class DB implements DatabaseGateway {
  calls: string[] = [];
  constructor(readonly result: unknown) {}
  rpc<T>(name: string, _: Record<string, unknown>): Promise<T> {
    this.calls.push(name);
    return Promise.resolve(
      (name === "wali_edge_take_rate_limit_v1"
        ? { allowed: true, retry_after_seconds: 0 }
        : this.result) as T,
    );
  }
}
function deps(database: DB): EndpointDependencies {
  return {
    database,
    authenticate: () =>
      Promise.resolve({
        actorID: ID,
        assuranceLevel: "aal1",
        accessToken: "synthetic",
        expiresAt: 2_000_000_000,
      }),
    now: () => new Date("2026-09-13T00:00:00Z"),
    fetcher: () => {
      throw new Error("unexpected network");
    },
    supabaseURL: "https://catalog.example",
    publishableKey: "synthetic",
    serviceRoleKey: "synthetic",
  };
}
function request(body: unknown) {
  return new Request("https://catalog.example/functions/v1/test", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}
for (const mime of ["image/jpeg", "image/png", "image/gif", "image/webp"]) {
  Deno.test(`Creator image admission ${mime}`, async () => {
    const db = new DB({
      upload_session_id: ID,
      storage_path: `${ID}/${ID}/source`,
      expires_at: "2026-09-14T00:00:00Z",
      revision: 1,
      upload_endpoint:
        "https://catalog.example/storage/v1/upload/resumable/existing",
    });
    const r = await handleCreateUpload(
      request({
        api_version: "creator.v1",
        request_id: ID,
        idempotency_key: "still_create_upload_01",
        declared_byte_count: 4096,
        container_hint: mime,
        original_filename: "source.png",
        target: { kind: "new" },
      }),
      deps(db),
    );
    eq(r.status, mime === "image/jpeg" || mime === "image/png" ? 201 : 400);
  });
}
Deno.test("Creator refuses image bytes above cap before DB/TUS", async () => {
  const db = new DB({});
  const r = await handleCreateUpload(
    request({
      api_version: "creator.v1",
      request_id: ID,
      idempotency_key: "still_create_upload_01",
      declared_byte_count: 134217729,
      container_hint: "image/png",
      original_filename: "source.png",
      target: { kind: "new" },
    }),
    deps(db),
  );
  eq(r.status, 400);
  eq(db.calls, []);
});
for (const kind of ["video", "still", null, "animated"]) {
  Deno.test(`V2 install validates kind ${kind}`, async () => {
    const db = new DB({
      wallpaper_id: ID,
      release_id: ID,
      manifest_body: "YWJj",
      metadata_body: "ZGVm",
      signature: "c2ln",
      key_id: "catalog-test",
      install_receipt: ID,
      expires_at: "2026-09-13T00:30:00Z",
      ...(kind === null ? {} : { media_kind: kind }),
    });
    const r = await handleRequestInstall(
      request({
        api_version: "catalog.v2",
        request_id: ID,
        idempotency_key: "still_request_install_01",
        wallpaper_id: ID,
        release_id: ID,
        expected_wallpaper_revision: 3,
      }),
      deps(db),
    );
    eq(r.status, kind === "video" || kind === "still" ? 200 : 503);
    assert(db.calls.includes("wali_edge_request_install_v2"));
    eq((await r.json()).api_version, "catalog.v2");
  });
}

for (const mixed of [false, true]) {
  Deno.test(`moderation still private preview ${mixed ? "rejects mixed video" : "signs poster and image"}`, async () => {
    const artifacts = [{
      role: "poster",
      media_type: "image/jpeg",
      width: 960,
      height: 1920,
      name: "poster.jpg",
    }, {
      role: mixed ? "video_default" : "image_default",
      media_type: mixed ? "video/mp4" : "image/png",
      width: 2160,
      height: 4320,
      name: mixed ? "video-default.mp4" : "image-default.png",
    }].map((a) => ({
      ...a,
      storage_path: `sha256/aa/aa/${"a".repeat(64)}/${a.name}`,
      sha256: "a".repeat(64),
      byte_count: 4096,
      duration_ms: 0,
    }));
    const db = new DB({
      items: [{
        submission_id: ID,
        media_facts: {
          media_kind: "still",
          container: "image/png",
          codec: "png",
          width: 2160,
          height: 4320,
        },
        canonical_artifacts: artifacts,
      }],
      next_cursor: null,
    });
    const d = deps(db);
    d.authenticate = () =>
      Promise.resolve({
        actorID: ID,
        assuranceLevel: "aal2",
        accessToken: "synthetic",
        expiresAt: 2_000_000_000,
      });
    d.fetcher = () =>
      Promise.resolve(
        Response.json(
          artifacts.map((a) => ({
            path: a.storage_path,
            signedURL:
              `/storage/v1/object/sign/processing-private/${a.storage_path}?token=synthetic`,
          })),
        ),
      );
    const r = await handleModerateSubmission(
      request({
        api_version: "moderation.v1",
        request_id: ID,
        idempotency_key: "still_moderation_queue_01",
        operation: "queue",
        status: "pending",
        sort: "oldest_submitted",
        cursor: null,
        limit: 24,
      }),
      d,
    );
    eq(r.status, mixed ? 503 : 200);
    if (!mixed) {
      const b = await r.json();
      eq(b.data.items[0].canonical_artifacts.length, 2);
      assert(!("storage_path" in b.data.items[0].canonical_artifacts[1]));
    }
  });
}

Deno.test("Edge and Swift share the canonical still golden manifest", async () => {
  const seed =
    "302e020100300506032b6570042204209d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
  const privateKey = unpaddedBase64URL(
    Uint8Array.from(seed.match(/../g)!, (v) => parseInt(v, 16)),
  );
  const pub =
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
  const pubBytes = Uint8Array.from(pub.match(/../g)!, (v) => parseInt(v, 16));
  const pk = await crypto.subtle.importKey(
    "raw",
    pubBytes,
    { name: "Ed25519" },
    false,
    ["verify"],
  );
  const signature =
    "qM1AAbKDRXmuDADj5aX8LxdKNjiy2DeYvbalZWvQyd7jkbyEc8AO22GqIlGIFHeT4jg4hg5bAk_ARLkiyhC3Cg";
  const sigBytes = Uint8Array.from(
    atob(signature.replaceAll("-", "+").replaceAll("_", "/") + "=="),
    (c) => c.charCodeAt(0),
  );
  assert(
    await crypto.subtle.verify(
      "Ed25519",
      pk,
      sigBytes,
      new TextEncoder().encode(JSON.stringify(goldenStill)),
    ),
  );
  const prepared = {
    ...goldenStill,
    public_key: unpaddedBase64URL(pubBytes),
    title: "Golden still",
    creator: { id: ID, handle: "artist", display_name: "Artist" },
    rights_holder: "Artist",
    attribution: {
      text: "Artist",
      source_url: "https://example.test/artist",
      license_code: "licensed-v1",
    },
  };
  const { schema: _, metadata_digest: __, ...input } = prepared;
  const signed = await buildSignedPublication(
    input,
    goldenStill.key_id,
    privateKey,
    "catalog.wali.example",
  );
  eq(
    new TextDecoder().decode(signed.manifestBody),
    JSON.stringify({ ...goldenStill, metadata_digest: signed.metadataDigest }),
  );
});
