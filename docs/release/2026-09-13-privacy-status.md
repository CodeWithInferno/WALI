# Account privacy implementation, 13 September 2026

The owner approved the concrete privacy scope under ADR0029 and private creator blocking under ADR0019. The source implements automated completion of confirmed account deletions, status receipts that survive sign-out, creator blocking, eligible hosted-upload cleanup, and account-bound Apple authorization custody and revocation. New automatic deletion admission and dispatch default to disabled until the scoped production rollout is complete.

## Verified source behavior

- A new isolated local database replayed all 44 migrations. All 27 database test files passed 817 assertions. The schema-only provider fixture required its usual storage table grants inside the rollback transactions for tests 011 and 015; production grants were not changed.
- All 138 Edge tests pass with formatting, type checking and lint. Apple tests cover exact native client keys, provider identity and lowercase bearer responses, encrypted subject binding, expired leases, uncertain commit replies and account freeze after a successful commit. Already committed credentials remain in deletion custody without admitting a frozen account's sign-in.
- Native focused tests cover 16 creator-blocking cases, 16 Auth authority cases, 4 receipt cases and 42 marketplace coordinator cases. A persisted retryable deletion failure continues refreshing through completion. Creating a receipt precedes admission; completion removes its live capability and account mapping while keeping a dismissible local confirmation.
- The affected worker cleanup, storage and queue tests pass. Public cleanup requires the current exact object intent, shared-reference eligibility and existing copyright holds; the worker has no account or Apple credential authority.
- Architecture and marketplace contract checks pass. Redacted secret scanning passes without adding scanner exemptions. Generated test keys are local test material; provider keys are not source inputs.

## Production and distribution boundary

This record does not claim production deployment, real account deletion, Apple token revocation, or App Store submission. The deployment packet applies only 013–015 after the already approved 009–012 rollout, retains the automation gate as false, and updates four named Edge routes. Its three new routes authenticate their specific credentials rather than relying on the platform JWT gate, as separately approved by the owner.

The deletion worker rollout is separate from the image-intake rollout. It requires the verified 28c4 still worker as its baseline and replaces only that worker with the reviewed 2a246 cleanup decoder, preserving the sandbox image, protected environment and namespace. Scheduler secrets, Apple keys and effective legal documents are separate activation inputs. No existing publishing account is a deletion fixture.

Stable GitHub 0.1.0 remains a separate already published binary. A later release must be built and tested from its final merged source. Store sandbox installation/rendering acceptance is tracked under ADR0030; a compiled or archived package is not an Apple upload or review result.
