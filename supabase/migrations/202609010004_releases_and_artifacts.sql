-- WALI Marketplace foundation: immutable releases and content-addressed artifacts.

create table wali.wallpaper_releases (
  id uuid primary key default gen_random_uuid(),
  wallpaper_id uuid not null references wali.wallpapers(id) on delete restrict,
  edition integer not null check (edition > 0),
  source_submission_id uuid not null unique,
  status wali.release_status not null default 'processing',
  manifest_epoch integer not null default 1 check (manifest_epoch = 1),
  manifest_revision integer not null default 0 check (manifest_revision >= 0),
  manifest_body bytea,
  manifest_digest text,
  manifest_signature bytea,
  signing_key_id text,
  published_at timestamptz,
  revoked_at timestamptz,
  revocation_reason wali.revocation_reason,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (wallpaper_id, edition),
  constraint releases_manifest_digest check (manifest_digest is null or manifest_digest ~ '^[0-9a-f]{64}$'),
  constraint releases_manifest_body check (manifest_body is null or octet_length(manifest_body) between 2 and 65536),
  constraint releases_manifest_hash check (
    manifest_body is null or manifest_digest is null
    or encode(extensions.digest(manifest_body, 'sha256'), 'hex') = manifest_digest
  ),
  constraint releases_manifest_signature check (manifest_signature is null or octet_length(manifest_signature) = 64),
  constraint releases_signing_key_format check (signing_key_id is null or signing_key_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$'),
  constraint releases_manifest_complete check (
    status not in ('published', 'revoked')
    or (manifest_body is not null and manifest_digest is not null and manifest_signature is not null
        and signing_key_id is not null and published_at is not null)
  ),
  constraint releases_revocation_complete check (
    (status = 'revoked') = (revoked_at is not null and revocation_reason is not null)
  )
);

alter table wali.wallpapers
  add constraint wallpapers_current_release_fk
  foreign key (current_release_id) references wali.wallpaper_releases(id)
  on delete restrict deferrable initially deferred;

create table wali.artifacts (
  digest text primary key,
  media_type text not null,
  byte_count bigint not null check (byte_count > 0 and byte_count <= 2147483648),
  storage_bucket text not null,
  storage_path text not null unique,
  width integer not null check (width between 1 and 7680),
  height integer not null check (height between 1 and 4320),
  duration_ms bigint check (duration_ms between 1 and 600000),
  frame_rate_numerator integer check (frame_rate_numerator between 1 and 120000),
  frame_rate_denominator integer check (frame_rate_denominator between 1 and 1001),
  codec text not null,
  pixel_format text not null,
  color_space text not null,
  has_audio boolean not null default false,
  verified_by_attempt_id uuid,
  created_at timestamptz not null default statement_timestamp(),
  constraint artifacts_digest_format check (digest ~ '^[0-9a-f]{64}$'),
  constraint artifacts_media_type check (media_type in ('image/jpeg', 'image/png', 'video/mp4')),
  constraint artifacts_catalog_bucket check (storage_bucket = 'catalog-public'),
  constraint artifacts_path_content_addressed check (
    storage_path ~ ('^sha256/' || substring(digest from 1 for 2) || '/' || substring(digest from 3 for 2) || '/' || digest || '/[a-z0-9_-]+\.(jpg|jpeg|png|mp4)$')
  ),
  constraint artifacts_video_duration check ((media_type = 'video/mp4') = (duration_ms is not null)),
  constraint artifacts_video_rate check (
    (media_type = 'video/mp4') = (frame_rate_numerator is not null and frame_rate_denominator is not null)
  ),
  constraint artifacts_silent_video check (has_audio = false)
);

create table wali.release_artifacts (
  release_id uuid not null references wali.wallpaper_releases(id) on delete restrict,
  role wali.artifact_role not null,
  artifact_digest text not null references wali.artifacts(digest) on delete restrict,
  variant_name text,
  sort_order integer not null check (sort_order between 0 and 1000),
  created_at timestamptz not null default statement_timestamp(),
  primary key (release_id, role),
  constraint release_artifacts_variant_name check (
    variant_name is null or variant_name ~ '^[a-z0-9][a-z0-9_-]{0,63}$'
  )
);

alter table wali.wallpaper_embeddings
  add constraint wallpaper_embeddings_release_fk
  foreign key (release_id) references wali.wallpaper_releases(id) on delete cascade;

create index releases_wallpaper_status_idx on wali.wallpaper_releases (wallpaper_id, status, edition desc);
create index releases_published_idx on wali.wallpaper_releases (published_at desc, id) where status = 'published';
create index release_artifacts_digest_idx on wali.release_artifacts (artifact_digest, release_id);

create or replace function wali.reject_artifact_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception using errcode = 'P0001', message = 'WALI_ARTIFACT_IMMUTABLE';
end
$$;

create or replace function wali.guard_release_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  required_count integer;
begin
  if tg_op = 'UPDATE' and old.status in ('published', 'revoked') then
    if row(
      new.wallpaper_id, new.edition, new.source_submission_id, new.manifest_epoch,
      new.manifest_revision, new.manifest_body, new.manifest_digest, new.manifest_signature,
      new.signing_key_id, new.published_at
    ) is distinct from row(
      old.wallpaper_id, old.edition, old.source_submission_id, old.manifest_epoch,
      old.manifest_revision, old.manifest_body, old.manifest_digest, old.manifest_signature,
      old.signing_key_id, old.published_at
    ) then
      raise exception using errcode = 'P0001', message = 'WALI_RELEASE_IMMUTABLE';
    end if;
    if old.status = 'revoked' and new.status <> 'revoked' then
      raise exception using errcode = 'P0001', message = 'WALI_RELEASE_IMMUTABLE';
    end if;
  end if;

  if new.status = 'published' and (tg_op = 'INSERT' or old.status <> 'published') then
    select count(*) into required_count
      from wali.release_artifacts ra
     where ra.release_id = new.id
       and ra.role in ('thumbnail', 'poster', 'preview', 'video_default');
    if required_count <> 4 then
      raise exception using errcode = 'P0001', message = 'WALI_RELEASE_REQUIRED_ARTIFACTS';
    end if;
    if new.manifest_body is null or new.manifest_digest is null or new.manifest_signature is null or new.signing_key_id is null then
      raise exception using errcode = 'P0001', message = 'WALI_RELEASE_UNSIGNED';
    end if;
    new.published_at := coalesce(new.published_at, statement_timestamp());
  end if;

  return new;
end
$$;

create or replace function wali.guard_release_artifact_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_release uuid;
begin
  target_release := coalesce(new.release_id, old.release_id);
  if exists (
    select 1 from wali.wallpaper_releases r
     where r.id = target_release and r.status in ('published', 'revoked')
  ) then
    raise exception using errcode = 'P0001', message = 'WALI_RELEASE_IMMUTABLE';
  end if;
  return coalesce(new, old);
end
$$;

create or replace function wali.validate_current_release()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.current_release_id is not null and not exists (
    select 1 from wali.wallpaper_releases r
     where r.id = new.current_release_id
       and r.wallpaper_id = new.id
       and r.status = 'published'
  ) then
    raise exception using errcode = 'P0001', message = 'WALI_CURRENT_RELEASE_INVALID';
  end if;
  return new;
end
$$;

create trigger artifacts_reject_update before update or delete on wali.artifacts
for each row execute function wali.reject_artifact_mutation();
create trigger releases_guard before insert or update on wali.wallpaper_releases
for each row execute function wali.guard_release_mutation();
create trigger releases_touch before update on wali.wallpaper_releases
for each row execute function wali.touch_mutable_row();
create trigger release_artifacts_guard before insert or update or delete on wali.release_artifacts
for each row execute function wali.guard_release_artifact_mutation();
create trigger wallpapers_current_release_guard before insert or update of current_release_id, status on wali.wallpapers
for each row execute function wali.validate_current_release();

alter table wali.wallpaper_releases enable row level security;
alter table wali.artifacts enable row level security;
alter table wali.release_artifacts enable row level security;

create policy releases_public_read on wali.wallpaper_releases for select to anon, authenticated
using (status in ('published', 'revoked'));
create policy artifacts_public_read on wali.artifacts for select to anon, authenticated
using (
  exists (
    select 1 from wali.release_artifacts ra
    join wali.wallpaper_releases r on r.id = ra.release_id
    where ra.artifact_digest = digest and r.status in ('published', 'revoked')
  )
);
create policy release_artifacts_public_read on wali.release_artifacts for select to anon, authenticated
using (exists (select 1 from wali.wallpaper_releases r where r.id = release_id and r.status in ('published', 'revoked')));

grant select on wali.wallpaper_releases, wali.artifacts, wali.release_artifacts to anon, authenticated;

revoke all on function wali.reject_artifact_mutation() from public, anon, authenticated;
revoke all on function wali.guard_release_mutation() from public, anon, authenticated;
revoke all on function wali.guard_release_artifact_mutation() from public, anon, authenticated;
revoke all on function wali.validate_current_release() from public, anon, authenticated;
