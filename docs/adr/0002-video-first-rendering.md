# 0002: Video-first rendering on Apple media frameworks

- status: accepted
- date: 2026-08-30
- owner_role: agent_runtime_maintainer
- accepted_by: project_owner_delegation
- approval_reference: founding autonomous architecture mandate

## Context

WALI must accept ordinary user videos, render efficiently, and support a future licensed catalog. Apple's Macintosh wallpaper proves procedural rendering is possible, but requiring a custom program/shader format would make user creation and content acquisition unnecessarily difficult.

## Decision

Use normalized video as the first wallpaper format. AVFoundation owns looping playback and VideoToolbox owns hardware encoding/decoding. A renderer interface allows future procedural or web adapters without exposing their implementation to assignment and policy logic.

## Invariants

- User import remains one operation; codec complexity is internal.
- Audio is removed and playback is muted.
- Poster imagery remains available while decoding is paused or failed.
- No custom renderer replaces Apple media frameworks without measured evidence.
- Asset metadata declares format and required renderer version.

## Alternatives considered

- Procedural/Metal first: potentially smaller assets but a much narrower creator ecosystem.
- Web views: flexible but heavier, less predictable, and a larger security surface.
- Raw frame pipeline for all videos: enables fan-out but adds complexity before multi-display measurements justify it.

## Consequences

Storage and conversion are first-class modules. Very long or high-frame-rate sources need bounded profiles. Future renderers require a new adapter and capability descriptor, not changes to assignment semantics.

## Migration and rollback

Asset manifests are versioned and identify variants by format. New renderers may
coexist only within the readable ranges and product compatibility proved by
`docs/compatibility/surfaces.yml` fixtures. No asset format is implemented or
promised readable yet.

## Verification

- Fixture import and playback tests.
- Codec/output inspection.
- One- and multi-display CPU, memory, and energy benchmarks.
- Eight-hour loop and repeated teardown tests.
