# 0007: License WALI code under Apache 2.0 with DCO

- status: accepted
- date: 2026-08-30
- owner_role: project_owner
- accepted_by: project_owner_delegation
- approval_reference: founding autonomous architecture mandate
- related: [LICENSE](../../LICENSE), [NOTICE](../../NOTICE), [DCO](../../DCO)

## Context

WALI describes itself as open source, but source visibility without an explicit
license grants no general right to use, modify, or redistribute the code.
Contributions also need a lightweight provenance statement. Wallpaper media,
reference-product assets, and future catalog content may have licenses separate
from the application code.

## Decision

License WALI software, source documentation, configuration, and original
code-adjacent materials under the Apache License 2.0 unless a file or directory
states a different license.

Adopt Developer Certificate of Origin 1.1 sign-off for contributions. Keep the
standard license in `LICENSE`, the DCO text in `DCO`, and attribution/scope
clarification in `NOTICE`.

The code license does not grant rights to wallpaper, video, image, audio,
catalog, or reference-product media unless that content is explicitly included
under Apache 2.0 or another identified license.

## Invariants

- No corporate copyright owner is invented.
- Contributor copyright remains with the applicable contributors.
- Contributions include DCO sign-off.
- Third-party code and assets retain their own notices and license terms.
- Proprietary reference assets are never redistributed under WALI's code
  license.
- Product documentation does not call WALI open source without an OSI-approved
  license present.

## Alternatives considered

- Keep the repository source-visible without a license: incompatible with the
  open-source claim and unusable for normal contribution.
- MIT: simpler text, but lacks Apache 2.0's explicit patent grant and NOTICE
  mechanism.
- Contributor license agreement: stronger centralized rights, but unnecessary
  administrative overhead for the current project.
- License all media under the code license: impossible for separately licensed
  or contributor-supplied content.

## Consequences

Users receive clear copyright and patent permissions for covered work, subject
to Apache 2.0 conditions. Contributors certify provenance through DCO rather
than assigning copyright. Distribution must retain the license and applicable
NOTICE material, and media licensing must be tracked separately.

## Migration and rollback

The repository had no prior license grant, so this establishes rather than
relicenses the project baseline. Future inclusion of third-party material
requires compatible terms and preserved notices.

Changing the project code license requires a new ADR and consent from relevant
copyright holders; it is not treated as a routine rollback.

## Verification

- `LICENSE` is the unmodified Apache License 2.0 text.
- `DCO` is Developer Certificate of Origin 1.1.
- `NOTICE`, `README.md`, `CONTRIBUTING.md`, and `GOVERNANCE.md` state the code
  and media scope accurately.
- Contribution instructions show the required `Signed-off-by` workflow without
  claiming hosted enforcement exists.
