# 0024: Private worker ID-mapping helpers

- status: accepted
- date: 2026-09-12
- owner_role: media_worker_maintainer
- accepted_by: project_owner
- approval_reference: repository-owner directive to repair the production product end to end autonomously, 2026-09-12; this implementation preserves the already specified namespace capability bound

## Context

A fresh production boot fails in the credential-free namespace service with
`newuidmap: open of uid_map failed: Permission denied`. The installed helpers
are root-owned setuid binaries without file capabilities. Their compiled code
omits Shadow's optional effective-user reset, leaving effective UID 0 unable to
open the worker-owned map under the service's existing capability bound.
[Shadow explains this capability/identity interaction](https://github.com/shadow-maint/shadow/blob/4.17.4/lib/idmapping.c#L101-L163).
Earlier deployment may have masked the failure by creating a reusable Podman
namespace before service startup; this is an inference, not cold-boot evidence.

## Decision

Manage private copies of the host's current `/usr/bin/newuidmap` and
`/usr/bin/newgidmap` at `/usr/libexec/wali-worker/idmap/`. The parent directory is
root:root 0755; `idmap` is root:wali-worker 0750. Both files are root:wali-worker
0550, have no setuid/setgid bits, and receive only `cap_setuid=ep` and
`cap_setgid=ep`, respectively. No unprivileged account can replace them.

Only `wali-podman-namespace.service` receives
`PATH=/usr/libexec/wali-worker/idmap:/usr/sbin:/usr/bin:/sbin:/bin`.
All path directories must be root-owned and not group/other writable; the unit
continues to invoke `/usr/bin/podman` absolutely. Podman
[resolves mapping helpers through PATH](https://github.com/containers/storage/blob/main/pkg/unshare/unshare_linux.go#L290-L295).
The helpers retain the worker's effective UID while acquiring only their
respective mapping capability. Matching the namespace owner's UID is material
to [Linux namespace authority](https://man7.org/linux/man-pages/man7/user_namespaces.7.html).

Extend release snapshots with the two helper byte copies and a version-1
`payload/idmap-helpers/manifest.json`: source package/version, SHA-256, installed
owner/group, mode, and exact file capability for each fixed path. Inactive
snapshot copies remain 0400 without capabilities. The existing release manifest
binds these files; validation checks actual installed ownership, permissions,
capabilities, and bytes because content hashes alone do not bind extended
attributes. Installation sets ownership/mode before setting capabilities.

## Invariants

- Namespace bootstrap remains credential-free, bounded to CAP_SETUID/CAP_SETGID,
  with empty ambient capabilities and its existing NoNewPrivileges setting.
- Main-worker NoNewPrivileges, empty capability sets, sandbox/container isolation,
  and media-policy requirements under [ADR 0015](0015-hostile-media-canonicalization.md)
  remain unchanged.
- No CAP_SYS_ADMIN, CAP_DAC_OVERRIDE, global helper modification, sysctl, LSM,
  IAM, credential, or subordinate-ID policy change is authorized by this decision.

## Alternatives considered

Widening capabilities grants unrelated authority and does not preserve the
current bound. Manual namespace prewarming does not repair boot. Rebuilding the
system uidmap package adds a broader maintenance and global-package change.

## Consequences

This introduces two narrowly privileged, release-managed executables. Root
ownership, fixed paths, hash checks, and exact capability checks are essential.
Private copies do not automatically receive package updates: updating uidmap
requires a reviewed recapture and new snapshot. Capability-supporting local
storage and the existing `setcap`/`getcap` tools are required; missing support
fails deployment rather than falling back to setuid or broader capabilities.

## Migration and rollback

Stage and validate before stopping services. Extend the existing transaction to
capture any previous private helper state, install while both services are
stopped, and verify before activation. An older snapshot without these files
means their absence: rollback removes only the managed private helper directory,
restores the previous unit and snapshot, and preserves recorded active/stopped
state. Rollback does not claim an old cold-boot defect or expired credentials are
healthy. A changed snapshot requires a newly calculated release digest.

## Verification

Hostless fixtures cover tampered bytes, wrong capabilities/ownership/modes,
missing helpers, and rollback from both previous-helper and absent-helper states.
Run the affected worker isolation/deployment checks. On the explicitly approved
dedicated host, prove startup after a fresh reboot before any manual Podman
invocation can seed a namespace: namespace service succeeds, the worker verifier
passes, and the main worker and media sandbox retain their existing restrictions.
A warm restart or structural check is insufficient. Implementation and live
cold-boot verification remain distinct evidence; a warm deployment does not prove boot recovery.
