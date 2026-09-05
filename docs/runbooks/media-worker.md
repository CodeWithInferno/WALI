# Media worker deployment and rebuild

**Implementation status:** the dedicated staging worker has processed an original
video through canonical encoding, independent verification, immutable Storage,
and native creator submission. Its signed image and rootless service were checked
on September 4, 2026. Production network controls, recovery drills, capacity,
and an exact release candidate remain gates; see the release evidence ledger.
Never use these instructions on a shared VM.

The Linux worker is disposable compute. Supabase remains authoritative; the VM
must never become a second product database or public API. These instructions
apply to a fresh encrypted, dedicated VM. They must not be used to repurpose a
shared production host.

The worker exposes no public port. Permit inbound SSH only from the operator
VPN/CIDR and established return traffic; restrict egress to DNS/NTP, the exact
Supabase project, approved OCI registry, and OS mirrors. Health and aggregate
metrics stay on the mode-0600 Unix socket. Never expose a Docker/Podman socket,
and never apply blanket host firewall changes on a shared machine.

## Required release inputs

- reviewed `wali-media-worker` Linux binary and SHA-256;
- media, verifier, and optional classifier OCI references pinned by manifest
  digest;
- Cosign public key and valid signatures for every image;
- SPDX SBOM whose content records each configured image digest;
- root-owned environment file containing a dedicated NOINHERIT worker database
  login and a separate `wali_storage_worker` JWT constrained by Storage RLS. A Supabase
  service-role/project secret is forbidden;
- provider evidence for encrypted root disk, deny-by-default ingress, and
  restricted egress.

Never place secrets, populated environment files, model weights, proprietary
media, or signing private keys in this repository or deployment bundle.

## Runtime trust boundary

The Go worker accepts only server-issued PGMQ envelopes. It validates the
frozen `uploads-private` reference and streams the source once to compute the
trusted digest; creators never provide that digest. Canonical output first
lands in `processing-private`. Only a frozen approved promotion may re-stream
it to `catalog-public`, and every new or existing stored object is read back
and checked for exact length and SHA-256 before completion. Export, cleanup,
promotion, classification, and live catalog-integrity queues use fixed names
and lease-bound database RPCs. Live catalog integrity verification is not an
archive or restore proof.

The media image is an untrusted-data plane. Its process and independent verify
passes accept fixed paths only, validate the embedded policy digest, fully
decode/re-encode supported media, strip audio and metadata, enforce bounded
tracks/duration/dimensions/rate/output, and write their bounded claim last.
They accept no URL, caller filename, command, prompt, shell fragment, or
plugin. Permanent policy failures emit only a stable `failure.json`; runtime
crashes and timeouts remain retryable. The generated hostile corpus includes
empty/truncated containers, spoofed scripts, symlinks, and FIFOs and is valid
only as evidence for the exact immutable image digest tested.

The offline staging helper removes allowed audio, subtitle, and data tracks by
bounded video-only stream-copy remux. It must not scale, filter, or encode that
intermediate; `process-media` remains the sole canonical encoder, followed by
the independent verifier. Staged results remain `third_party_unverified` and
must never be promoted merely because media verification passed.

Classification is optional. Without reviewed weights the worker emits
`classifier_unavailable` and no guesses. A production build must pass
`WALI_MODEL_IMAGE=registry/repository@sha256:<64-hex-digest>`; that immutable
model image's `/model` contains only files matching
`model-manifest.json`; the final image digest therefore binds application,
taxonomy, dependencies, and weights. Runtime downloads, remote model code,
mutable model mounts, pickle/PyTorch serialized blobs, arbitrary prompts, and
unknown model IDs are forbidden. Only seven independently verified JPEG
frames plus bounded server-read title/description enter the networkless
classifier; model, taxonomy, and frame-set provenance and normalized bounded
embeddings are validated before suggestions are stored.

Required runtime settings are: a TLS `WALI_DATABASE_URL` for a LOGIN member of
`wali_worker`; origin-only `WALI_STORAGE_URL`; distinct public
`WALI_STORAGE_PUBLISHABLE_KEY` and lease-bound `wali_storage_worker` JWT;
bounded worker ID; fixed media queue; narrow scratch/socket paths; absolute
Podman path; immutable media/verifier/classifier image digests; and the exact
reviewed media-policy digest. A service-role token, mutable image tag, TCP
health listener, or broad scratch path must fail startup. Health and metrics
contain aggregate readiness, counts, safe codes, and durations only—never
tokens, object URLs, creator text, filenames, or claim bodies.

## Rebuild

1. Provision a new minimal Ubuntu 26.04 VM with rendered
   `deploy/worker/cloud-init.yml`. Replace the dedicated-host marker's
   `REPLACE_ENVIRONMENT` and `REPLACE_PROJECT_REF` values before provisioning;
   the root-owned marker, protected environment file, and every deploy or
   rollback command must name the same environment and 20-letter Supabase
   project ref.
   Confirm SSH keys only, root/password login disabled, security updates active,
   and `wali-worker` has subordinate UID/GID ranges but no privileged groups.
2. Verify the host is dedicated. Inventory units, listeners, containers,
   networks, volumes, mounts, routes, and firewall rules before installing WALI.
3. Build the Go binary in reviewed CI. Generate/sign immutable linux/amd64 media
   and classifier images and preserve their SBOMs and license bundles. Build
   the production classifier with `--target production` and an immutable
   reviewed model image passed as `WALI_MODEL_IMAGE`; the ordinary source-only
   image is not inference-capable. The production target verifies every model
   byte against `model-manifest.json` and emits the exact model/taxonomy labels
   enforced by both deployment and runtime verification.
   Before selecting a classifier digest, mirror exactly the manifest-pinned
   model revision, verify every listed byte count and digest, preserve its
   Apache-2.0 notice/model-card review, and run the source contract tests.
4. Copy the release inputs over the management channel without logging the
   environment file. Run
   `deploy/worker/deploy.sh --dry-run --environment staging --supabase-project-ref <ref> ...`,
   review its WALI-only targets, then run the same command as root without
   `--dry-run`. The deploy script rejects a database or Storage origin that
   does not belong to that exact project.
5. Run `/usr/local/sbin/wali-worker-verify`. It checks the dedicated identity,
   protected secret file, rootless runtime, immutable local images, systemd
   resource controls, absence of TCP/UDP listeners, Unix health/metrics,
   scratch cleanup, and networkless rejection probes in a transient service with
   the worker's containment settings. The empty-input probe verifies startup,
   mounts, policy validation and rejection reporting; it does not exercise FFmpeg.
   The original-video canary separately supplies decode/encode evidence. Failed
   probes retain only a bounded root-only diagnostic at
   `/var/log/wali-worker-verification-last.log`.
6. Submit one generated staging upload. Confirm exactly one terminal generation,
   immutable artifact digests, no residual container, and no stale scratch.
7. Stop the worker mid-attempt, wait for lease expiry, restart it, and confirm
   the new generation completes exactly once while the stale generation cannot
   publish.
8. Rotate the bootstrap storage/database credential after the first successful
   run. Retain only the current and one rollback release/image set.

Before production enablement also run `go vet ./...`, `go test -race ./...`,
the classifier frozen test suite, the sandbox static corpus, and the runtime
corpus against each exact media image ID/digest. An end-to-end backup is not
proved by the catalog-integrity queue: separately create the provider archive,
reopen and hash it, verify the deterministic attestation, and perform an
isolated restore drill before passing the deployment gate.

## Rollback

`sudo deploy/worker/deploy.sh --rollback --environment staging --supabase-project-ref <ref>`
restores a complete immutable snapshot: binary, protected environment, both WALI
units, Storage configuration, verification script, public verification key, SBOMs,
and runbooks. Snapshot identity hashes all of these inputs. The environment and
manifest remain root-only. Both the host binding and snapshot must match the
explicit environment and project. Legacy binary-only releases cannot be selected
for rollback; the next successful deployment captures the actual installed files
as its complete baseline.

Activation is serialized with a host lock. It records a durable pending
transaction before changing live files, restarts the worker and its namespace
dependency, and verifies the installed snapshot before advancing `previous`.
Failure restores the baseline files, links and unit state. An interrupted pending
transaction is recovered on the next invocation. Failed recovery stops the worker
and retains the transaction for inspection. An identical deployment is a verified
no-op that preserves the rollback target. `--rollback --dry-run` validates the
target without mutating the host.

Run a deployment/rollback/redeployment drill in staging for the exact candidate.
Retain root-only snapshots securely: they include scoped credentials. Rotate keys
with awareness that an old snapshot may contain credentials that have since been
revoked. A Podman storage-layout change requires a separate migration. Database
migrations, Supabase configuration, unrelated units, host networks, and unrelated
containers are outside this rollback boundary.

If verification fails, stop the WALI unit, preserve logs and attempt metadata,
and follow `worker-compromise.md` when compromise cannot be excluded.
