# WALI Marketplace Threat Model

Status: accepted baseline for the public-beta foundation, 2026-09-01. This model
implements ADRs 0011–0016 and must be revisited before enabling public creator
uploads, adding a new parser/codec/model, broadening Full Disk Access, changing
catalog trust, or exposing another data surface.

This is an accepted security contract, not deployment evidence. Local controls
exist for the native engine, catalog verification, private media processing,
and bounded backend commands. Rights-proof processing, native account privacy
flows, provider session/Auth deletion, hosted signing/recovery, a dedicated
worker VM, and independent backup/restore evidence remain open release gates.

## Security objectives

1. A hostile upload or catalog object cannot execute with Full Disk Access,
   backend credentials, signing authority, or access to another user's data.
2. Only a current approved immutable release can become an installed
   catalog-origin wallpaper, and every byte is identified by a trusted signed
   manifest plus independent destination-byte verification.
3. Authorization is enforced by current server facts and RLS, not UI state,
   filenames, MIME claims, JWT display claims, or client-provided roles.
4. Publication, moderation, role, rights, key, revocation, and account actions
   are revisioned, idempotent, and auditable.
5. Marketplace analytics do not observe the desktop, local library, display
   topology, playback, applications, locks, or unrelated disk content.
6. Local imports and installed unrevoked releases continue to work when the
   marketplace is unavailable.

## Assets

- current user files reachable through Full Disk Access;
- Supabase sessions, database roles, service credentials, and Storage grants;
- catalog signing private keys and trusted public-key history;
- raw uploads, rights proof, claimant/contact details, moderator notes;
- immutable catalog artifacts, manifests, revocations, and public metadata;
- WALI local SQLite state, content-addressed objects, journals, assignments;
- moderation/audit history, ranking eligibility, and account data;
- build, dependency, container, FFmpeg, and model provenance.

## Actors and trust assumptions

| Actor | Assumption |
| --- | --- |
| visitor/user | untrusted requests; may automate, forge, replay, or manipulate input |
| creator | authenticated but uploads and metadata remain hostile |
| moderator/admin | privileged only with current role and AAL2; account compromise remains possible |
| WALI.app | signed client, but network responses/downloads are untrusted and the process has no backend/FDA authority |
| WALIAgent | local engine/install/render authority without Full Disk Access or catalog credentials |
| WALITranscoder | sandboxed parser of one bounded local attempt; outputs are untrusted claims |
| WALILockScreenHelper | only FDA-eligible WALI process; fixed operations/roots and no media/network/parser authority |
| Supabase | managed control plane; service compromise is in scope for signing/digest defenses |
| media worker | replaceable lease/movement controller; holds bounded server credentials but does not parse media |
| media/verifier/classifier sandboxes | hostile-computation boundary with no network, credentials, or unrelated mounts |
| catalog signer | high-value authority isolated in bounded Edge secret/function path |
| CDN/network | untrusted for byte identity; HTTPS and strict host policy still required |

Apple private Lock Screen formats and current macOS behavior are compatibility
inputs, not trusted stable APIs. FileVault preboot, loginwindow, other users,
root, SIP bypass, and protected-screen injection remain out of scope.

## Data-flow boundaries

```text
creator -> scoped private upload -> opaque worker download
        -> networkless media sandbox -> networkless verifier/classifier
        -> processing-private candidate artifacts -> moderator AAL2
        -> approved digest-verified promotion -> catalog-public
        -> publish transaction + signer
        -> WALI strict manifest verifier -> opaque quarantine
        -> sandboxed local transcoder -> agent destination-byte verifier
        -> local content store

agent -> authenticated bounded IPC -> FDA Lock Screen helper
      -> exact current-user allowlisted Apple store roots
```

Trust never crosses two arrows at once. A checksum establishes identity, not
safety or approval. A canonical worker output is still untrusted until separate
verification, moderation, publication, signature, client verification, and
agent publication complete.

## Direct email authentication boundary

Accepted [ADR 0022](../adr/0022-direct-production-email-otp-authentication.md)
adds email-code authentication only to the production direct edition. Email and
codes stay in transient foreground state. Each pending verification has isolated
in-memory SDK storage and cannot emit the accepted account stream. One shared
foreground authority serializes admission and sign-out across windows; each
window retains only its own presentation and pending action.

Cancellation before admission discards late results. Admission has an explicit
commit point and Completing sign-in state; subsequent sign-out is ordered after
that admission. Closing a window discards its action without pretending an
already committed session can be cancelled. Storage failures cannot publish an
accepted login. Stale cleanup must never globally sign out a newer account.

Email verification is AAL1, not MFA. Fresh TOTP/AAL2, current subject and role,
revision, deletion-retention, and identity-finalization requirements remain.
Native Apple and separate session namespaces remain for Development and Store.
Production source, Xcode, app/agent and release receipts bind the same exact
project and public trust configuration; public client keys confer no backend
privilege. SMTP/private catalog/worker credentials remain outside the app and
repository. Actual provider delivery and account/deletion journeys remain
separate release evidence.

## STRIDE analysis and controls

### Spoofing

Threats: forged Supabase JWT, stale/revoked moderator claim, creator identity
confusion, fake XPC peer, fake CDN host, substituted signing key, forged worker.

Controls:

- validate issuer, audience, expiry, session, account state, and current database
  grant; require AAL2 for moderator/admin operations;
- identify targets by UUID, never ambiguous email/handle, and prohibit
  self-review;
- authenticate XPC peers with exact designated code requirements before decode;
- exact HTTPS host allowlist, no userinfo/query/fragment authority and no
  cross-host redirects;
- ship a catalog root key, accept key transitions only when signed by an
  already trusted eligible key, and keep private keys server-only;
- lease processing attempts to a registered worker build and reject stale
  generation/lease completions.

### Tampering

Threats: changed upload during processing, malicious container structure,
worker claim forgery, mutable CDN object, manifest ambiguity, local staging
replacement, Apple-store race, audit deletion.

Controls:

- generated opaque upload paths, stable object facts, one-time binding, digest
  and size checks before/after attempts;
- full decode/re-encode in a fresh networkless sandbox and independent verifier
  sandbox;
- immutable content-addressed paths with no overwrite/upsert;
- strict canonical JSON with duplicate/unknown-key rejection, detached Ed25519,
  fixed roles/order/bounds, and download length/SHA-256 verification;
- create-exclusive quarantine and destination files; directory-relative
  no-follow operations; reject symlink, hardlink, FIFO, device, sparse/racing
  inputs; hash agent-owned destination bytes;
- exact Apple-store preimage journal, schema/ownership revalidation,
  compare-and-swap replacement, fsync, and fail-closed recovery;
- update/delete-rejecting triggers for audit and moderation actions.

### Repudiation

Threats: denied upload terms, ambiguous moderator action, duplicate publication,
role change without provenance, signing operation without evidence.

Controls:

- versioned terms acceptance, rights attestation, request IDs, actor IDs,
  expected revisions, generation IDs, idempotency reservation and response
  digest;
- append-only reviews, moderation actions, audit events, key transitions, and
  case timelines;
- canonical manifest digest, key ID, signing time, artifact set, publication
  actor, and release edition retained permanently while referenced;
- logs contain stable safe codes and request IDs, not secrets or private evidence.

### Information disclosure

Threats: service key in app/build/log, cross-user RLS leak, raw upload made
public, rights/claimant data exposed, filename/path leak, cache of account data,
FDA process compromise.

Controls:

- publishable key only in app; service/database/signing credentials in scoped
  server secret stores; secret scanning blocks release;
- authoritative `wali` schema not exposed, default grants revoked, RLS on every
  table, explicit public views/RPC allowlist, negative pgTAP matrix;
- distinct private upload/moderation/export buckets and service-only immutable
  writes to public catalog bucket;
- safe projections omit raw filenames/paths, contact, proof, private notes,
  eligibility, tokens, leases, and model raw output;
- cache public catalog only; memory/encrypted handling for private sessions;
- FDA helper has no network, media, database, WebKit, script, plug-in, process,
  arbitrary-path, or generic read API.

### Denial of service

Threats: upload bomb, huge dimensions/duration/frame rate/tracks, parser hang,
queue flood, expensive search, report spam, disk exhaustion, ranking flood.

Controls:

- media policy size/track/dimension/duration/frame-rate/decode/output bounds;
- creator quotas, two concurrent attempts, daily configurable submission cap,
  bounded TUS sessions, expiry and abandoned cleanup;
- fresh sandboxes with wall-time, CPU, RAM, PID, scratch, output and disk limits;
- durable leased queue, stale lease recovery, backoff, idempotent attempts and
  independent worker replacement;
- server-capped page/query/filter/cursor/body sizes, fixed sorts, rate-limit
  buckets, statement timeouts, indexed public access;
- deduplicate receipts and user/release/day ranking contributions;
- storage capacity alarms, immutable-object backup, and tested GC/restore.

### Elevation of privilege

Threats: RLS bypass, service-role use by client, moderator self-approval,
decoder escape reaching secrets/kernel workload, helper command/path expansion,
dynamic dependency/model substitution.

Controls:

- no client service role; fixed-search-path security-definer functions without
  dynamic SQL; current role/AAL checks inside privileged transaction;
- self-review prohibition and latest-generation/rights/checklist gates;
- dedicated worker host account; rootless per-attempt containers with no
  network/credentials/runtime socket/capabilities/devices/host mounts and
  `no-new-privileges`; worker VM must not be treated as a hard boundary for
  unrelated sensitive production without additional isolation;
- helper operations restricted to status/activate/deactivate/restore and fixed
  internally resolved roots; reject paths, URLs, blobs, commands and unknown
  fields;
- exact dependency/model/container/binary digests, allowlisted licenses, SBOM,
  provenance, SHA-pinned Actions, review before update.

## Abuse and business-logic threats

| Threat | Control |
| --- | --- |
| creator uploads copyrighted media | rights declaration, proof when required, human review, notice/counter-notice, delist and repeat-infringer process |
| model suggests unsafe/wrong category | suggestions are non-authoritative and moderator-approved; model cannot publish or decide rights |
| fake popularity | one-use install receipt, unique eligible user/release/day, exclude self/suspended/abuse, time decay and rate limits |
| stale moderator publishes old bytes | expected submission revision/generation and artifact set checked inside publication transaction |
| report used for censorship | report does not revoke; human triage and auditable controlled action |
| copyright takedown abused as malware revocation | security revocation reasons are closed and separately authorized; normal cases delist only |
| signing key compromise | freeze publication, retire key, use surviving offline/root trust path, signed key/revocation transition, client safe mode |
| compromised catalog metadata links to SSRF/local file | URLs rendered inert or strict HTTPS; backend never fetches creator source URL; artifact host exact allowlist |

## Full Disk Access-specific review

The helper is the highest-consequence local component. Its accepted attack
surface is deliberately smaller than a normal app:

- input is a bounded versioned operation plus release ID/digest/expected
  compatibility revision;
- caller is an authenticated signed WALI peer;
- filesystem access is compiled fixed current-user roots and WALI-owned object
  roots only;
- output is bounded status/result/error codes;
- no arbitrary listing/read/write/copy API exists;
- no URL, bookmark, path, media bytes, archive, object name, shell string, model,
  or plug-in crosses the protocol;
- automatic tests use injected temporary roots and never touch the live Apple
  wallpaper store.

Static checks reject forbidden imports/APIs. Bundle verification inspects every
nested signature, entitlement, identifier, service name, and Hardened Runtime
setting. Permission UX explains that only authenticated-session Lock Screen
continuity needs Full Disk Access and provides a reversible disable/restore path.

## Privacy analysis

Collected data is enumerated in `data-inventory.yml`. The marketplace records
account identity, explicit interactions, upload/review/right facts, and coarse
operational/security events. It prohibits raw IP storage and all device-local
wallpaper observation. Personalization is optional; opt-out deletes the derived
interest profile and prevents regeneration. Public counts are verified installs,
saves, and favorites with documented aggregation—not live usage.

The required account-deletion workflow revokes sessions, tombstones identity,
deletes private preferences/interactions/derived profiles when allowed,
anonymizes public creator identity where compatible with attribution/legal
obligations, and retains only the minimum security/legal/audit facts. Local
database/object processing currently stops at `awaiting_auth_cleanup`; provider
session revocation, Auth identity cleanup, and native request/status UX are not
implemented. Generated export files expire after seven days, but native export
request/status/retrieval is also deferred.

## Supply-chain analysis

The exact policy is `dependency-policy.yml`. Release requires a complete SPDX
SBOM for Swift, Deno, Go, Python, OCI images, FFmpeg, model code/weights, and
seed media; immutable pins/digests; license compatibility; vulnerability and
secret scans; provenance; and retained notices/source obligations. The default
FFmpeg build avoids GPL/nonfree flags until a later accepted decision. No
Backdrop/Wallsflow asset, endpoint, cookie, credential, manifest, or brand
element is permitted.

## Detection and response

Alert on authentication/authorization denials, RLS test drift, publication and
signing failures, key validity, processing crash/timeouts, queue age, scanner
findings, object/digest mismatch, revocation fetch/verify failure, anomalous
reports/installs, backup age, and helper IPC/ownership failure. Alerts contain
request/release/attempt IDs and safe codes only.

Runbooks must cover credential leak, signing compromise, malicious release,
worker compromise, database restore, object restore, queue backlog, RLS leak,
rights takedown, ranking abuse, and account deletion. Preserve evidence, rotate
scoped credentials, pause the smallest affected surface, and never erase audit
history or weaken verification during urgency.

## Required evidence before public creator uploads

- accepted ADRs and compatibility/module registries;
- complete API, media, dependency, and data contracts passing mutation checks;
- RLS authorization matrix and exposed-surface allowlist passing locally and in
  staging;
- hostile-media corpus and sandbox escape-boundary tests;
- manifest/key/revocation fixtures and tamper/replay/rotation tests;
- helper static/bundle/peer/path/store/recovery verification;
- database and object restore exercise;
- terms, privacy, creator license, content/copyright, account deletion, and
  security reporting surfaces reviewed for the launch jurisdiction;
- seed media provenance and license records;
- signed/notarized app verification and owner production authorization.

## Residual risks

- AVFoundation, FFmpeg, image, model, kernel, and container-runtime defects can
  still exist; isolation reduces consequence but is not proof of absence.
- The private Lock Screen store may change on any macOS build; unknown shapes
  fail closed and continuity can stop working.
- Supabase and CDN compromise can disrupt service; signatures and digests limit
  artifact substitution but do not guarantee availability.
- Human moderation and rights review can be wrong; reports, appeals, audit, and
  delisting reduce but do not eliminate harm.
- One shared VM kernel is not strong tenant isolation. WALI's hostile-media
  worker must not be presented as harmless to unrelated production workloads;
  a dedicated VM remains the production target.
