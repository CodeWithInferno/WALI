# Worker compromise response

Assume compromise when an image/signature/digest check fails, a sandbox has
network or host access, secrets appear in sandbox state/logs, an unexpected
listener/container/process exists, verified bytes differ from published bytes,
or the dedicated host's integrity is uncertain.

## Immediate containment

1. Disable new queue dispatch to this worker identity and revoke its scoped
   database/storage credential. Do not delete attempts or evidence.
2. Stop only `wali-media-worker.service`. Do not restart unrelated workloads or
   change a shared firewall as an improvised containment step.
3. Isolate the VM through the provider control plane, preserving the encrypted
   disk snapshot, serial console log, cloud audit log, image digests, SBOMs,
   unit journal, process/container inventory, and relevant Supabase audit rows.
4. Mark every attempt leased by this worker after the last known-good time for
   independent reprocessing. Quarantine its unpublished artifacts and revoke
   any catalog release whose byte provenance is not independently established.

Never trust cleanup performed from the suspected host, and never reuse its
secret, SSH host key, rootless container store, scratch volume, or cached image.

## Recovery

1. Rotate the worker credential and any registry token reachable by the host.
   Rotate broader keys only when evidence shows exposure; document the scope.
2. Verify signed catalog manifests and public object digests from an independent
   trusted environment. Preserve append-only moderation/audit history.
3. Rebuild a fresh encrypted dedicated VM from `media-worker.md`; do not clean
   and return the suspected VM to service.
4. Pull only newly reviewed immutable images, verify Cosign signatures and
   SPDX SBOMs, run the hostile corpus, then process a generated staging upload.
5. Requeue quarantined attempts with new generations. Confirm stale completions
   cannot commit and each accepted submission reaches one terminal state.
6. Restore dispatch gradually and watch queue depth, safe-code rates, duration,
   scratch usage, storage conflicts, and unexpected egress.

## Post-incident record

Record the detection time, affected worker/release/image digests, credential
scope, attempts and catalog releases reviewed, containment actions, evidence
locations, root cause, customer/legal impact assessment, and hardening actions.
Do not put secrets, raw rights evidence, creator private data, or proprietary
media into the public issue or repository.
