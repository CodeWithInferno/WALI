# Private creator preferences v1

Accepted ADR0019 governs migration `202609130013_private_creator_blocking.sql`.
These are private preferences, not moderation or security revocations. Source and
fixture results do not establish production activation.

| RPC | Named parameters | Result |
| --- | --- | --- |
| `my_creator_blocks_v1` | `cursor` text/null, `limit` 1–100, `selected_creator_id` UUID/null (default null) | `subject_id`, `generation`, `items`, `next_cursor` |
| `set_creator_block_v1` | `creator_id` UUID, `desired` boolean, `expected_revision` integer, `idempotency_key` text | `subject_id`, `creator_id`, `desired`, `revision`, `generation` |
| `my_hidden_interactions_v1` | `cursor` text/null, `limit` 1–100 | `subject_id`, `generation`, `items`, `next_cursor` |

Only an active `auth.uid()` is the actor. AAL1 suffices; clients cannot supply
another viewer. New targets must be accessible creators; self-block is invalid.
An existing relationship can be unblocked after its creator becomes inactive.
The active limit is 10,000 with no eviction. Revision zero means no relation;
inactive rows retain revision. Effective changes increment viewer generation.
Exact successful retries replay; changed payload/key reuse fails.

The ordinary list is outgoing, active-only and cursor-paged. An optional exact
`selected_creator_id` with null cursor returns at most one existing outgoing row,
including its inactive revision. This lets a client revalidate before a mutation
without a fourth public RPC. Rows contain `creator_id`, `active`, `revision`,
nullable `display_name` and `handle`. Cursors bind viewer/generation/kind and are
at most 1,024 bytes. Revision/generation fit JSON-safe unsigned integers.

Hidden interaction rows contain only `kind` (`favorite`, `saved`, `follow`),
`target_id`, `active`, `revision`. Cleanup uses existing negative favorite/save/
follow commands with the returned revision and a retained retry key. No hidden
media, incoming list, notification, public count or analytics signal is added.
Owner export includes only outgoing relationships; account cleanup removes both
directions and advances affected viewer generations.

Authenticated V1/V2 catalog base views filter before paging/counts. Home, browse,
search, direct detail, related items, creators, collections and saved/favorite
lists inherit that predicate. New installs and positive interactions serialize
with the viewer preference lock; grants already committed before a block retain
their existing record/install semantics. Profile locks precede this preference
lock so deletion cannot be followed by a stale new relationship. Existing
local media, assignments and signed manifests remain unchanged.

Native catalog reads refresh the subject/generation snapshot before metadata
is admitted for hydration. Changed preferences cancel pending presentation and
reload; missing/failed authenticated preference reads fail closed. Anonymous
choices store only bounded IDs in the foreground container, filter before media
hydration, never upload on sign-in, and return on sign-out. Account switches clear
all subject-bound state. The UI offers Block Creator beside Report, keeps a
minimal known target for reporting after hiding it, and provides Account →
Blocked Creators with bounded list and hidden-interaction cleanup pages.

Rollback may stop new commands but must preserve existing server filtering,
positive-action denial and relation generations. Do not drop block rows or
re-enable a previous client that would present personalized cached metadata.
