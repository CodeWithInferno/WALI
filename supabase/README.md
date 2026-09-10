# WALI marketplace backend

This directory is a local-first Supabase control plane for marketplace
development. Its migrations define identity, catalog publication, creator and
moderation workflows, immutable signed releases, engagement/ranking, Storage
policies, queues, cron, and retention. The public Data API exposes only the
versioned `public.*_v1` allowlist; workflow and evidence tables live in `wali`
behind RLS and narrow functions.

## Local setup

Requirements: Docker and Supabase CLI 2.116.0 or newer.

```bash
make backend-start
make backend-reset
make backend-test
make backend-lint
make marketplace-contracts
```

`backend-reset` rebuilds the local database from every migration and loads
`seed.sql`. The seed is deterministic and synthetic: it contains no production
identity, secret, or third-party wallpaper. Local fixture accounts use password
`local-only-password`; useful emails are `admin@example.invalid`,
`creator-a@example.invalid`, `user-b@example.invalid`, and
`moderator@example.invalid`.

## Native marketplace integration

The local commands above test the database and Edge Functions. They do not make
the local HTTP endpoint usable by the native app: `CatalogEnvironment` requires
HTTPS with a public hostname and no explicit port, and catalog host validation
rejects loopback/private-style names and numeric IPs. Keep those trust checks.
The local wallpaper core can be developed without configuring marketplace access.

For a connected native journey, use an explicitly authorized isolated hosted
development project with a public HTTPS endpoint, approved CDN host, and its own
catalog signing/verification setup. Hosted setup is a separate reviewed operation;
these local targets do not provision it. Then copy
`Config/Marketplace.example.xcconfig` to the ignored
`Config/Marketplace.local.xcconfig` and fill only that environment's public project
URL, publishable key, approved CDN host, and catalog verification public key.
Service-role keys, database passwords, signing private keys, and VM credentials
must never enter the app configuration or repository.

## Safety boundary

- Do not run `supabase link`, `supabase db push`, or remote reset/migration
  commands as part of local development.
- Raw uploads and rights evidence are private and use exact issued object paths.
- Published artifacts are content-addressed and immutable.
- Storage deletion is queued for a Storage API worker; database jobs do not
  bypass Supabase Storage deletion guards.
- Install grants bind the current wallpaper revision and release, return the
  canonical signed manifest, and issue a one-use receipt for at most 30 minutes.
- Favorite, save, and follow state retains monotonic tombstone revisions so an
  add/remove/add sequence cannot reuse revision zero.

Hosted development and production projects are intentionally outside these
commands. Deployment requires reviewed environment-specific configuration,
secret injection, backups, and an explicit migration runbook.
