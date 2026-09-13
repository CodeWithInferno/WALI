# Catalog V2

ADR 0027 adds real still wallpapers without changing published video manifest bytes. V2 reads retain the V1 envelopes, authentication, public eligibility, user rating preferences, bounded page sizes and durable public counts. Image upload admission stays disabled by default until the image worker, signer and native client are deployed and accepted together.

## Read surfaces

The public views are `catalog_wallpapers_v2` and `catalog_wallpaper_details_v2`; authenticated owner views are `my_saved_wallpapers_v2` and `my_favorites_v2`. Owner views retain `{wallpaper, revision, updated_at}`. Each wallpaper summary adds required `media_kind: "video" | "still"`. A poster is always present. A still summary has `preview: null`; no video preview is fabricated.

The RPCs retain their existing parameters:

| RPC | Parameters | Result |
| --- | --- | --- |
| `catalog_home_v2` | `locale`, `rating_ceiling` | `{sections}` with the existing bounded sections/items shape |
| `catalog_browse_v2` | `category`, `tags`, `sort`, `cursor`, `limit` | `{items, next_cursor}` |
| `catalog_search_v2` | `query`, `filters`, `cursor`, `limit` | `{items, next_cursor, ranking_explanation}` |
| `catalog_wallpaper_detail_v2` | `wallpaper_id` | Detail with typed `media` and V2 `related` summaries |

Detail retains the common wallpaper, description, edition, rights, attribution, source, license, viewer favorite/save and related fields. The old flat video dimensions/timing and `video_default` are replaced by exactly one media object:

```json
{"kind":"video","width":3840,"height":2160,"duration_ms":12000,"frame_rate_numerator":60,"frame_rate_denominator":1,"artifact":{"role":"video_default","url":"https://…","sha256":"…","byte_count":123,"media_type":"video/mp4","width":3840,"height":2160,"duration_ms":12000}}
```

```json
{"kind":"still","width":2160,"height":4320,"artifact":{"role":"image_default","url":"https://…","sha256":"…","byte_count":123,"media_type":"image/png","width":2160,"height":4320,"duration_ms":0}}
```

The common signed artifact record retains its existing zero duration for a raster artifact; the typed still media facts contain no duration or frame rate. Duration search filters exclude stills. Browse/search cursors bind the V2 contract and all effective filters/rating bounds; V1 cursors are rejected by V2 and vice versa.

V1 base summaries explicitly select video releases before pagination or aggregation. V1 Home, Browse, search, related, detail, Saved and Favorites therefore exclude stills. Ordinary verified-email creators remain publicly visible with an honest unverified badge when their private Creator profile is not publicly readable; no private profile fields or fabricated verification are exposed.

Native Home, Browse, search, detail and Saved readers try V2 first. Only PostgREST `PGRST202` (missing function) permits a read of the existing V1 RPC with identical parameters and the same captured authentication. Each new operation checks V2 again; no capability result is cached. Authorization, transport and malformed-response failures do not select a different contract. Legacy V1 video payloads are adapted into the current model only on that explicit path.

## Install and acknowledgements

`POST request-install` accepts the same exact fields: `api_version`, `request_id`, `idempotency_key`, `wallpaper_id`, `release_id`, `expected_wallpaper_revision`. `api_version: "catalog.v2"` selects the service-only `wali_edge_request_install_v2` RPC. The success envelope retains the requested API version and returns the existing signed manifest, install metadata, signature/key, receipt and expiry plus required `media_kind`.

The native install command chooses its contract from the selected release’s validated media kind before sending: video uses `catalog.v1`; still uses `catalog.v2`. The selection retains wallpaper, release and revision identity through retries. Install errors never trigger a mutation with another API version; the returned grant and signed manifest must match the selected kind.

V2 install uses a separate idempotency operation (`request_install_edge_v2`) so a V1 replay cannot erase the required kind. Replays retain the same receipt. Both versions recheck current public eligibility, actual actor rating preferences and release/revocation authority; V1 refuses image releases. `record-install` remains **catalog.v1** with its existing receipt/manifest binding and `verified_installed` result. It counts a completed still download once through the same durable anonymous aggregate and preserves existing ranking/self-install rules.

## Signed manifests

Video remains schema **1.0**, with identical canonical bytes and no media-kind member. Still uses schema **2.0** and required `media_kind: "still"`. Canonical top-level order is:

`schema, media_kind, key_id, wallpaper_id, release_id, edition, issued_at, artifacts, metadata_digest`.

The exact still artifact order is `thumbnail`, `poster`, `image_default`. Each artifact retains the ordered fields `role, url, sha256, byte_count, media_type, width, height, duration_ms`. There is no preview or video role. The canonical master is bounded opaque eight-bit sRGB PNG; poster and thumbnail are JPEG. The metadata document remains `wali.catalog.install-metadata.v1`. The existing Edge signer verifies its own Ed25519 signature against the active public key; no signer material moves to the media worker.

## Creator and worker compatibility

Ordinary `creator.v1` upload admission adds exact MIME types `image/jpeg` and `image/png`, capped at 134,217,728 encoded bytes, with the same real verified-email, terms, rights, quota and concurrency checks. A hint establishes only expected kind: separate media and verification sandboxes establish actual bytes and canonical properties. Current-generation Creator `media_facts` for stills require `media_kind`, `container`, `codec`, `width`, `height` and omit duration/frame rate. Moderation previews expose only the verified poster/image pair through the existing real moderator AAL2 signed-URL flow.

Still media and promotion jobs use schema 2 plus `media_kind: "still"`; video schema 1 is unchanged. Old readers exclude unsupported versions before leasing. New workers opt into the V2 queue reader only with a configured reviewed `WALI_STILL_POLICY_DIGEST`. Still attempts retain the existing first-lease 1,200-second execution budget and exact generation/lease authority. Newly admitted video generations use the frozen 5,400-second budget from migration008; previously issued video deadlines remain unchanged. Retried processing preserves source object/version, rights and existing attempt caps. Equal poster/thumbnail JPEG bytes may share either fixed canonical JPEG path under digest deduplication; immutable digest/MIME, role metadata and exact DB job-to-Begin equality still govern promotion.

After the existing V1 visibility repair in migration 007 and video execution budget in 008, deploy migrations 009 (enum commit), 010 (gated processing), and 011 (readers) in order, then the reviewed worker and affected Edge functions (`create-upload`, `request-install`, `moderate-submission`, `publish-release`, `automatic-publication`). Configure the same reviewed still policy digest in worker and runtime configuration. Enable `still_uploads_enabled` only after the complete native install/rendering journey is accepted. Existing video jobs retain their original policy digest and are never rewritten.
