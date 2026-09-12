# Production Creator Studio availability — 11 September 2026

## Reproduction

The public `v0.1.0-beta.2` app, source `559208c`, restored a real production
email session and loaded its Account profile. Opening Creator Studio displayed
“Creator Studio unavailable” and “Sign in and refresh your account to load
creator access.” Discover displayed only “Trending” and “New.”

A fresh read-only production query found no runtime-configuration row, no
Creator Terms version, no creator profiles or grants, no published wallpapers,
and no published collections. Taxonomy existed: 12 categories, 14 tags, and two
allowed licenses. Authenticated RPC permissions were present. The production
media worker was stopped; its current running image and media-policy digest
could not be verified.

## Causes and correction

Creator authorization legitimately returns no current terms when the service
has not been activated. The coordinator consequently skips creator metadata.
The foreground fallback previously mislabeled that state, loading, and request
failures as sign-in problems. It must present those states separately without
inventing metadata, granting roles, or weakening term acceptance.

The home endpoint can return stable sections with no items. The foreground
previously treated the presence of those sections as a populated catalog. It
must omit item-empty sections and use the existing empty-catalog view when no
renderable sections remain.

The UI correction does not initialize production configuration, accept terms,
create a creator grant, start the worker, or publish catalog media.

## Production activation still required

The only natively supported Creator Terms version is `2026-09-01`; the checked-in
terms explicitly remain draft and not effective for public UGC. Public uploads
must follow `docs/legal/README.md` before configuring that version. The operator
and contact are already recorded; legal activation is not recorded by this UI
repair.

The prospective production singleton uses environment `production`, public
base URL `https://afgxvhhubqzgpijcstsv.supabase.co/storage/v1/object/public/catalog-public`,
and the deployed worker's independently verified media-policy digest. Current
source policy digest is `9710d4e665b29989a0c6109c1f807ae5fb52ef009536194663b365ae06e28875`.
There is no separate creator-disable flag: populating the terms version enables
active accounts to accept the current terms and self-enroll through the existing
subject-bound command. A manual creator-role insertion is not a repair.

Creator processing also requires the production worker running with verified
provenance. Public catalog publication separately requires the reviewed trust
bootstrap with the existing owner's real AAL2 session and content authorized
for public distribution. No staging content is promoted by this change.

## Verification

The signed beta.2 native reproduction and fresh production read-only checks
are complete. Two focused empty-section regressions first reproduced four
failures. After the repair, all 32 MarketplaceCoordinator tests passed, including
creator request failure, retry, loading, unconfigured, and sign-out transitions.
The Debug build-for-testing, architecture and marketplace-contract checks passed.
Independent source review found no actionable issues.

The corrected signed candidate still requires its native availability check and
normal release lane. This source record does not claim creator uploads,
processing, catalog publication, or a new GitHub release are complete.
