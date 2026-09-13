# 0028: Bound production video processing with measured throughput

- status: proposed
- date: 2026-09-13
- owner_role: security_responder
- accepted_by: pending
- approval_reference: proposed record; production completion directive authorizes preparation and separately reviewed deployment, without specific acceptance of this numeric budget

## Context and scope

The initial licensed catalog includes a 4,147-frame 4K clip. On the existing four-vCPU host, a 64-frame ultrafast/QP20/four-thread sample took 48.3182 seconds versus 57.8995 seconds with two CPUs. Its 52.2-minute master estimate exceeds the current 1,200-second execution budget. Full longest-clip completion is not yet proven.

This narrowly supersedes the attempt-wall-time value governed by ADR 0015 and the first-lease timing paragraph of ADR 0025 for new video generations only. Mandatory resource limits, independent verification, rights, signed immutable publication and privacy/isolation remain unchanged. Preset/CPU tuning retains the codec/output contract and introduces no new rendering strategy. The owner's production completion directive authorizes preparing this correction; hosted activation is recorded separately.

## Decision

Use `preset=ultrafast,qp=20,threads=4` for the full video master. Its process container receives 4 CPUs; verifier/classifier and still containers retain 2 CPUs. The existing VM stays unchanged; service CPUQuota becomes 400%, while memory/PID/tmpfs/capability/NNP/network limits remain. One media consumer processes one job synchronously; two admitted uploads queue behind it.

New video complete/retry commands emit `first_queue_lease_video_90m_v1`. The private reader freezes one 5,400-second absolute deadline at first lease or existing Begin; old markers remain 1,200 seconds and issued/frozen deadlines never extend. All phases share that deadline. Short leases, heartbeat, bounded terminal writes and retry limits remain unchanged. Still admission and V2 exposure are not activated.

Static-token startup and each new media queue read require more than 95 minutes of remaining lifetime. Cache the validated expiry and recheck before leasing. Other queues and Ack/Nack/Reject retain their behavior. No token is issued, renewed, lengthened or logged. Real Storage authentication remains authoritative. Optional database renewal is unchanged and is not activated here.

Canonical output policy JSON stays unchanged. New media image/SBOM/source pins bind the flags; verifier/classifier pins stay unchanged. The documented attempt-wall maximum becomes 5,400 seconds. The inventory names generated consumers that do not exist; this change does not invent a generator or alter the distinct runtime canonical-policy digest.

Warm activation uses explicit reviewed deployment mode. Namespace unit/storage bytes, active start identity and privileges must stay unchanged. Only the media service is stopped/started with systemd's `ignore-requirements` job mode, preserving ordering without propagating its PartOf namespace restart. Its identity is retained in the existing complete-snapshot rollback transaction. The mode refuses cold recovery and does not implement the separately held namespace helper or Vault changes.

## Validation and limits

Focused tests cover token lifetime/admission/recovery, CPU selection, new/old queue deadlines and retry source ownership. Complete-snapshot rollback is tested with fake systemctl. Production acceptance requires the full longest initial clip to verify, publish and visibly render within its frozen budget. Arbitrary admitted 10-minute 8K input is not proven to fit 90 minutes; timeout and source retention remain truthful.
