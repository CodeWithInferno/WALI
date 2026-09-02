-- WALI Marketplace foundation: bounded service-only commands behind Edge Functions.

alter table wali.wallpaper_releases
  add column metadata_body bytea,
  add column metadata_digest text;
alter table wali.wallpaper_releases
  add constraint releases_metadata_digest check (metadata_digest is null or metadata_digest ~ '^[0-9a-f]{64}$'),
  add constraint releases_metadata_body check (metadata_body is null or octet_length(metadata_body) between 2 and 65536),
  add constraint releases_metadata_hash check (
    metadata_body is null or metadata_digest is null
    or encode(extensions.digest(metadata_body, 'sha256'), 'hex') = metadata_digest
  );

alter table wali.upload_sessions
  add column declared_media_type text,
  add column target_wallpaper_id uuid references wali.wallpapers(id) on delete restrict,
  add column upload_endpoint text,
  add column storage_version text;
alter table wali.upload_sessions drop constraint upload_sessions_path_opaque;
alter table wali.upload_sessions
  add constraint upload_declared_media_type check (declared_media_type in ('video/mp4', 'video/quicktime')),
  add constraint upload_endpoint_safe check (
    upload_endpoint is null or upload_endpoint ~ '^https://[^[:space:][:cntrl:]@]+/storage/v1/upload/resumable/[A-Za-z0-9._~/?=&%-]+$'
    or upload_endpoint ~ '^http://(127[.]0[.]0[.]1|localhost)(:[0-9]{2,5})?/storage/v1/upload/resumable/[A-Za-z0-9._~/?=&%-]+$'
  ),
  add constraint upload_sessions_path_opaque check (
    storage_path = creator_id::text || '/' || id::text || '/source'
  );
alter table wali.upload_sessions drop constraint upload_sessions_completion;
alter table wali.upload_sessions add constraint upload_sessions_completion check (
  (status = 'completed') =
  (completed_at is not null and received_byte_count is not null and detected_media_type is not null and storage_version is not null)
);

alter table wali.role_grants add column revision bigint not null default 1 check (revision > 0);

create table wali.runtime_configuration (
  singleton boolean primary key default true check (singleton),
  environment text not null check (environment in ('local', 'development', 'production')),
  catalog_public_base_url text not null,
  creator_terms_version text not null,
  media_policy_digest text not null,
  updated_at timestamptz not null default statement_timestamp(),
  constraint runtime_catalog_url check (
    catalog_public_base_url ~ '^https://[^[:space:][:cntrl:]@]+/storage/v1/object/public/catalog-public$'
    and (environment = 'local' or catalog_public_base_url !~ 'example[.]invalid')
  ),
  constraint runtime_terms_version check (creator_terms_version ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}([.][0-9]+)?$')
  ,constraint runtime_media_policy_digest check (media_policy_digest ~ '^[0-9a-f]{64}$')
);
alter table wali.runtime_configuration enable row level security;
create policy runtime_configuration_public_read on wali.runtime_configuration
for select to anon, authenticated using (true);
grant select on wali.runtime_configuration to anon, authenticated;
grant all on wali.runtime_configuration to service_role;

create table wali.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references wali.profiles(id) on delete restrict,
  request_id uuid not null unique,
  requested_at timestamptz not null default statement_timestamp(),
  status text not null default 'pending' check (status in ('pending', 'processing', 'completed', 'cancelled'))
);
alter table wali.account_deletion_requests drop constraint account_deletion_requests_status_check;
alter table wali.account_deletion_requests
  add column lease_owner text,
  add column lease_expires_at timestamptz,
  add column safe_error_code text,
  add column completed_at timestamptz,
  add column revision bigint not null default 1,
  add column auth_identity_status text not null default 'session_revocation_pending',
  add column sessions_revoked_at timestamptz,
  add column session_revocation_operation_id uuid,
  add column identity_deleted_at timestamptz,
  add column identity_deletion_operation_id uuid,
  add constraint account_deletion_status check (status in ('pending', 'processing', 'held', 'awaiting_auth_cleanup', 'completed', 'failed', 'cancelled')),
  add constraint account_deletion_lease_pair check ((lease_owner is null) = (lease_expires_at is null)),
  add constraint account_deletion_safe_error check (safe_error_code is null or safe_error_code ~ '^WALI_[A-Z0-9_]{2,96}$'),
  add constraint account_deletion_identity_status check (auth_identity_status in ('session_revocation_pending', 'sessions_revoked', 'operator_cleanup_required', 'completed')),
  add constraint account_deletion_revision_positive check (revision > 0),
  add constraint account_deletion_sessions_pair check (
    (sessions_revoked_at is null) = (session_revocation_operation_id is null)
  ),
  add constraint account_deletion_identity_pair check (
    (identity_deleted_at is null) = (identity_deletion_operation_id is null)
  ),
  add constraint account_deletion_completed_identity check (
    status <> 'completed' or (auth_identity_status = 'completed' and identity_deleted_at is not null)
  );
alter table wali.account_deletion_requests enable row level security;
grant all on wali.account_deletion_requests to service_role;

-- Preserve immutable event facts while permitting the sole privacy-safe
-- account-deletion mutation: removing the subject link. All other columns must
-- remain identical and the subject must already be deprovisioning.
create or replace function wali.reject_append_only_mutation()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if tg_table_schema = 'wali' and tg_table_name = 'engagement_events'
     and tg_op = 'UPDATE'
     and to_jsonb(old) ->> 'user_id' is not null
     and to_jsonb(new) -> 'user_id' = 'null'::jsonb
     and (to_jsonb(new) - 'user_id') = (to_jsonb(old) - 'user_id')
     and exists (select 1 from wali.profiles profile
       where profile.id::text = to_jsonb(old) ->> 'user_id'
         and profile.status in ('deletion_pending', 'deleted')) then
    return new;
  end if;
  raise exception using errcode = 'P0001', message = 'WALI_APPEND_ONLY';
end $$;

alter table wali.install_receipts alter column user_id drop not null;

create table wali.cleanup_object_intents (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null check (bucket_id in ('uploads-private', 'moderation-private', 'exports-private', 'processing-private')),
  storage_path text not null,
  reason text not null check (reason in ('expired_upload', 'expired_export', 'account_deletion', 'staged_artifact_retention')),
  status text not null default 'queued' check (status in ('queued', 'processing', 'completed', 'failed')),
  lease_owner text,
  lease_expires_at timestamptz,
  safe_error_code text check (safe_error_code is null or safe_error_code ~ '^WALI_[A-Z0-9_]{2,96}$'),
  created_at timestamptz not null default statement_timestamp(),
  completed_at timestamptz,
  unique (bucket_id, storage_path),
  constraint cleanup_object_path_plain check (wali.plain_text_is_valid(storage_path, 1, 768) and storage_path !~ '(^|/)\.\.(/|$)'),
  constraint cleanup_object_lease_pair check ((lease_owner is null) = (lease_expires_at is null))
);
alter table wali.cleanup_object_intents enable row level security;
grant all on wali.cleanup_object_intents to service_role;

-- Mutable control-plane state is kept private; only bounded commands and
-- projections below cross the Edge boundary.
do $role$
begin
  if not exists (select 1 from pg_roles where rolname = 'wali_worker') then
    create role wali_worker nologin noinherit nobypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'wali_storage_worker') then
    create role wali_storage_worker nologin noinherit nobypassrls;
  end if;
end
$role$;
grant wali_storage_worker to authenticator;
grant usage on schema wali to wali_worker;
grant usage on schema storage to wali_storage_worker;

create table wali.catalog_signed_documents (
  kind text not null check (kind in ('trust_transition', 'revocations')),
  revision bigint not null check (revision between 1 and 2147483647),
  issued_at timestamptz not null,
  body bytea not null check (octet_length(body) between 2 and 1048576),
  body_digest text not null check (body_digest ~ '^[0-9a-f]{64}$'),
  signature bytea not null check (octet_length(signature) = 64),
  signing_key_id text not null references wali.catalog_signing_keys(key_id) on delete restrict,
  created_by uuid not null references wali.profiles(id) on delete restrict,
  request_id uuid not null unique,
  created_at timestamptz not null default statement_timestamp(),
  primary key (kind, revision),
  constraint signed_document_hash check (encode(extensions.digest(body, 'sha256'), 'hex') = body_digest)
);

create table wali.security_response_grants (
  user_id uuid primary key references wali.profiles(id) on delete restrict,
  granted_by uuid not null references wali.profiles(id) on delete restrict,
  granted_at timestamptz not null default statement_timestamp(),
  revoked_at timestamptz,
  revision bigint not null default 1 check (revision > 0),
  constraint security_response_grant_window check (revoked_at is null or revoked_at >= granted_at)
);
alter table wali.security_response_grants enable row level security;
grant all on wali.security_response_grants to service_role;
create index catalog_signed_documents_latest_idx
  on wali.catalog_signed_documents (kind, revision desc);
alter table wali.catalog_signed_documents enable row level security;
grant all on wali.catalog_signed_documents to service_role;

create trigger catalog_signed_documents_immutable
before update or delete on wali.catalog_signed_documents
for each row execute function wali.reject_append_only_mutation();

create table wali.publication_intents (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references wali.profiles(id) on delete restrict,
  idempotency_key text not null,
  request_id uuid not null,
  submission_id uuid not null references wali.submissions(id) on delete restrict,
  release_id uuid not null references wali.wallpaper_releases(id) on delete restrict,
  wallpaper_id uuid not null references wali.wallpapers(id) on delete restrict,
  submission_revision bigint not null,
  generation integer not null,
  wallpaper_revision bigint not null,
  artifact_set_digest text not null check (artifact_set_digest ~ '^[0-9a-f]{64}$'),
  metadata_set_digest text not null check (metadata_set_digest ~ '^[0-9a-f]{64}$'),
  signing_key_id text not null references wali.catalog_signing_keys(key_id) on delete restrict,
  issued_at timestamptz not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  response jsonb,
  created_at timestamptz not null default statement_timestamp(),
  unique (actor_id, idempotency_key),
  constraint publication_intent_key check (
    char_length(idempotency_key) between 16 and 64 and idempotency_key ~ '^[A-Za-z0-9_-]+$'
  ),
  constraint publication_intent_expiry check (expires_at > created_at and expires_at <= created_at + interval '5 minutes'),
  constraint publication_intent_consumed check ((consumed_at is null) = (response is null))
);
alter table wali.publication_intents enable row level security;
grant all on wali.publication_intents to service_role;

create table wali.submission_tag_suggestions (
  submission_id uuid not null references wali.submissions(id) on delete cascade,
  tag_id uuid not null references wali.tags(id) on delete restrict,
  source wali.taxonomy_source not null default 'creator',
  confidence numeric(5,4),
  model_id text,
  model_revision text,
  created_at timestamptz not null default statement_timestamp(),
  primary key (submission_id, tag_id, source),
  constraint submission_tag_suggestion_model check (
    (source = 'classifier') = (model_id is not null and model_revision is not null)
  )
);
alter table wali.submission_tag_suggestions enable row level security;
grant all on wali.submission_tag_suggestions to service_role;

alter table wali.submissions
  add column content_warning text,
  add constraint submissions_content_warning_plain check (
    content_warning is null or wali.plain_text_is_valid(content_warning, 1, 500)
  );
alter table wali.submissions drop constraint submissions_attribution_plain;
alter table wali.submissions add constraint submissions_attribution_plain check (
  attribution_text is null or wali.plain_text_is_valid(attribution_text, 1, 1000)
);
alter table wali.rights_declarations
  add column proof_object_ids uuid[] not null default '{}',
  add constraint rights_proof_object_count check (
    cardinality(proof_object_ids) between 0 and 5
  );
alter table wali.rights_declarations drop constraint rights_attribution_plain;
alter table wali.rights_declarations add constraint rights_attribution_plain check (
  attribution_text is null or wali.plain_text_is_valid(attribution_text, 1, 1000)
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('processing-private', 'processing-private', false, 1073741824,
  array['image/jpeg', 'image/png', 'video/mp4'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table wali.staged_artifacts (
  digest text primary key check (digest ~ '^[0-9a-f]{64}$'),
  media_type text not null check (media_type in ('image/jpeg', 'image/png', 'video/mp4')),
  byte_count bigint not null check (byte_count between 1 and 2147483648),
  storage_bucket text not null default 'processing-private' check (storage_bucket = 'processing-private'),
  storage_path text not null unique,
  width integer not null check (width between 1 and 7680),
  height integer not null check (height between 1 and 4320),
  duration_ms bigint check (duration_ms between 1 and 600000),
  frame_rate_numerator integer,
  frame_rate_denominator integer,
  codec text not null,
  pixel_format text not null,
  color_space text not null,
  has_audio boolean not null default false check (not has_audio),
  verified_by_attempt_id uuid not null references wali.processing_attempts(id) on delete restrict,
  created_at timestamptz not null default statement_timestamp(),
  constraint staged_artifact_path check (
    storage_path ~ ('^sha256/' || substring(digest from 1 for 2) || '/' || substring(digest from 3 for 2) || '/' || digest || '/[a-z0-9_-]+[.](jpg|jpeg|png|mp4)$')
  )
);
create table wali.release_staged_artifacts (
  release_id uuid not null references wali.wallpaper_releases(id) on delete restrict,
  role wali.artifact_role not null,
  artifact_digest text not null references wali.staged_artifacts(digest) on delete restrict,
  sort_order integer not null check (sort_order between 0 and 1000),
  primary key (release_id, role)
);
create table wali.artifact_promotions (
  id uuid primary key default gen_random_uuid(),
  release_id uuid not null unique references wali.wallpaper_releases(id) on delete restrict,
  status text not null default 'queued' check (status in ('queued', 'processing', 'completed', 'failed')),
  lease_owner text,
  lease_expires_at timestamptz,
  safe_error_code text check (safe_error_code is null or safe_error_code ~ '^WALI_[A-Z0-9_]{2,96}$'),
  created_at timestamptz not null default statement_timestamp(),
  completed_at timestamptz,
  constraint artifact_promotion_lease_pair check ((lease_owner is null) = (lease_expires_at is null))
);
create table wali.staged_upload_intents (
  attempt_id uuid not null references wali.processing_attempts(id) on delete cascade,
  generation integer not null check (generation > 0),
  worker_identity text not null,
  role wali.artifact_role not null,
  digest text not null check (digest ~ '^[0-9a-f]{64}$'),
  byte_count bigint not null check (byte_count between 1 and 2147483648),
  media_type text not null check (media_type in ('image/jpeg', 'image/png', 'video/mp4')),
  storage_path text not null,
  artifact_claim jsonb not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  primary key (attempt_id, role),
  constraint staged_upload_worker_plain check (wali.plain_text_is_valid(worker_identity, 1, 128)),
  constraint staged_upload_claim_bound check (jsonb_typeof(artifact_claim) = 'object' and octet_length(artifact_claim::text) <= 8192),
  constraint staged_upload_path check (
    storage_path ~ ('^sha256/' || substring(digest from 1 for 2) || '/' || substring(digest from 3 for 2) || '/' || digest || '/[a-z0-9-]+[.](jpg|jpeg|png|mp4)$')
  ),
  constraint staged_upload_expiry check (expires_at > created_at and expires_at <= created_at + interval '10 minutes')
);
alter table wali.staged_artifacts enable row level security;
alter table wali.release_staged_artifacts enable row level security;
alter table wali.artifact_promotions enable row level security;
alter table wali.staged_upload_intents enable row level security;
grant all on wali.staged_artifacts, wali.release_staged_artifacts, wali.artifact_promotions,
  wali.staged_upload_intents to service_role;
create trigger staged_artifacts_immutable before update or delete on wali.staged_artifacts
for each row execute function wali.reject_artifact_mutation();
select pgmq.create('wali_promotions');
select pgmq.create('wali_promotions_dlq');
select pgmq.create('wali_account_deletions');
select pgmq.create('wali_account_deletions_dlq');
insert into wali.queue_policies (
  queue_name, max_attempts, visibility_timeout_seconds, retry_delay_seconds, message_retention
) values
  ('wali_promotions', 5, 300, 60, interval '14 days'),
  ('wali_account_deletions', 8, 300, 120, interval '30 days')
on conflict (queue_name) do nothing;

alter table wali.account_exports
  add column lease_owner text,
  add column lease_expires_at timestamptz,
  add column byte_count bigint check (byte_count is null or byte_count between 2 and 104857600),
  add column digest text check (digest is null or digest ~ '^[0-9a-f]{64}$'),
  add column safe_error_code text check (safe_error_code is null or safe_error_code ~ '^WALI_[A-Z0-9_]{2,96}$'),
  add constraint account_exports_lease_pair check ((lease_owner is null) = (lease_expires_at is null)),
  add constraint account_exports_ready_metadata check (
    status <> 'ready' or (byte_count is not null and digest is not null)
  );

alter table wali.backup_verification_runs
  add column lease_owner text,
  add column lease_expires_at timestamptz,
  add column safe_error_code text check (safe_error_code is null or safe_error_code ~ '^WALI_[A-Z0-9_]{2,96}$'),
  add constraint backup_verification_lease_pair check ((lease_owner is null) = (lease_expires_at is null));

create or replace function wali.storage_worker_can_select(
  object_bucket text, object_path text, worker_identity text
) returns boolean language sql stable security definer set search_path = '' as $$
  select worker_identity is not null and wali.plain_text_is_valid(worker_identity, 1, 128) and (
    (object_bucket = 'uploads-private' and exists (
      select 1 from wali.processing_attempts attempt
      join wali.submissions submission on submission.id = attempt.submission_id
      join wali.upload_sessions upload on upload.id = submission.upload_session_id
      where upload.storage_path = object_path and attempt.lease_owner = worker_identity
        and attempt.lease_expires_at > statement_timestamp()
        and attempt.status in ('leased', 'downloading', 'transcoding', 'verifying', 'classifying')
        and submission.generation = attempt.generation and submission.status = 'processing'
    )) or
    (object_bucket = 'processing-private' and (
      exists (
        select 1 from wali.staged_upload_intents intent
        join wali.processing_attempts attempt on attempt.id = intent.attempt_id
        where intent.storage_path = object_path and intent.worker_identity = worker_identity
          and intent.consumed_at is null and intent.expires_at > statement_timestamp()
          and attempt.lease_owner = worker_identity and attempt.lease_expires_at > statement_timestamp()
      ) or exists (
        select 1 from wali.staged_artifacts staged
        join wali.release_staged_artifacts link on link.artifact_digest = staged.digest
        join wali.artifact_promotions promotion on promotion.release_id = link.release_id
        where staged.storage_path = object_path and promotion.status = 'processing'
          and promotion.lease_owner = worker_identity and promotion.lease_expires_at > statement_timestamp()
      )
    )) or
    (object_bucket = 'catalog-public' and exists (
      select 1 from wali.staged_artifacts staged
      join wali.release_staged_artifacts link on link.artifact_digest = staged.digest
      join wali.artifact_promotions promotion on promotion.release_id = link.release_id
      where staged.storage_path = object_path and promotion.status = 'processing'
        and promotion.lease_owner = worker_identity and promotion.lease_expires_at > statement_timestamp()
    )) or
    (object_bucket = 'exports-private' and exists (
      select 1 from wali.account_exports export where export.storage_path = object_path
        and export.status = 'processing' and export.lease_owner = worker_identity
        and export.lease_expires_at > statement_timestamp()
    )) or
    (object_bucket in ('uploads-private', 'exports-private', 'processing-private', 'moderation-private') and exists (
      select 1 from wali.cleanup_object_intents cleanup
      where cleanup.bucket_id = object_bucket and cleanup.storage_path = object_path
        and cleanup.status = 'processing' and cleanup.lease_owner = worker_identity
        and cleanup.lease_expires_at > statement_timestamp()
    ))
  )
$$;

create or replace function wali.storage_worker_can_insert(
  object_bucket text, object_path text, worker_identity text
) returns boolean language sql stable security definer set search_path = '' as $$
  select case object_bucket
    when 'processing-private' then exists (
      select 1 from wali.staged_upload_intents intent
      join wali.processing_attempts attempt on attempt.id = intent.attempt_id
      where intent.storage_path = object_path and intent.worker_identity = worker_identity
        and intent.consumed_at is null and intent.expires_at > statement_timestamp()
        and attempt.lease_owner = worker_identity and attempt.lease_expires_at > statement_timestamp()
    )
    when 'catalog-public' then exists (
      select 1 from wali.staged_artifacts staged
      join wali.release_staged_artifacts link on link.artifact_digest = staged.digest
      join wali.artifact_promotions promotion on promotion.release_id = link.release_id
      where staged.storage_path = object_path and promotion.status = 'processing'
        and promotion.lease_owner = worker_identity and promotion.lease_expires_at > statement_timestamp()
    )
    when 'exports-private' then exists (
      select 1 from wali.account_exports export where export.storage_path = object_path
        and export.status = 'processing' and export.lease_owner = worker_identity
        and export.lease_expires_at > statement_timestamp()
    )
    else false end
$$;

create or replace function wali.storage_worker_can_delete(
  object_bucket text, object_path text, worker_identity text
) returns boolean language sql stable security definer set search_path = '' as $$
  select worker_identity is not null and wali.plain_text_is_valid(worker_identity, 1, 128)
    and exists (
      select 1 from wali.cleanup_object_intents cleanup
      where cleanup.bucket_id = object_bucket and cleanup.storage_path = object_path
        and cleanup.status = 'processing' and cleanup.lease_owner = worker_identity
        and cleanup.lease_expires_at > statement_timestamp()
    )
$$;

create or replace function wali.moderator_can_preview_canonical(
  object_bucket text, object_path text
) returns boolean language sql stable security definer set search_path = '' as $$
  select object_bucket = 'processing-private'
    and auth.uid() is not null and wali.current_aal() = 'aal2'
    and exists (select 1 from wali.profiles profile
      where profile.id = auth.uid() and profile.status = 'active')
    and exists (select 1 from wali.role_grants grant_row
      where grant_row.user_id = auth.uid() and grant_row.role in ('moderator', 'admin')
        and grant_row.revoked_at is null)
    and exists (
      select 1 from wali.staged_artifacts staged
      join wali.release_staged_artifacts link on link.artifact_digest = staged.digest
      join wali.wallpaper_releases release on release.id = link.release_id
      join wali.submissions submission on submission.id = release.source_submission_id
      join wali.processing_attempts attempt on attempt.id = staged.verified_by_attempt_id
      where staged.storage_path = object_path
        and submission.status in ('submitted', 'under_review', 'approved')
        and attempt.submission_id = submission.id and attempt.generation = submission.generation
    )
$$;

grant usage on schema wali to wali_storage_worker;
grant select, insert, delete on storage.objects to wali_storage_worker;
create policy wali_worker_read_scoped_objects on storage.objects for select to wali_storage_worker
using (wali.storage_worker_can_select(bucket_id, name, auth.jwt() ->> 'worker_id'));
create policy wali_worker_create_processing_objects on storage.objects for insert to wali_storage_worker
with check (
  bucket_id = 'processing-private'
  and wali.storage_worker_can_insert(bucket_id, name, auth.jwt() ->> 'worker_id')
);

create policy wali_worker_promote_approved_objects on storage.objects for insert to wali_storage_worker
with check (
  bucket_id = 'catalog-public' and wali.storage_worker_can_insert(bucket_id, name, auth.jwt() ->> 'worker_id')
);
create policy wali_worker_create_owned_export on storage.objects for insert to wali_storage_worker
with check (
  bucket_id = 'exports-private' and wali.storage_worker_can_insert(bucket_id, name, auth.jwt() ->> 'worker_id')
);
create policy wali_worker_delete_leased_private_object on storage.objects for delete to wali_storage_worker
using (
  bucket_id in ('uploads-private', 'exports-private', 'processing-private', 'moderation-private')
  and wali.storage_worker_can_delete(bucket_id, name, auth.jwt() ->> 'worker_id')
);
create policy wali_moderator_read_canonical_preview on storage.objects for select to authenticated
using (wali.moderator_can_preview_canonical(bucket_id, name));

-- Replace placeholder public URLs with the environment-owned Storage origin.
create or replace view public.catalog_wallpapers_v1
with (security_invoker = true, security_barrier = true) as
select w.id, w.slug::text as slug, w.title,
  jsonb_build_object(
    'id', p.id, 'handle', p.handle::text, 'display_name', p.display_name,
    'avatar_url', case when p.avatar_path is null then null else cfg.catalog_public_base_url || '/' || p.avatar_path end,
    'verification_status', cp.verification_status::text
  ) as creator,
  w.content_rating::text as content_rating,
  jsonb_build_object('id', c.id, 'name', c.name, 'slug', c.slug) as primary_category,
  coalesce(tags.approved_tags, '[]'::jsonb) as approved_tags,
  poster.artifact as poster, preview.artifact as preview,
  w.current_release_id, w.revision, w.published_at,
  coalesce(stats.verified_install_count, 0) as verified_install_count,
  coalesce(stats.favorite_count, 0) as favorite_count,
  coalesce(stats.save_count, 0) as save_count
from wali.runtime_configuration cfg
join wali.wallpapers w on true
join wali.profiles p on p.id = w.creator_id and p.status = 'active'
join wali.creator_profiles cp on cp.user_id = p.id
join wali.categories c on c.id = w.primary_category_id and c.active
join wali.licenses l on l.id = w.license_id and l.active and l.redistribution_allowed
join wali.wallpaper_releases r on r.id = w.current_release_id and r.status = 'published'
join lateral (
  select jsonb_build_object(
    'role', ra.role::text, 'url', cfg.catalog_public_base_url || '/' || a.storage_path,
    'sha256', a.digest, 'byte_count', a.byte_count, 'media_type', a.media_type,
    'width', a.width, 'height', a.height, 'duration_ms', coalesce(a.duration_ms, 0)
  ) as artifact from wali.release_artifacts ra join wali.artifacts a on a.digest = ra.artifact_digest
  where ra.release_id = r.id and ra.role = 'poster'
) poster on true
join lateral (
  select jsonb_build_object(
    'role', ra.role::text, 'url', cfg.catalog_public_base_url || '/' || a.storage_path,
    'sha256', a.digest, 'byte_count', a.byte_count, 'media_type', a.media_type,
    'width', a.width, 'height', a.height, 'duration_ms', a.duration_ms
  ) as artifact from wali.release_artifacts ra join wali.artifacts a on a.digest = ra.artifact_digest
  where ra.release_id = r.id and ra.role = 'preview'
) preview on true
left join lateral (
  select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.label, 'slug', t.slug) order by t.slug) as approved_tags
  from wali.wallpaper_tags wt join wali.tags t on t.id = wt.tag_id and t.active
  where wt.wallpaper_id = w.id and wt.status = 'approved'
) tags on true
left join lateral (
  select sum(s.unique_installers)::bigint as verified_install_count,
    sum(s.favorites)::bigint as favorite_count, sum(s.saves)::bigint as save_count
  from wali.wallpaper_stats_daily s where s.wallpaper_id = w.id
) stats on true
where cfg.singleton and w.status = 'published' and w.visibility = 'public';

create or replace view public.catalog_creators_v1
with (security_invoker = true, security_barrier = true) as
select p.id, p.handle::text as handle, p.display_name,
  case when p.avatar_path is null then null else cfg.catalog_public_base_url || '/' || p.avatar_path end as avatar_url,
  cp.bio, cp.website_url, cp.verification_status::text as verification_status,
  count(w.id)::bigint as published_wallpaper_count
from wali.runtime_configuration cfg
join wali.profiles p on true
join wali.creator_profiles cp on cp.user_id = p.id
left join wali.wallpapers w on w.creator_id = p.id and w.status = 'published' and w.visibility = 'public'
where cfg.singleton and p.status = 'active'
group by p.id, p.handle, p.display_name, p.avatar_path, cp.bio, cp.website_url,
  cp.verification_status, cfg.catalog_public_base_url;

create or replace view public.my_profile_v1
with (security_invoker = true, security_barrier = true) as
select p.id, p.handle::text as handle, p.display_name,
  case when p.avatar_path is null then null else cfg.catalog_public_base_url || '/' || p.avatar_path end as avatar_url,
  p.status::text as status, p.revision, pref.rating_ceiling::text as rating_ceiling,
  pref.locale, pref.personalization_opt_out, pref.marketing_opt_out, pref.revision as preferences_revision
from wali.runtime_configuration cfg
join wali.profiles p on p.id = auth.uid()
join wali.user_preferences pref on pref.user_id = p.id
where cfg.singleton;

create or replace function wali.edge_actor_has_role(actor_id uuid, required_role wali.role_name)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from wali.profiles profile
    join wali.role_grants grant_row on grant_row.user_id = profile.id
    where profile.id = actor_id and profile.status = 'active'
      and grant_row.role = required_role and grant_row.revoked_at is null
  )
$$;

create or replace function public.wali_edge_take_rate_limit_v1(
  actor_id uuid, operation text, maximum integer, window_seconds integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  bucket_start timestamptz;
  bucket_count integer;
  retry_after integer;
  subject text;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if wali_edge_take_rate_limit_v1.operation !~ '^[a-z][a-z0-9_.]{2,95}$'
     or wali_edge_take_rate_limit_v1.maximum not between 1 and 10000
     or wali_edge_take_rate_limit_v1.window_seconds not between 1 and 86400 then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  subject := encode(extensions.digest(wali_edge_take_rate_limit_v1.actor_id::text, 'sha256'), 'hex');
  bucket_start := to_timestamp(floor(extract(epoch from statement_timestamp()) / wali_edge_take_rate_limit_v1.window_seconds) * wali_edge_take_rate_limit_v1.window_seconds);
  insert into wali.rate_limit_buckets (subject_hash, operation, window_start, window_seconds, counter, expires_at)
  values (subject, wali_edge_take_rate_limit_v1.operation, bucket_start, wali_edge_take_rate_limit_v1.window_seconds,
    1, bucket_start + make_interval(secs => wali_edge_take_rate_limit_v1.window_seconds))
  on conflict on constraint rate_limit_buckets_pkey do update set
    counter = wali.rate_limit_buckets.counter + 1,
    updated_at = statement_timestamp()
  returning counter into bucket_count;
  retry_after := greatest(1, ceil(extract(epoch from (bucket_start + make_interval(secs => wali_edge_take_rate_limit_v1.window_seconds) - statement_timestamp())))::integer);
  return jsonb_build_object('allowed', bucket_count <= wali_edge_take_rate_limit_v1.maximum, 'retry_after_seconds', retry_after);
end $$;

create or replace function public.wali_edge_request_install_v1(
  actor_id uuid, request_id uuid, idempotency_key text,
  wallpaper_id uuid, release_id uuid, expected_wallpaper_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  wallpaper_row wali.wallpapers%rowtype;
  release_row wali.wallpaper_releases%rowtype;
  request_hash text;
  replay jsonb;
  receipt_id uuid;
  expiry timestamptz;
  response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not exists (select 1 from wali.profiles p where p.id = actor_id and p.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  if expected_wallpaper_revision not between 0 and 9007199254740991
     or char_length(idempotency_key) not between 16 and 64 or idempotency_key !~ '^[A-Za-z0-9_-]+$' then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  request_hash := encode(extensions.digest(
    wallpaper_id::text || ':' || release_id::text || ':' || expected_wallpaper_revision::text,
    'sha256'
  ), 'hex');
  replay := wali.reserve_command(actor_id, 'request_install_edge', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select * into wallpaper_row from wali.wallpapers w where w.id = wallpaper_id and w.status = 'published' for share;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_WALLPAPER_NOT_FOUND'; end if;
  if wallpaper_row.revision <> expected_wallpaper_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if wallpaper_row.current_release_id <> release_id then raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_CURRENT'; end if;
  select * into release_row from wali.wallpaper_releases release
   where release.id = wali_edge_request_install_v1.release_id
     and release.wallpaper_id = wali_edge_request_install_v1.wallpaper_id
     and release.status = 'published';
  if not found or release_row.manifest_body is null or release_row.metadata_body is null
     or exists (select 1 from wali.catalog_revocations r where r.release_id = wali_edge_request_install_v1.release_id) then
    raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_AVAILABLE';
  end if;
  expiry := statement_timestamp() + interval '30 minutes';
  insert into wali.install_receipts (user_id, release_id, request_id, expires_at)
  values (actor_id, release_id, request_id, expiry) returning id into receipt_id;
  insert into wali.engagement_events (user_id, wallpaper_id, release_id, kind, client_request_id, coarse_source)
  values (actor_id, wallpaper_id, release_id, 'install_requested', request_id, 'macos');
  response := jsonb_build_object(
    'wallpaper_id', wallpaper_id, 'release_id', release_id,
    'manifest_body', translate(encode(release_row.manifest_body, 'base64'), E'+/=\n\r', '-_'),
    'metadata_body', translate(encode(release_row.metadata_body, 'base64'), E'+/=\n\r', '-_'),
    'signature', translate(encode(release_row.manifest_signature, 'base64'), E'+/=\n\r', '-_'),
    'key_id', release_row.signing_key_id, 'install_receipt', receipt_id::text,
    'expires_at', to_char(expiry at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
  perform wali.complete_command(actor_id, 'request_install_edge', idempotency_key, response);
  return response;
end $$;

create or replace function public.wali_edge_create_upload_v1(
  actor_id uuid, request_id uuid, idempotency_key text, declared_byte_count bigint,
  container_hint text, original_filename text, target_kind text,
  target_wallpaper_id uuid, expected_wallpaper_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  request_hash text;
  replay jsonb;
  session_row wali.upload_sessions%rowtype;
  terms_version text;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not wali.edge_actor_has_role(actor_id, 'creator') then raise exception using errcode = 'P0001', message = 'WALI_CREATOR_ROLE_REQUIRED'; end if;
  select creator_terms_version into terms_version from wali.runtime_configuration where singleton;
  if not exists (select 1 from wali.terms_acceptances t where t.user_id = actor_id and t.document_kind = 'creator_terms' and t.document_version = terms_version) then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_TERMS_REQUIRED';
  end if;
  if declared_byte_count not between 1 and 1073741824 or container_hint not in ('video/mp4', 'video/quicktime')
     or not wali.plain_text_is_valid(original_filename, 1, 255) or original_filename ~ '[/\\]'
     or target_kind not in ('new', 'wallpaper_update')
     or (target_kind = 'new') <> (target_wallpaper_id is null and expected_wallpaper_revision is null) then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  if target_kind = 'wallpaper_update' and not exists (
    select 1 from wali.wallpapers w where w.id = target_wallpaper_id and w.creator_id = actor_id and w.revision = expected_wallpaper_revision
  ) then raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_TARGET_INVALID'; end if;
  if (select count(*) from wali.submissions s where s.creator_id = actor_id and s.status in ('processing', 'submitted', 'under_review')) >= 2 then
    raise exception using errcode = 'P0001', message = 'WALI_PROCESSING_CAPACITY_UNAVAILABLE';
  end if;
  request_hash := encode(extensions.digest(
    declared_byte_count::text || ':' || container_hint || ':' || original_filename || ':' || target_kind || ':' ||
    coalesce(target_wallpaper_id::text, '') || ':' || coalesce(expected_wallpaper_revision::text, ''), 'sha256'
  ), 'hex');
  replay := wali.reserve_command(actor_id, 'create_upload', idempotency_key, request_hash);
  if replay is not null then
    select * into session_row from wali.upload_sessions where id = (replay ->> 'upload_session_id')::uuid;
    return replay || jsonb_build_object('revision', session_row.revision, 'upload_endpoint', session_row.upload_endpoint);
  end if;
  session_row.id := gen_random_uuid();
  insert into wali.upload_sessions (
    id, creator_id, storage_path, original_filename, declared_byte_count, declared_media_type,
    target_wallpaper_id, status, expires_at, idempotency_key
  ) values (
    session_row.id, actor_id, actor_id::text || '/' || session_row.id::text || '/source', original_filename,
    declared_byte_count, container_hint, target_wallpaper_id, 'issued', statement_timestamp() + interval '24 hours', idempotency_key
  ) returning * into session_row;
  replay := jsonb_build_object(
    'upload_session_id', session_row.id, 'storage_path', session_row.storage_path,
    'expires_at', to_char(session_row.expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'revision', session_row.revision, 'upload_endpoint', session_row.upload_endpoint
  );
  perform wali.complete_command(actor_id, 'create_upload', idempotency_key, replay);
  return replay;
end $$;

create or replace function public.wali_edge_bind_upload_endpoint_v1(
  actor_id uuid, upload_session_id uuid, expected_session_revision bigint, upload_endpoint text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare session_row wali.upload_sessions%rowtype;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  select * into session_row from wali.upload_sessions s where s.id = upload_session_id and s.creator_id = actor_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_TARGET_INVALID'; end if;
  if session_row.upload_endpoint = upload_endpoint then return jsonb_build_object('revision', session_row.revision); end if;
  if session_row.upload_endpoint is not null or session_row.revision <> expected_session_revision then
    raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH';
  end if;
  update wali.upload_sessions set upload_endpoint = wali_edge_bind_upload_endpoint_v1.upload_endpoint
   where id = session_row.id returning * into session_row;
  return jsonb_build_object('revision', session_row.revision);
end $$;

create or replace function public.wali_edge_complete_upload_v1(
  actor_id uuid, request_id uuid, idempotency_key text,
  upload_session_id uuid, expected_session_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  request_hash text; replay jsonb; session_row wali.upload_sessions%rowtype; object_row storage.objects%rowtype;
  submission_id uuid; wallpaper_id uuid; attempt_id uuid; observed_size bigint; observed_type text;
  category_id uuid; license_id uuid; actor_name text;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not wali.edge_actor_has_role(actor_id, 'creator') then raise exception using errcode = 'P0001', message = 'WALI_CREATOR_ROLE_REQUIRED'; end if;
  request_hash := encode(extensions.digest(upload_session_id::text || ':' || expected_session_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'complete_upload', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select * into session_row from wali.upload_sessions s where s.id = upload_session_id and s.creator_id = actor_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_TARGET_INVALID'; end if;
  if session_row.revision <> expected_session_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if session_row.status not in ('issued', 'uploading') then raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_ALREADY_BOUND'; end if;
  if session_row.expires_at <= statement_timestamp() then raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_EXPIRED'; end if;
  select * into object_row from storage.objects o
   where o.bucket_id = 'uploads-private' and o.name = session_row.storage_path
     and o.owner_id = actor_id::text and not coalesce(o.is_delete_marker, false) for share;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_INCOMPLETE'; end if;
  observed_size := coalesce((object_row.metadata ->> 'size')::bigint, 0);
  observed_type := coalesce(object_row.metadata ->> 'mimetype', object_row.metadata ->> 'contentType');
  if observed_size <> session_row.declared_byte_count or observed_type not in ('video/mp4', 'video/quicktime') then
    raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_CHANGED';
  end if;
  select c.id into category_id from wali.categories c where c.active order by c.sort_order, c.id limit 1;
  select l.id into license_id from wali.licenses l where l.active and l.redistribution_allowed order by l.code limit 1;
  select display_name into actor_name from wali.profiles where id = actor_id;
  wallpaper_id := coalesce(session_row.target_wallpaper_id, gen_random_uuid());
  if session_row.target_wallpaper_id is null then
    insert into wali.wallpapers (
      id, creator_id, slug, title, description, primary_category_id, license_id,
      rights_holder_display, status, visibility, content_rating
    ) values (
      wallpaper_id, actor_id, ('draft-' || replace(wallpaper_id::text, '-', ''))::extensions.citext,
      left(session_row.original_filename, 120), 'Complete the wallpaper description before submission.',
      category_id, license_id, actor_name, 'draft', 'public', 'everyone'
    );
  end if;
  submission_id := gen_random_uuid(); attempt_id := gen_random_uuid();
  insert into wali.submissions (
    id, creator_id, wallpaper_id, proposed_title, proposed_description, primary_category_id, license_id,
    rights_holder, upload_session_id, status, generation
  ) select submission_id, actor_id, wallpaper_id, w.title, w.description, w.primary_category_id, w.license_id,
      w.rights_holder_display, session_row.id, 'processing', 1 from wali.wallpapers w where w.id = wallpaper_id;
  update wali.upload_sessions set status = 'completed', received_byte_count = observed_size,
    detected_media_type = observed_type, storage_version = object_row.version, completed_at = statement_timestamp()
   where id = session_row.id;
  insert into wali.processing_attempts (id, submission_id, generation, status) values (attempt_id, submission_id, 1, 'queued');
  perform pgmq.send('wali_media_processing', jsonb_build_object(
    'schema_version', 1, 'attempt_id', attempt_id, 'submission_id', submission_id, 'generation', 1,
    'input', jsonb_build_object('bucket', 'uploads-private', 'path', session_row.storage_path,
      'byte_count', observed_size, 'storage_version', object_row.version),
    'policy_digest', (select media_policy_digest from wali.runtime_configuration where singleton),
    'expected_artifact_roles', jsonb_build_array('thumbnail', 'poster', 'preview', 'video_default'),
    'deadline_at', to_char(statement_timestamp() + interval '20 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ));
  replay := jsonb_build_object(
    'submission_id', submission_id, 'revision', 1, 'generation', 1, 'state', 'processing',
    'processing_status_key', submission_id::text || ':1'
  );
  perform wali.complete_command(actor_id, 'complete_upload', idempotency_key, replay);
  return replay;
end $$;

create or replace function public.wali_edge_accept_creator_terms_v1(
  actor_id uuid, request_id uuid, idempotency_key text, creator_terms_version text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; current_version text; latest_revision bigint;
  grant_row wali.role_grants%rowtype; response jsonb; enrolled boolean := false;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not exists (select 1 from wali.profiles p where p.id = actor_id and p.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  select cfg.creator_terms_version into current_version from wali.runtime_configuration cfg where cfg.singleton;
  if creator_terms_version is distinct from current_version then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_TERMS_REQUIRED';
  end if;
  request_hash := encode(extensions.digest(actor_id::text || ':' || creator_terms_version, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'accept_creator_terms', idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  insert into wali.terms_acceptances (user_id, document_kind, document_version, request_id)
  values (actor_id, 'creator_terms', creator_terms_version, request_id)
  on conflict (user_id, document_kind, document_version) do nothing;
  insert into wali.creator_profiles (user_id) values (actor_id) on conflict (user_id) do nothing;

  select * into grant_row from wali.role_grants role_grant
   where role_grant.user_id = actor_id and role_grant.role = 'creator' and role_grant.revoked_at is null
   for update;
  if not found then
    select coalesce(max(role_grant.revision), 0) + 1 into latest_revision
      from wali.role_grants role_grant where role_grant.user_id = actor_id and role_grant.role = 'creator';
    insert into wali.role_grants (user_id, role, granted_by, reason, revision)
    values (actor_id, 'creator', actor_id, 'creator_terms_self_enrollment', latest_revision)
    returning * into grant_row;
    enrolled := true;
    insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
    values (actor_id, 'creator.self_enrolled', 'account', actor_id, request_id,
      jsonb_build_object('terms_version', creator_terms_version, 'grant_revision', grant_row.revision));
  end if;
  response := jsonb_build_object(
    'account_is_active', true, 'creator_enrolled', true, 'creator_grant_revision', grant_row.revision,
    'accepted_creator_terms_version', creator_terms_version, 'current_creator_terms_version', current_version,
    'newly_enrolled', enrolled
  );
  perform wali.complete_command(actor_id, 'accept_creator_terms', idempotency_key, response);
  return response;
end $$;

create or replace function public.creator_authorization_v1()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor_id uuid := auth.uid(); profile_status wali.account_status; current_terms text;
  accepted_terms text; creator_revision bigint; moderator_revision bigint; session_expiry timestamptz;
begin
  if actor_id is null then raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED'; end if;
  select p.status into profile_status from wali.profiles p where p.id = actor_id;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED'; end if;
  select cfg.creator_terms_version into current_terms from wali.runtime_configuration cfg where cfg.singleton;
  select t.document_version into accepted_terms from wali.terms_acceptances t
   where t.user_id = actor_id and t.document_kind = 'creator_terms' and t.document_version = current_terms;
  select max(role_grant.revision) into creator_revision from wali.role_grants role_grant
   where role_grant.user_id = actor_id and role_grant.role = 'creator' and role_grant.revoked_at is null;
  select max(role_grant.revision) into moderator_revision from wali.role_grants role_grant
   where role_grant.user_id = actor_id and role_grant.role in ('moderator', 'admin') and role_grant.revoked_at is null;
  begin
    session_expiry := to_timestamp((auth.jwt() ->> 'exp')::double precision);
  exception when others then
    session_expiry := statement_timestamp();
  end;
  return jsonb_build_object(
    'account_is_active', profile_status = 'active',
    'session_expires_at', to_char(session_expiry at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'creator_grant_revision', creator_revision,
    'accepted_creator_terms_version', accepted_terms,
    'current_creator_terms_version', current_terms,
    'moderator_grant_revision', moderator_revision,
    'assurance_level', case when wali.current_aal() = 'aal2' then 'aal2' else 'aal1' end
  );
end $$;

create or replace function public.wali_edge_save_submission_draft_v1(
  actor_id uuid, request_id uuid, idempotency_key text, submission_id uuid, expected_revision bigint,
  title text, description text, primary_category_id uuid, suggested_tag_ids uuid[], content_warning text,
  rights_basis wali.rights_basis, rights_holder text, license_id uuid, source_url text,
  attribution_text text, proof_object_ids uuid[], attests_rights boolean, creator_terms_version text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; current_row wali.submissions%rowtype; target_status wali.submission_status;
  license_row wali.licenses%rowtype; response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not wali.edge_actor_has_role(actor_id, 'creator') then raise exception using errcode = 'P0001', message = 'WALI_CREATOR_ROLE_REQUIRED'; end if;
  -- Licensed/other declarations stay closed until every proof object is issued,
  -- scanned, observed and bound to this submission. UUIDs alone are not proof.
  if rights_basis in ('licensed', 'other') or cardinality(proof_object_ids) <> 0 then
    raise exception using errcode = 'P0001', message = 'WALI_RIGHTS_WORKFLOW_UNAVAILABLE';
  end if;
  if creator_terms_version is distinct from (select cfg.creator_terms_version from wali.runtime_configuration cfg where cfg.singleton)
     or not exists (select 1 from wali.terms_acceptances t where t.user_id = actor_id and t.document_kind = 'creator_terms' and t.document_version = creator_terms_version) then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_TERMS_REQUIRED';
  end if;
  select * into license_row from wali.licenses license where license.id = license_id and license.active;
  if not found or not attests_rights or not wali.plain_text_is_valid(title, 1, 120)
     or not wali.plain_text_is_valid(description, 1, 2000)
     or not wali.plain_text_is_valid(rights_holder, 1, 160)
     or (content_warning is not null and not wali.plain_text_is_valid(content_warning, 1, 500))
     or (attribution_text is not null and not wali.plain_text_is_valid(attribution_text, 1, 1000))
     or not wali.https_url_is_valid(source_url)
     or not exists (select 1 from wali.categories c where c.id = primary_category_id and c.active)
     or cardinality(suggested_tag_ids) not between 0 and 20
     or cardinality(suggested_tag_ids) <> (select count(distinct tag_id) from unnest(suggested_tag_ids) tag_id)
     or exists (select 1 from unnest(suggested_tag_ids) tag_id where not exists (select 1 from wali.tags t where t.id = tag_id and t.active))
     or (license_row.attribution_required and attribution_text is null)
     or (rights_basis in ('licensed', 'public_domain') and source_url is null)
     then
    raise exception using errcode = 'P0001', message = 'WALI_RIGHTS_INCOMPLETE';
  end if;
  request_hash := encode(extensions.digest(jsonb_build_object(
    'submission_id', submission_id, 'expected_revision', expected_revision, 'title', title,
    'description', description, 'primary_category_id', primary_category_id,
    'suggested_tag_ids', suggested_tag_ids, 'content_warning', content_warning,
    'rights_basis', rights_basis, 'rights_holder', rights_holder, 'license_id', license_id,
    'source_url', source_url, 'attribution_text', attribution_text, 'proof_object_ids', proof_object_ids,
    'attests_rights', attests_rights, 'creator_terms_version', creator_terms_version
  )::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'save_submission_draft', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select * into current_row from wali.submissions s where s.id = submission_id and s.creator_id = actor_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_FOUND'; end if;
  if current_row.revision <> expected_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if current_row.status not in ('draft', 'ready_for_submission', 'changes_requested') then
    raise exception using errcode = 'P0001', message = 'WALI_INVALID_TRANSITION';
  end if;
  target_status := case when current_row.status = 'changes_requested' then 'draft'::wali.submission_status else current_row.status end;
  update wali.submissions set proposed_title = wali_edge_save_submission_draft_v1.title,
    proposed_description = wali_edge_save_submission_draft_v1.description,
    primary_category_id = wali_edge_save_submission_draft_v1.primary_category_id,
    license_id = wali_edge_save_submission_draft_v1.license_id,
    rights_holder = wali_edge_save_submission_draft_v1.rights_holder,
    attribution_text = wali_edge_save_submission_draft_v1.attribution_text,
    source_url = wali_edge_save_submission_draft_v1.source_url,
    content_warning = wali_edge_save_submission_draft_v1.content_warning,
    status = target_status where id = current_row.id returning * into current_row;
  insert into wali.rights_declarations (submission_id, basis, rights_holder, license_id, source_url,
    attribution_text, proof_object_ids, attested_at, creator_terms_version)
  values (current_row.id, rights_basis, rights_holder, license_id, source_url, attribution_text,
    proof_object_ids, statement_timestamp(), creator_terms_version)
  on conflict on constraint rights_declarations_submission_id_key do update set basis = excluded.basis, rights_holder = excluded.rights_holder,
    license_id = excluded.license_id, source_url = excluded.source_url, attribution_text = excluded.attribution_text,
    proof_object_ids = excluded.proof_object_ids, attested_at = excluded.attested_at,
    creator_terms_version = excluded.creator_terms_version, review_status = 'pending',
    reviewed_by = null, reviewed_at = null;
  delete from wali.submission_tag_suggestions suggestion
   where suggestion.submission_id = current_row.id and suggestion.source = 'creator';
  insert into wali.submission_tag_suggestions (submission_id, tag_id, source)
  select current_row.id, tag_id, 'creator'::wali.taxonomy_source from unnest(suggested_tag_ids) tag_id;
  response := jsonb_build_object('submission_id', current_row.id, 'revision', current_row.revision,
    'generation', current_row.generation, 'state', current_row.status, 'field_errors', '[]'::jsonb);
  perform wali.complete_command(actor_id, 'save_submission_draft', idempotency_key, response);
  return response;
end $$;

create or replace function public.wali_edge_withdraw_submission_v1(
  actor_id uuid, request_id uuid, idempotency_key text, submission_id uuid, expected_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; current_row wali.submissions%rowtype; response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not wali.edge_actor_has_role(actor_id, 'creator') then raise exception using errcode = 'P0001', message = 'WALI_CREATOR_ROLE_REQUIRED'; end if;
  request_hash := encode(extensions.digest(submission_id::text || ':' || expected_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'withdraw_submission', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select * into current_row from wali.submissions s where s.id = submission_id and s.creator_id = actor_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_FOUND'; end if;
  if current_row.revision <> expected_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if current_row.status not in ('draft', 'uploading', 'uploaded', 'processing', 'processing_failed',
    'ready_for_submission', 'submitted', 'under_review', 'changes_requested') then
    raise exception using errcode = 'P0001', message = 'WALI_INVALID_TRANSITION';
  end if;
  update wali.submissions set status = 'withdrawn' where id = current_row.id returning * into current_row;
  update wali.processing_attempts set status = 'failed', safe_error_code = 'WALI_WITHDRAWN',
    finished_at = statement_timestamp(), lease_owner = null, lease_expires_at = null
    where wali.processing_attempts.submission_id = current_row.id
      and wali.processing_attempts.status not in ('completed', 'failed', 'timed_out');
  response := jsonb_build_object('submission_id', current_row.id, 'revision', current_row.revision,
    'generation', current_row.generation, 'state', current_row.status, 'field_errors', '[]'::jsonb);
  perform wali.complete_command(actor_id, 'withdraw_submission', idempotency_key, response);
  return response;
end $$;

create or replace function public.wali_edge_submit_wallpaper_v1(
  actor_id uuid, request_id uuid, idempotency_key text, submission_id uuid,
  expected_revision bigint, expected_generation bigint, creator_terms_version text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; current_row wali.submissions%rowtype; response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not wali.edge_actor_has_role(actor_id, 'creator') then raise exception using errcode = 'P0001', message = 'WALI_CREATOR_ROLE_REQUIRED'; end if;
  if wali_edge_submit_wallpaper_v1.creator_terms_version is distinct from
       (select cfg.creator_terms_version from wali.runtime_configuration cfg where cfg.singleton)
     or not exists (select 1 from wali.terms_acceptances t
       where t.user_id = wali_edge_submit_wallpaper_v1.actor_id and t.document_kind = 'creator_terms'
         and t.document_version = wali_edge_submit_wallpaper_v1.creator_terms_version) then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_TERMS_REQUIRED';
  end if;
  request_hash := encode(extensions.digest(submission_id::text || ':' || expected_revision::text || ':' || expected_generation::text || ':' || creator_terms_version, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'submit_wallpaper_edge', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select * into current_row from wali.submissions s where s.id = submission_id and s.creator_id = actor_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_FOUND'; end if;
  if current_row.revision <> expected_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if current_row.generation <> expected_generation then raise exception using errcode = 'P0001', message = 'WALI_STALE_PROCESSING_GENERATION'; end if;
  if current_row.status <> 'ready_for_submission' or not exists (
    select 1 from wali.processing_attempts p where p.submission_id = current_row.id and p.generation = current_row.generation and p.status = 'completed'
  ) or not exists (
    select 1 from wali.rights_declarations r where r.submission_id = current_row.id
      and r.creator_terms_version = wali_edge_submit_wallpaper_v1.creator_terms_version
  ) then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_READY'; end if;
  update wali.submissions set status = 'submitted', submitted_at = statement_timestamp() where id = current_row.id
  returning jsonb_build_object('submission_id', id, 'revision', revision, 'generation', generation, 'state', status) into response;
  perform wali.complete_command(actor_id, 'submit_wallpaper_edge', idempotency_key, response);
  return response;
end $$;

create or replace function public.wali_edge_moderate_submission_v1(
  actor_id uuid, actor_aal text, request_id uuid, idempotency_key text,
  submission_id uuid, expected_revision bigint, expected_generation bigint,
  decision wali.review_decision, checklist_revision integer, reason_codes text[],
  creator_note text, private_note text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; current_row wali.submissions%rowtype; mapped wali.submission_status; response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if actor_aal <> 'aal2' or not (wali.edge_actor_has_role(actor_id, 'moderator') or wali.edge_actor_has_role(actor_id, 'admin')) then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATOR_AAL2_REQUIRED';
  end if;
  if checklist_revision <> 1 or cardinality(reason_codes) not between 1 and 20
     or not wali.plain_text_is_valid(creator_note, 1, 2000)
     or (private_note is not null and not wali.plain_text_is_valid(private_note, 1, 4000))
     or exists (select 1 from unnest(reason_codes) reason_code where not (
       (reason_code = 'policy_pass' and decision = 'approved')
       or (reason_code in ('rights_incomplete', 'technical_quality', 'duplicate_content')
         and decision in ('changes_requested', 'rejected'))
       or (reason_code = 'metadata_inaccurate' and decision = 'changes_requested')
       or (reason_code = 'unsafe_content' and decision = 'rejected')
     )) then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATION_INPUT_INVALID';
  end if;
  request_hash := encode(extensions.digest(submission_id::text || ':' || expected_revision::text || ':' || expected_generation::text || ':' ||
    decision::text || ':' || checklist_revision::text || ':' || array_to_string(reason_codes, ',') || ':' || creator_note || ':' || coalesce(private_note, ''), 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'moderate_submission_edge', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select * into current_row from wali.submissions s where s.id = submission_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_FOUND'; end if;
  if current_row.creator_id = actor_id then raise exception using errcode = 'P0001', message = 'WALI_SELF_REVIEW_FORBIDDEN'; end if;
  if current_row.revision <> expected_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if current_row.generation <> expected_generation then raise exception using errcode = 'P0001', message = 'WALI_STALE_PROCESSING_GENERATION'; end if;
  if current_row.status not in ('submitted', 'under_review') then raise exception using errcode = 'P0001', message = 'WALI_INVALID_TRANSITION'; end if;
  if decision = 'approved' and not exists (
    select 1 from wali.processing_attempts p where p.submission_id = current_row.id and p.generation = current_row.generation and p.status = 'completed'
  ) then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_READY'; end if;
  mapped := case decision when 'approved' then 'approved'::wali.submission_status when 'changes_requested' then 'changes_requested'::wali.submission_status else 'rejected'::wali.submission_status end;
  insert into wali.moderation_reviews (submission_id, moderator_id, decision, public_note, private_note, checklist_revision, reason_codes, request_id)
  values (current_row.id, actor_id, decision, creator_note, private_note, checklist_revision, reason_codes, request_id);
  insert into wali.moderation_actions (actor_id, action, target_type, target_id, reason_code, request_id, metadata)
  values (actor_id, 'submission.' || decision::text, 'submission', current_row.id, reason_codes[1], request_id,
    jsonb_build_object('generation', current_row.generation, 'revision', current_row.revision));
  insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
  values (actor_id, 'moderation.submission.' || decision::text, 'submission', current_row.id, request_id,
    jsonb_build_object('generation', current_row.generation, 'revision', current_row.revision));
  update wali.submissions set status = mapped,
    decided_at = case when mapped in ('approved', 'rejected') then statement_timestamp() else null end where id = current_row.id
  returning jsonb_build_object('submission_id', id, 'revision', revision, 'generation', generation,
    'state', status, 'decision', decision) into response;
  if decision = 'approved' then
    update wali.rights_declarations rights set review_status = 'approved',
      reviewed_by = wali_edge_moderate_submission_v1.actor_id, reviewed_at = statement_timestamp()
      where rights.submission_id = current_row.id and rights.review_status = 'pending';
    update wali.wallpaper_releases set status = 'approved'
      where source_submission_id = current_row.id and status in ('processing', 'review');
  end if;
  perform wali.complete_command(actor_id, 'moderate_submission_edge', idempotency_key, response);
  return response;
end $$;

create or replace function public.wali_edge_report_wallpaper_v1(
  actor_id uuid, request_id uuid, idempotency_key text, wallpaper_id uuid,
  release_id uuid, report_kind wali.report_kind, detail text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; report_row wali.reports%rowtype; response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not exists (select 1 from wali.profiles p where p.id = actor_id and p.status = 'active') then raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE'; end if;
  if not wali.plain_text_is_valid(detail, 1, 2000) or not exists (
    select 1 from wali.wallpapers w where w.id = wali_edge_report_wallpaper_v1.wallpaper_id and w.status = 'published'
  ) or (wali_edge_report_wallpaper_v1.release_id is not null and not exists (
    select 1 from wali.wallpaper_releases r where r.id = wali_edge_report_wallpaper_v1.release_id
      and r.wallpaper_id = wali_edge_report_wallpaper_v1.wallpaper_id
  )) then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  request_hash := encode(extensions.digest(wallpaper_id::text || ':' || coalesce(release_id::text, '') || ':' || report_kind::text || ':' || detail, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'report_wallpaper', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  insert into wali.reports (reporter_id, wallpaper_id, release_id, kind, detail)
  values (actor_id, wallpaper_id, release_id, report_kind, detail) returning * into report_row;
  insert into wali.engagement_events (user_id, wallpaper_id, release_id, kind, client_request_id, coarse_source)
  values (actor_id, wallpaper_id, release_id, 'report_submitted', request_id, 'macos');
  response := jsonb_build_object('report_id', report_row.id, 'status', report_row.status,
    'created_at', to_char(report_row.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  perform wali.complete_command(actor_id, 'report_wallpaper', idempotency_key, response); return response;
end $$;

create or replace function public.wali_edge_request_account_export_v1(
  actor_id uuid, request_id uuid, idempotency_key text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; export_row wali.account_exports%rowtype; response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not exists (select 1 from wali.profiles p where p.id = actor_id and p.status in ('active', 'deletion_pending')) then raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE'; end if;
  request_hash := encode(extensions.digest(actor_id::text || ':export', 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'account_export', idempotency_key, request_hash); if replay is not null then return replay; end if;
  export_row.id := gen_random_uuid();
  insert into wali.account_exports (id, user_id, storage_path, status, expires_at)
  values (export_row.id, actor_id, 'exports/' || actor_id::text || '/' || export_row.id::text || '/account.json', 'queued', statement_timestamp() + interval '7 days')
  returning * into export_row;
  perform pgmq.send('wali_exports', jsonb_build_object('schema_version', 1, 'export_id', export_row.id, 'user_id', actor_id));
  response := jsonb_build_object('export_id', export_row.id, 'status', export_row.status,
    'expires_at', to_char(export_row.expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  perform wali.complete_command(actor_id, 'account_export', idempotency_key, response); return response;
end $$;

create or replace function public.wali_edge_request_account_deletion_v1(
  actor_id uuid, request_id uuid, idempotency_key text, expected_profile_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; profile_row wali.profiles%rowtype; response jsonb; deletion_id uuid;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  request_hash := encode(extensions.digest(actor_id::text || ':' || expected_profile_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'account_deletion', idempotency_key, request_hash); if replay is not null then return replay; end if;
  select * into profile_row from wali.profiles p where p.id = actor_id for update;
  if not found or profile_row.status <> 'active' then raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE'; end if;
  if profile_row.revision <> expected_profile_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  insert into wali.account_deletion_requests (user_id, request_id) values (actor_id, request_id)
  returning id into deletion_id;
  perform pgmq.send('wali_account_deletions', jsonb_build_object(
    'schema_version', 1, 'deletion_id', deletion_id, 'user_id', actor_id
  ));
  update wali.profiles set status = 'deletion_pending' where id = actor_id returning * into profile_row;
  update wali.role_grants set revoked_by = actor_id, revoked_at = statement_timestamp(), reason = 'account deletion requested'
   where user_id = actor_id and revoked_at is null;
  response := jsonb_build_object('deletion_id', deletion_id, 'status', profile_row.status, 'revision', profile_row.revision,
    'requested_at', to_char(statement_timestamp() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  perform wali.complete_command(actor_id, 'account_deletion', idempotency_key, response); return response;
end $$;

create or replace function public.wali_edge_account_export_status_v1(
  actor_id uuid, export_id uuid
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare export_row wali.account_exports%rowtype;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  select * into export_row from wali.account_exports export
   where export.id = wali_edge_account_export_status_v1.export_id
     and export.user_id = wali_edge_account_export_status_v1.actor_id;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_EXPORT_NOT_FOUND'; end if;
  return jsonb_build_object(
    'export_id', export_row.id,
    'status', case when export_row.expires_at <= statement_timestamp() then 'expired' else export_row.status end,
    'expires_at', to_char(export_row.expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'completed_at', case when export_row.completed_at is null then null
      else to_char(export_row.completed_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') end,
    'byte_count', case when export_row.status = 'ready' and export_row.expires_at > statement_timestamp()
      then export_row.byte_count else null end,
    'digest', case when export_row.status = 'ready' and export_row.expires_at > statement_timestamp()
      then export_row.digest else null end,
    'download_path', case when export_row.status = 'ready' and export_row.expires_at > statement_timestamp()
      then export_row.storage_path else null end
  );
end $$;

create or replace function public.wali_edge_mark_account_deletion_sessions_revoked_v1(
  actor_id uuid, deletion_id uuid, provider_operation_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare deletion wali.account_deletion_requests%rowtype;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  select * into deletion from wali.account_deletion_requests request
   where request.id = wali_edge_mark_account_deletion_sessions_revoked_v1.deletion_id
     and request.user_id = wali_edge_mark_account_deletion_sessions_revoked_v1.actor_id
   for update;
  if not found or deletion.status in ('cancelled', 'failed') then
    raise exception using errcode = 'P0001', message = 'WALI_DELETION_NOT_FOUND';
  end if;
  if deletion.sessions_revoked_at is null then
    -- Revocation and its durable checkpoint share this transaction. Deleting a
    -- GoTrue session cascades to its refresh-token family; extant access JWTs
    -- are separately contained by the profile status checks on every command.
    delete from auth.sessions session
     where session.user_id = wali_edge_mark_account_deletion_sessions_revoked_v1.actor_id;
    update wali.account_deletion_requests request set
      auth_identity_status = 'sessions_revoked',
      sessions_revoked_at = statement_timestamp(),
      session_revocation_operation_id = provider_operation_id,
      revision = request.revision + 1
    where request.id = deletion.id returning * into deletion;
    insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
    values (actor_id, 'account.sessions_revoked', 'account', actor_id, provider_operation_id,
      jsonb_build_object('deletion_id', deletion.id, 'provider', 'supabase_auth_sessions'));
  end if;
  return jsonb_build_object(
    'deletion_id', deletion.id, 'status', 'deletion_pending', 'processing_status', deletion.status,
    'auth_identity_status', deletion.auth_identity_status, 'revision', deletion.revision,
    'requested_at', to_char(deletion.requested_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
end $$;

create or replace function public.wali_edge_account_deletion_status_v1(
  actor_id uuid, deletion_id uuid
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare deletion wali.account_deletion_requests%rowtype;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  select * into deletion from wali.account_deletion_requests request
   where request.id = wali_edge_account_deletion_status_v1.deletion_id
     and request.user_id = wali_edge_account_deletion_status_v1.actor_id;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_DELETION_NOT_FOUND'; end if;
  return jsonb_build_object(
    'deletion_id', deletion.id, 'status', deletion.status,
    'auth_identity_status', deletion.auth_identity_status, 'revision', deletion.revision,
    'requested_at', to_char(deletion.requested_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'completed_at', case when deletion.completed_at is null then null
      else to_char(deletion.completed_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') end,
    'held', deletion.status = 'held'
  );
end $$;

create or replace function public.wali_edge_prepare_account_identity_deletion_v1(
  actor_id uuid, actor_aal text, deletion_id uuid, expected_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare deletion wali.account_deletion_requests%rowtype;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if actor_aal <> 'aal2' or not wali.edge_actor_has_role(actor_id, 'admin') then
    raise exception using errcode = 'P0001', message = 'WALI_ADMIN_AAL2_REQUIRED';
  end if;
  select * into deletion from wali.account_deletion_requests request
   where request.id = wali_edge_prepare_account_identity_deletion_v1.deletion_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_DELETION_NOT_FOUND'; end if;
  if deletion.status = 'completed' and deletion.auth_identity_status = 'completed' then
    return jsonb_build_object('completed', true, 'deletion_id', deletion.id,
      'user_id', deletion.user_id, 'revision', deletion.revision);
  end if;
  if deletion.revision <> expected_revision then
    raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH';
  end if;
  if deletion.status <> 'awaiting_auth_cleanup'
     or deletion.auth_identity_status <> 'operator_cleanup_required'
     or deletion.sessions_revoked_at is null then
    raise exception using errcode = 'P0001', message = 'WALI_DELETION_NOT_READY';
  end if;
  return jsonb_build_object('completed', false, 'deletion_id', deletion.id,
    'user_id', deletion.user_id, 'revision', deletion.revision);
end $$;

create or replace function public.wali_edge_finalize_account_identity_deletion_v1(
  actor_id uuid, actor_aal text, request_id uuid, deletion_id uuid,
  expected_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare deletion wali.account_deletion_requests%rowtype; result jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if actor_aal <> 'aal2' or not wali.edge_actor_has_role(actor_id, 'admin') then
    raise exception using errcode = 'P0001', message = 'WALI_ADMIN_AAL2_REQUIRED';
  end if;
  select * into deletion from wali.account_deletion_requests request
   where request.id = wali_edge_finalize_account_identity_deletion_v1.deletion_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_DELETION_NOT_FOUND'; end if;
  if deletion.status = 'completed' and deletion.auth_identity_status = 'completed' then
    return jsonb_build_object('deletion_id', deletion.id, 'status', deletion.status,
      'auth_identity_status', deletion.auth_identity_status, 'revision', deletion.revision,
      'completed_at', to_char(deletion.completed_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  end if;
  if deletion.revision <> expected_revision then
    raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH';
  end if;
  if deletion.status <> 'awaiting_auth_cleanup'
     or deletion.auth_identity_status <> 'operator_cleanup_required'
     or deletion.sessions_revoked_at is null then
    raise exception using errcode = 'P0001', message = 'WALI_DELETION_NOT_READY';
  end if;
  update wali.account_deletion_requests request set
    status = 'completed', auth_identity_status = 'completed',
    identity_deleted_at = statement_timestamp(),
    identity_deletion_operation_id = wali_edge_finalize_account_identity_deletion_v1.request_id,
    completed_at = statement_timestamp(), revision = request.revision + 1
   where request.id = deletion.id returning * into deletion;
  insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
  values (actor_id, 'account.auth_identity_soft_deleted', 'account', deletion.user_id, request_id,
    jsonb_build_object('deletion_id', deletion.id, 'provider', 'supabase_auth', 'soft_delete', true));
  result := jsonb_build_object('deletion_id', deletion.id, 'status', deletion.status,
    'auth_identity_status', deletion.auth_identity_status, 'revision', deletion.revision,
    'completed_at', to_char(deletion.completed_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  return result;
end $$;

create or replace function public.wali_edge_admin_role_grant_v1(
  actor_id uuid, actor_aal text, request_id uuid, idempotency_key text,
  target_user_id uuid, target_role wali.role_name, desired_active boolean,
  reason_code text, reason_text text, expected_role_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; latest wali.role_grants%rowtype; next_revision bigint; response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if actor_aal <> 'aal2' or not wali.edge_actor_has_role(actor_id, 'admin') then raise exception using errcode = 'P0001', message = 'WALI_ADMIN_AAL2_REQUIRED'; end if;
  if reason_code !~ '^[a-z][a-z0-9_.-]{2,95}$' or (reason_text is not null and not wali.plain_text_is_valid(reason_text, 1, 500))
     or not exists (select 1 from wali.profiles p where p.id = target_user_id and p.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  request_hash := encode(extensions.digest(target_user_id::text || ':' || target_role::text || ':' || desired_active::text || ':' ||
    reason_code || ':' || coalesce(reason_text, '') || ':' || expected_role_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'admin_role_grant', idempotency_key, request_hash); if replay is not null then return replay; end if;
  select * into latest from wali.role_grants r where r.user_id = target_user_id and r.role = target_role order by r.revision desc limit 1 for update;
  if coalesce(latest.revision, 0) <> expected_role_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if target_role = 'admin' and not desired_active and latest.revoked_at is null and
     (select count(*) from wali.role_grants r where r.role = 'admin' and r.revoked_at is null) <= 1 then
    raise exception using errcode = 'P0001', message = 'WALI_LAST_ADMIN_REQUIRED'; end if;
  next_revision := coalesce(latest.revision, 0);
  if desired_active and (latest.id is null or latest.revoked_at is not null) then
    next_revision := next_revision + 1;
    insert into wali.role_grants (user_id, role, granted_by, reason, revision)
    values (target_user_id, target_role, actor_id, coalesce(reason_text, reason_code), next_revision);
  elsif not desired_active and latest.id is not null and latest.revoked_at is null then
    next_revision := latest.revision + 1;
    update wali.role_grants set revoked_by = actor_id, revoked_at = statement_timestamp(),
      reason = coalesce(reason_text, reason_code), revision = next_revision where id = latest.id;
  end if;
  insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
  values (actor_id, case when desired_active then 'role.granted' else 'role.revoked' end, 'account', target_user_id, request_id,
    jsonb_build_object('role', target_role, 'reason_code', reason_code, 'revision', next_revision));
  response := jsonb_build_object('target_user_id', target_user_id, 'role', target_role, 'active', desired_active,
    'revision', next_revision, 'updated_at', to_char(statement_timestamp() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  perform wali.complete_command(actor_id, 'admin_role_grant', idempotency_key, response); return response;
end $$;

-- The first insert wins without surfacing a raw unique violation. The locked
-- row then provides deterministic in-progress, conflict, or replay behavior.
create or replace function wali.reserve_command(
  command_actor uuid, command_operation text, command_key text, command_digest text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare existing wali.command_idempotency%rowtype; inserted_count integer;
begin
  insert into wali.command_idempotency (actor_id, operation, idempotency_key, request_digest)
  values (command_actor, command_operation, command_key, command_digest)
  on conflict (actor_id, operation, idempotency_key) do nothing;
  get diagnostics inserted_count = row_count;
  if inserted_count = 1 then return null; end if;
  select * into strict existing from wali.command_idempotency
   where actor_id = command_actor and operation = command_operation and idempotency_key = command_key
   for update;
  if existing.request_digest <> command_digest then
    raise exception using errcode = 'P0001', message = 'WALI_IDEMPOTENCY_CONFLICT';
  end if;
  if existing.status = 'completed' then
    return existing.response || jsonb_build_object('replayed', true);
  end if;
  raise exception using errcode = 'P0001', message = 'WALI_COMMAND_IN_PROGRESS';
end $$;

create or replace function wali.complete_command(
  command_actor uuid, command_operation text, command_key text, command_response jsonb
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if jsonb_typeof(command_response) <> 'object' or octet_length(command_response::text) > 32768 then
    raise exception using errcode = 'P0001', message = 'WALI_COMMAND_RESPONSE_INVALID';
  end if;
  update wali.command_idempotency set status = 'completed', response = command_response,
    completed_at = statement_timestamp()
   where actor_id = command_actor and operation = command_operation and idempotency_key = command_key
     and status = 'in_progress';
  if not found then raise exception using errcode = 'P0001', message = 'WALI_COMMAND_STATE_INVALID'; end if;
end $$;

create or replace function wali.worker_caller_authorized()
returns boolean language sql stable security invoker set search_path = '' as $$
  select auth.role() = 'service_role'
    or (session_user <> 'authenticator' and pg_has_role(session_user, 'wali_worker', 'member'))
$$;

create or replace function wali.worker_queue_allowed(queue_name text)
returns boolean language sql immutable security invoker set search_path = '' as $$
  select queue_name in ('wali_media_processing', 'wali_promotions', 'wali_exports',
    'wali_cleanup', 'wali_backup_verification', 'wali_account_deletions')
$$;

create or replace function wali.worker_queue_read(queue_name text, visibility_seconds integer)
returns table (msg_id bigint, message jsonb, vt timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.worker_queue_allowed(queue_name) or visibility_seconds not between 30 and 1800 then
    raise exception using errcode = 'P0001', message = 'WALI_QUEUE_NOT_ALLOWED';
  end if;
  return query select q.msg_id, q.message, q.vt from pgmq.read(queue_name, visibility_seconds, 1) q;
end $$;

create or replace function wali.worker_queue_ack(queue_name text, message_id bigint)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.worker_queue_allowed(queue_name) or message_id <= 0 then raise exception using errcode = 'P0001', message = 'WALI_QUEUE_NOT_ALLOWED'; end if;
  return pgmq.delete(queue_name, message_id);
end $$;

create or replace function wali.worker_queue_nack(queue_name text, message_id bigint, delay_seconds integer)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.worker_queue_allowed(queue_name) or message_id <= 0 or delay_seconds not between 1 and 900 then
    raise exception using errcode = 'P0001', message = 'WALI_QUEUE_NOT_ALLOWED';
  end if;
  perform pgmq.set_vt(queue_name, message_id, delay_seconds);
  return true;
end $$;

create or replace function wali.worker_queue_reject(queue_name text, message_id bigint)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.worker_queue_allowed(queue_name) or message_id <= 0 then raise exception using errcode = 'P0001', message = 'WALI_QUEUE_NOT_ALLOWED'; end if;
  return pgmq.archive(queue_name, message_id);
end $$;

create or replace function wali.worker_enqueue_cleanup(scratch_path text, reason text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if scratch_path !~ '^scratch/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     or reason not in ('remove_completed', 'remove_failed', 'remove_rejected') then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  perform pgmq.send('wali_cleanup', jsonb_build_object('schema_version', 1,
    'operation', 'delete_scratch', 'storage_path', scratch_path, 'reason', reason));
  return true;
end $$;

create or replace function wali.worker_begin_attempt(
  target_attempt_id uuid, target_submission_id uuid, expected_generation integer,
  worker_identity text, lease_until timestamptz
) returns text language plpgsql security definer set search_path = '' as $$
declare attempt_row wali.processing_attempts%rowtype; submission_row wali.submissions%rowtype;
  upload_row wali.upload_sessions%rowtype; object_row storage.objects%rowtype; object_size bigint;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.plain_text_is_valid(worker_identity, 1, 128)
     or lease_until <= statement_timestamp() or lease_until > statement_timestamp() + interval '5 minutes' then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_LEASE_INVALID';
  end if;
  select * into attempt_row from wali.processing_attempts p where p.id = target_attempt_id for update;
  if not found or attempt_row.submission_id <> target_submission_id or attempt_row.generation <> expected_generation then return 'stale'; end if;
  if attempt_row.status = 'completed' then return 'completed'; end if;
  select * into submission_row from wali.submissions s where s.id = target_submission_id for update;
  if not found or submission_row.generation <> expected_generation or submission_row.status <> 'processing' then return 'stale'; end if;
  if attempt_row.status in ('leased', 'downloading', 'transcoding', 'verifying', 'classifying')
     and attempt_row.lease_expires_at > statement_timestamp() then return 'active'; end if;
  select * into upload_row from wali.upload_sessions u where u.id = submission_row.upload_session_id for share;
  select * into object_row from storage.objects o
   where o.bucket_id = 'uploads-private' and o.name = upload_row.storage_path
     and o.version = upload_row.storage_version and not coalesce(o.is_delete_marker, false) for share;
  object_size := coalesce((object_row.metadata ->> 'size')::bigint, 0);
  if upload_row.status <> 'completed' or object_row.id is null
     or object_size <> upload_row.received_byte_count or object_size <> upload_row.declared_byte_count then
    update wali.processing_attempts set status = 'failed', safe_error_code = 'WALI_UPLOAD_CHANGED',
      finished_at = statement_timestamp(), lease_owner = null, lease_expires_at = null
     where id = attempt_row.id;
    update wali.submissions set status = 'processing_failed', last_safe_error_code = 'WALI_UPLOAD_CHANGED'
     where id = submission_row.id;
    return 'stale';
  end if;
  update wali.processing_attempts set status = 'leased', lease_owner = worker_identity,
    lease_expires_at = lease_until, started_at = coalesce(started_at, statement_timestamp()),
    worker_build = worker_identity where id = attempt_row.id;
  return 'started';
end $$;

create or replace function wali.worker_heartbeat_attempt(
  target_attempt_id uuid, expected_generation integer, worker_identity text, lease_until timestamptz
) returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if lease_until <= statement_timestamp() or lease_until > statement_timestamp() + interval '5 minutes' then return false; end if;
  update wali.processing_attempts set lease_expires_at = lease_until
   where id = target_attempt_id and generation = expected_generation and lease_owner = worker_identity
     and status in ('leased', 'downloading', 'transcoding', 'verifying', 'classifying')
     and lease_expires_at > statement_timestamp();
  return found;
end $$;

create or replace function wali.worker_read_classification_input(
  target_attempt_id uuid, expected_generation integer, worker_identity text
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  select jsonb_build_object('title', s.proposed_title, 'description', s.proposed_description) into result
    from wali.processing_attempts p join wali.submissions s on s.id = p.submission_id
   where p.id = target_attempt_id and p.generation = expected_generation
     and p.lease_owner = worker_identity and p.lease_expires_at > statement_timestamp()
     and p.status in ('leased', 'downloading', 'transcoding', 'verifying', 'classifying');
  if result is null then raise exception using errcode = 'P0001', message = 'WALI_WORKER_LEASE_INVALID'; end if;
  return result;
end $$;

create or replace function wali.worker_authorize_staged_artifact(
  target_attempt_id uuid, expected_generation integer, worker_identity text, artifact jsonb
) returns boolean language plpgsql security definer set search_path = '' as $$
declare attempt_row wali.processing_attempts%rowtype; extension text; expected_path text;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if jsonb_typeof(artifact) <> 'object'
     or (select array_agg(key order by key) from jsonb_object_keys(artifact) key) <>
       array['byte_count','codec','color_space','digest','duration_ms','frame_rate_denominator','frame_rate_numerator','has_audio','height','media_type','pixel_format','role','width']::text[]
     or artifact ->> 'role' not in ('thumbnail', 'poster', 'preview', 'video_default')
     or artifact ->> 'digest' !~ '^[0-9a-f]{64}$'
     or artifact ->> 'media_type' not in ('image/jpeg', 'image/png', 'video/mp4')
     or jsonb_typeof(artifact -> 'has_audio') <> 'boolean' or (artifact ->> 'has_audio')::boolean
     or jsonb_typeof(artifact -> 'byte_count') <> 'number' or (artifact ->> 'byte_count')::bigint not between 1 and 2147483648
     or jsonb_typeof(artifact -> 'width') <> 'number' or (artifact ->> 'width')::integer not between 1 and 7680
     or jsonb_typeof(artifact -> 'height') <> 'number' or (artifact ->> 'height')::integer not between 1 and 4320
     or jsonb_typeof(artifact -> 'duration_ms') <> 'number' or (artifact ->> 'duration_ms')::bigint not between 0 and 600000
     or not wali.plain_text_is_valid(artifact ->> 'codec', 1, 64)
     or not wali.plain_text_is_valid(artifact ->> 'pixel_format', 1, 64)
     or not wali.plain_text_is_valid(artifact ->> 'color_space', 1, 64) then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID';
  end if;
  select * into attempt_row from wali.processing_attempts attempt where attempt.id = target_attempt_id for update;
  if not found or attempt_row.generation <> expected_generation
     or attempt_row.lease_owner <> worker_identity or attempt_row.lease_expires_at <= statement_timestamp()
     or attempt_row.status not in ('leased', 'downloading', 'transcoding', 'verifying', 'classifying') then
    return false;
  end if;
  extension := case artifact ->> 'media_type' when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'video/mp4' then 'mp4' end;
  expected_path := 'sha256/' || substring((artifact ->> 'digest') from 1 for 2) || '/' ||
    substring((artifact ->> 'digest') from 3 for 2) || '/' || (artifact ->> 'digest') || '/' ||
    replace((artifact ->> 'role'), '_', '-') || '.' || extension;
  insert into wali.staged_upload_intents (attempt_id, generation, worker_identity, role, digest,
    byte_count, media_type, storage_path, artifact_claim, expires_at)
  values (attempt_row.id, expected_generation, worker_identity, (artifact ->> 'role')::wali.artifact_role,
    artifact ->> 'digest', (artifact ->> 'byte_count')::bigint, artifact ->> 'media_type', expected_path,
    artifact, least(attempt_row.lease_expires_at, statement_timestamp() + interval '10 minutes'))
  on conflict (attempt_id, role) do update set
    generation = excluded.generation, worker_identity = excluded.worker_identity, digest = excluded.digest,
    byte_count = excluded.byte_count, media_type = excluded.media_type, storage_path = excluded.storage_path,
    artifact_claim = excluded.artifact_claim, expires_at = excluded.expires_at, consumed_at = null
  where wali.staged_upload_intents.worker_identity = excluded.worker_identity
    and wali.staged_upload_intents.consumed_at is null;
  return found;
end $$;

create or replace function wali.classifier_result_is_valid(result jsonb)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare embedding_name text; embedding jsonb; squared_norm numeric;
  categories jsonb; tags jsonb;
begin
  if jsonb_typeof(result) <> 'object'
     or (select array_agg(key order by key) from jsonb_object_keys(result) key) <>
       array['available','categories','combined_embedding','input_frame_set_digest','model_digest','model_id','model_revision','safe_code','tags','taxonomy_revision','text_embedding','visual_embedding']::text[]
     or jsonb_typeof(result -> 'available') <> 'boolean'
     or jsonb_typeof(result -> 'categories') <> 'array'
     or jsonb_typeof(result -> 'tags') <> 'array'
     or jsonb_typeof(result -> 'visual_embedding') <> 'array'
     or jsonb_typeof(result -> 'text_embedding') <> 'array'
     or jsonb_typeof(result -> 'combined_embedding') <> 'array' then
    return false;
  end if;
  if not (result ->> 'available')::boolean then
    return result ->> 'safe_code' = 'classifier_unavailable'
      and result ->> 'model_id' = '' and result ->> 'model_revision' = ''
      and result ->> 'model_digest' = '' and result ->> 'taxonomy_revision' = ''
      and result ->> 'input_frame_set_digest' = ''
      and jsonb_array_length(result -> 'categories') = 0 and jsonb_array_length(result -> 'tags') = 0
      and jsonb_array_length(result -> 'visual_embedding') = 0
      and jsonb_array_length(result -> 'text_embedding') = 0
      and jsonb_array_length(result -> 'combined_embedding') = 0;
  end if;
  if result ->> 'safe_code' <> 'ok'
     or result ->> 'model_digest' !~ '^[0-9a-f]{64}$'
     or result ->> 'input_frame_set_digest' !~ '^[0-9a-f]{64}$'
     or not exists (select 1 from wali.model_registry model
       where model.model_id = result ->> 'model_id'
         and model.model_revision = result ->> 'model_revision'
         and model.artifact_digest = result ->> 'model_digest'
         and model.taxonomy_revision = result ->> 'taxonomy_revision'
         and model.embedding_dimension = 768 and model.status = 'active') then
    return false;
  end if;
  foreach embedding_name in array array['visual_embedding','text_embedding','combined_embedding'] loop
    embedding := result -> embedding_name;
    if jsonb_array_length(embedding) <> 768
       or exists (select 1 from jsonb_array_elements(embedding) number where jsonb_typeof(number) <> 'number') then
      return false;
    end if;
    select sum(power((number #>> '{}')::numeric, 2)) into squared_norm
      from jsonb_array_elements(embedding) number;
    if squared_norm not between 0.98 and 1.02 then return false; end if;
  end loop;
  categories := result -> 'categories'; tags := result -> 'tags';
  if jsonb_array_length(categories) > 64 or jsonb_array_length(tags) > 256 then return false; end if;
  if exists (
    select 1 from jsonb_array_elements(categories || tags) score
     where jsonb_typeof(score) <> 'object'
        or (select array_agg(key order by key) from jsonb_object_keys(score) key) <> array['confidence','id']::text[]
        or score ->> 'id' !~ '^[a-z][a-z0-9_]{1,47}$'
        or jsonb_typeof(score -> 'confidence') <> 'number'
        or (score ->> 'confidence')::numeric not between 0 and 1
  ) or (select count(*) from jsonb_array_elements(categories)) <>
       (select count(distinct score ->> 'id') from jsonb_array_elements(categories) score)
    or (select count(*) from jsonb_array_elements(tags)) <>
       (select count(distinct score ->> 'id') from jsonb_array_elements(tags) score)
    or exists (select 1 from jsonb_array_elements(categories) score
       where not exists (select 1 from wali.categories category
         join wali.model_registry model on model.model_id = result ->> 'model_id'
           and model.model_revision = result ->> 'model_revision'
         where replace(category.slug, '-', '_') = score ->> 'id' and category.active
           and model.approved_labels ? ('category:' || (score ->> 'id'))))
    or exists (select 1 from jsonb_array_elements(tags) score
       where not exists (select 1 from wali.tags tag
         join wali.model_registry model on model.model_id = result ->> 'model_id'
           and model.model_revision = result ->> 'model_revision'
         where replace(tag.slug, '-', '_') = score ->> 'id' and tag.active
           and model.approved_labels ? ('tag:' || (score ->> 'id')))) then
    return false;
  end if;
  return true;
exception when others then
  return false;
end $$;

create or replace function wali.worker_complete_attempt(
  target_attempt_id uuid, expected_generation integer, worker_identity text, completion jsonb
) returns boolean language plpgsql security definer set search_path = '' as $$
declare attempt_row wali.processing_attempts%rowtype; submission_row wali.submissions%rowtype;
  upload_row wali.upload_sessions%rowtype; raw_object storage.objects%rowtype; artifact jsonb;
  target_release_id uuid; computed_source_digest text; roles text[]; expected_path text; extension text;
  classification jsonb; run_id uuid; safe_summary jsonb;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if jsonb_typeof(completion) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(completion) k)
       <> array['artifacts','classification','source_digest']::text[]
     or completion ->> 'source_digest' !~ '^[0-9a-f]{64}$'
     or jsonb_typeof(completion -> 'artifacts') <> 'array'
     or jsonb_array_length(completion -> 'artifacts') <> 4
     or not wali.classifier_result_is_valid(completion -> 'classification')
     or octet_length(completion::text) > 131072 then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID';
  end if;
  select * into attempt_row from wali.processing_attempts p where p.id = target_attempt_id for update;
  if not found or attempt_row.generation <> expected_generation then return false; end if;
  computed_source_digest := completion ->> 'source_digest';
  if attempt_row.status = 'completed' then return attempt_row.output_summary ->> 'source_digest' = computed_source_digest; end if;
  if attempt_row.lease_owner <> worker_identity or attempt_row.lease_expires_at <= statement_timestamp()
     or attempt_row.status not in ('leased', 'downloading', 'transcoding', 'verifying', 'classifying') then return false; end if;
  select * into submission_row from wali.submissions s where s.id = attempt_row.submission_id for update;
  select * into upload_row from wali.upload_sessions u where u.id = submission_row.upload_session_id for share;
  select * into raw_object from storage.objects o where o.bucket_id = 'uploads-private'
    and o.name = upload_row.storage_path and o.version = upload_row.storage_version
    and not coalesce(o.is_delete_marker, false) for share;
  if raw_object.id is null or coalesce((raw_object.metadata ->> 'size')::bigint, 0) <> upload_row.received_byte_count then
    raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_CHANGED';
  end if;
  select array_agg(value ->> 'role' order by value ->> 'role') into roles
    from jsonb_array_elements(completion -> 'artifacts');
  if roles <> array['poster','preview','thumbnail','video_default']::text[] then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID';
  end if;
  for artifact in select value from jsonb_array_elements(completion -> 'artifacts') loop
    if (select array_agg(k order by k) from jsonb_object_keys(artifact) k) <>
       array['byte_count','codec','color_space','digest','duration_ms','frame_rate_denominator','frame_rate_numerator','has_audio','height','media_type','pixel_format','role','width']::text[]
       or artifact ->> 'digest' !~ '^[0-9a-f]{64}$'
       or (artifact ->> 'has_audio')::boolean then
      raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID';
    end if;
    extension := case artifact ->> 'media_type' when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'video/mp4' then 'mp4' else null end;
    if extension is null then raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID'; end if;
    expected_path := 'sha256/' || substring((artifact ->> 'digest') from 1 for 2) || '/' ||
      substring((artifact ->> 'digest') from 3 for 2) || '/' || (artifact ->> 'digest') || '/' ||
      replace((artifact ->> 'role'), '_', '-') || '.' || extension;
    if not exists (select 1 from wali.staged_upload_intents intent
      where intent.attempt_id = attempt_row.id and intent.generation = expected_generation
        and intent.worker_identity = worker_complete_attempt.worker_identity
        and intent.role = (artifact ->> 'role')::wali.artifact_role
        and intent.storage_path = expected_path and intent.artifact_claim = artifact
        and intent.consumed_at is null and intent.expires_at > statement_timestamp())
      or not exists (select 1 from storage.objects o where o.bucket_id = 'processing-private' and o.name = expected_path
      and not coalesce(o.is_delete_marker, false)
      and coalesce((o.metadata ->> 'size')::bigint, 0) = (artifact ->> 'byte_count')::bigint) then
      raise exception using errcode = 'P0001', message = 'WALI_CANONICAL_OBJECT_MISSING';
    end if;
    insert into wali.staged_artifacts (digest, media_type, byte_count, storage_bucket, storage_path,
      width, height, duration_ms, frame_rate_numerator, frame_rate_denominator, codec,
      pixel_format, color_space, has_audio, verified_by_attempt_id)
    values (artifact ->> 'digest', artifact ->> 'media_type', (artifact ->> 'byte_count')::bigint,
      'processing-private', expected_path, (artifact ->> 'width')::integer, (artifact ->> 'height')::integer,
      nullif((artifact ->> 'duration_ms')::bigint, 0), nullif((artifact ->> 'frame_rate_numerator')::integer, 0),
      nullif((artifact ->> 'frame_rate_denominator')::integer, 0), artifact ->> 'codec',
      artifact ->> 'pixel_format', artifact ->> 'color_space', false, attempt_row.id)
    on conflict (digest) do nothing;
  end loop;
  select r.id into target_release_id from wali.wallpaper_releases r where r.source_submission_id = submission_row.id;
  if target_release_id is null then
    insert into wali.wallpaper_releases (wallpaper_id, edition, source_submission_id, status)
    select submission_row.wallpaper_id, coalesce(max(r.edition), 0) + 1, submission_row.id, 'processing'
      from wali.wallpaper_releases r where r.wallpaper_id = submission_row.wallpaper_id
    returning id into target_release_id;
  end if;
  classification := completion -> 'classification';
  safe_summary := jsonb_set(completion, '{classification}',
    classification - array['visual_embedding','text_embedding','combined_embedding']);
  if octet_length(safe_summary::text) > 32768 then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID';
  end if;
  if (classification ->> 'available')::boolean then
    insert into wali.classification_runs (
      attempt_id, model_id, model_revision, model_artifact_digest, input_frame_set_digest,
      status, started_at, finished_at, raw_result
    ) values (
      attempt_row.id, classification ->> 'model_id', classification ->> 'model_revision',
      classification ->> 'model_digest', classification ->> 'input_frame_set_digest',
      'completed', coalesce(attempt_row.started_at, statement_timestamp()), statement_timestamp(),
      classification - array['visual_embedding','text_embedding','combined_embedding']
    ) returning id into run_id;
    insert into wali.submission_tag_suggestions (
      submission_id, tag_id, source, confidence, model_id, model_revision
    ) select submission_row.id, tag.id, 'classifier', (score ->> 'confidence')::numeric,
        classification ->> 'model_id', classification ->> 'model_revision'
      from jsonb_array_elements(classification -> 'tags') score
      join wali.tags tag on replace(tag.slug, '-', '_') = score ->> 'id'
    on conflict (submission_id, tag_id, source) do update set
      confidence = excluded.confidence, model_id = excluded.model_id, model_revision = excluded.model_revision;
    insert into wali.wallpaper_categories (wallpaper_id, category_id, source, confidence, model_run_id)
    select submission_row.wallpaper_id, category.id, 'classifier', (score ->> 'confidence')::numeric, run_id
      from jsonb_array_elements(classification -> 'categories') score
      join wali.categories category on replace(category.slug, '-', '_') = score ->> 'id'
    on conflict (wallpaper_id, category_id, source) do update set
      confidence = excluded.confidence, model_run_id = excluded.model_run_id;
    insert into wali.wallpaper_tags (wallpaper_id, tag_id, source, confidence, status, model_run_id)
    select submission_row.wallpaper_id, tag.id, 'classifier', (score ->> 'confidence')::numeric, 'suggested', run_id
      from jsonb_array_elements(classification -> 'tags') score
      join wali.tags tag on replace(tag.slug, '-', '_') = score ->> 'id'
    on conflict (wallpaper_id, tag_id, source) do update set
      confidence = excluded.confidence, status = 'suggested', model_run_id = excluded.model_run_id,
      decided_by = null, decided_at = null;
    insert into wali.wallpaper_embeddings (
      wallpaper_id, release_id, modality, model_id, model_revision, embedding, input_digest
    ) values
      (submission_row.wallpaper_id, target_release_id, 'visual', classification ->> 'model_id',
        classification ->> 'model_revision', (classification -> 'visual_embedding')::text::extensions.vector,
        classification ->> 'input_frame_set_digest'),
      (submission_row.wallpaper_id, target_release_id, 'text', classification ->> 'model_id',
        classification ->> 'model_revision', (classification -> 'text_embedding')::text::extensions.vector,
        classification ->> 'input_frame_set_digest'),
      (submission_row.wallpaper_id, target_release_id, 'combined', classification ->> 'model_id',
        classification ->> 'model_revision', (classification -> 'combined_embedding')::text::extensions.vector,
        classification ->> 'input_frame_set_digest');
  end if;
  insert into wali.release_staged_artifacts (release_id, role, artifact_digest, sort_order)
  select target_release_id, (value ->> 'role')::wali.artifact_role, value ->> 'digest', ordinal::integer
    from jsonb_array_elements(completion -> 'artifacts') with ordinality a(value, ordinal)
  on conflict (release_id, role) do nothing;
  update wali.staged_upload_intents intent set consumed_at = statement_timestamp()
   where intent.attempt_id = attempt_row.id and intent.generation = expected_generation
     and intent.worker_identity = worker_complete_attempt.worker_identity;
  update wali.upload_sessions set source_digest = computed_source_digest where id = upload_row.id;
  update wali.processing_attempts set status = 'completed', output_summary = safe_summary,
    finished_at = statement_timestamp(), lease_owner = null, lease_expires_at = null where id = attempt_row.id;
  update wali.submissions set status = 'ready_for_submission', last_safe_error_code = null where id = submission_row.id;
  return true;
end $$;

create or replace function wali.worker_fail_attempt(
  target_attempt_id uuid, expected_generation integer, worker_identity text, safe_error_code text
) returns boolean language plpgsql security definer set search_path = '' as $$
declare affected_submission uuid;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if safe_error_code !~ '^WALI_[A-Z0-9_]{2,96}$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  update wali.processing_attempts set status = 'failed', safe_error_code = worker_fail_attempt.safe_error_code,
    finished_at = statement_timestamp(), lease_owner = null, lease_expires_at = null
   where id = target_attempt_id and generation = expected_generation and lease_owner = worker_identity
     and status in ('leased', 'downloading', 'transcoding', 'verifying', 'classifying')
  returning submission_id into affected_submission;
  if affected_submission is null then return false; end if;
  update wali.submissions set status = 'processing_failed', last_safe_error_code = safe_error_code
   where id = affected_submission and generation = expected_generation;
  return true;
end $$;

create or replace function wali.worker_begin_promotion(
  promotion_id uuid, worker_identity text, lease_until timestamptz
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare job wali.artifact_promotions%rowtype; payload jsonb;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.plain_text_is_valid(worker_identity, 1, 128)
     or lease_until <= statement_timestamp() or lease_until > statement_timestamp() + interval '5 minutes' then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_LEASE_INVALID';
  end if;
  select * into job from wali.artifact_promotions p where p.id = promotion_id for update;
  if not found then return jsonb_build_object('disposition', 'stale'); end if;
  if job.status = 'completed' then return jsonb_build_object('disposition', 'completed'); end if;
  if job.status = 'processing' and job.lease_expires_at > statement_timestamp() then
    return jsonb_build_object('disposition', 'active');
  end if;
  update wali.artifact_promotions set status = 'processing', lease_owner = worker_identity,
    lease_expires_at = lease_until, safe_error_code = null where id = job.id;
  select jsonb_build_object(
    'disposition', 'started', 'promotion_id', job.id, 'release_id', job.release_id,
    'artifacts', jsonb_agg(jsonb_build_object(
      'role', rsa.role, 'digest', sa.digest, 'byte_count', sa.byte_count,
      'media_type', sa.media_type, 'source_bucket', 'processing-private',
      'source_path', sa.storage_path, 'destination_bucket', 'catalog-public',
      'destination_path', sa.storage_path
    ) order by rsa.sort_order)
  ) into payload
  from wali.release_staged_artifacts rsa join wali.staged_artifacts sa on sa.digest = rsa.artifact_digest
  where rsa.release_id = job.release_id;
  return payload;
end $$;

create or replace function wali.worker_complete_promotion(
  promotion_id uuid, worker_identity text, observed_artifacts jsonb
) returns boolean language plpgsql security definer set search_path = '' as $$
declare job wali.artifact_promotions%rowtype; staged record; observed jsonb; expected_count integer := 0;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if jsonb_typeof(observed_artifacts) <> 'array' or jsonb_array_length(observed_artifacts) <> 4 then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID';
  end if;
  select * into job from wali.artifact_promotions p where p.id = promotion_id for update;
  if not found then return false; end if;
  if job.status = 'completed' then return true; end if;
  if job.status <> 'processing' or job.lease_owner <> worker_identity or job.lease_expires_at <= statement_timestamp() then return false; end if;
  for staged in
    select rsa.role, rsa.sort_order, sa.* from wali.release_staged_artifacts rsa
    join wali.staged_artifacts sa on sa.digest = rsa.artifact_digest where rsa.release_id = job.release_id
  loop
    expected_count := expected_count + 1;
    select value into observed from jsonb_array_elements(observed_artifacts) value
      where value ->> 'role' = staged.role::text and value ->> 'digest' = staged.digest;
    if observed is null or (observed ->> 'byte_count')::bigint <> staged.byte_count
       or not exists (select 1 from storage.objects o where o.bucket_id = 'catalog-public'
         and o.name = staged.storage_path and not coalesce(o.is_delete_marker, false)
         and coalesce((o.metadata ->> 'size')::bigint, 0) = staged.byte_count) then
      raise exception using errcode = 'P0001', message = 'WALI_PROMOTED_OBJECT_INVALID';
    end if;
    insert into wali.artifacts (digest, media_type, byte_count, storage_bucket, storage_path,
      width, height, duration_ms, frame_rate_numerator, frame_rate_denominator, codec,
      pixel_format, color_space, has_audio, verified_by_attempt_id)
    values (staged.digest, staged.media_type, staged.byte_count, 'catalog-public', staged.storage_path,
      staged.width, staged.height, staged.duration_ms, staged.frame_rate_numerator,
      staged.frame_rate_denominator, staged.codec, staged.pixel_format, staged.color_space,
      false, staged.verified_by_attempt_id)
    on conflict (digest) do nothing;
    insert into wali.release_artifacts (release_id, role, artifact_digest, sort_order)
    values (job.release_id, staged.role, staged.digest, staged.sort_order)
    on conflict (release_id, role) do nothing;
  end loop;
  if expected_count <> 4 then raise exception using errcode = 'P0001', message = 'WALI_ARTIFACT_SET_INVALID'; end if;
  update wali.artifact_promotions set status = 'completed', completed_at = statement_timestamp(),
    lease_owner = null, lease_expires_at = null where id = job.id;
  return true;
end $$;

create or replace function wali.worker_fail_promotion(
  promotion_id uuid, worker_identity text, safe_error_code text
) returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if safe_error_code !~ '^WALI_[A-Z0-9_]{2,96}$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  update wali.artifact_promotions set status = 'failed', safe_error_code = worker_fail_promotion.safe_error_code,
    lease_owner = null, lease_expires_at = null where id = promotion_id and status = 'processing'
    and lease_owner = worker_identity;
  return found;
end $$;

create or replace function wali.worker_begin_export(
  export_id uuid, user_id uuid, worker_identity text, lease_until timestamptz
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare export_row wali.account_exports%rowtype;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.plain_text_is_valid(worker_identity, 1, 128)
     or lease_until <= statement_timestamp() or lease_until > statement_timestamp() + interval '5 minutes' then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_LEASE_INVALID';
  end if;
  select * into export_row from wali.account_exports e
   where e.id = worker_begin_export.export_id and e.user_id = worker_begin_export.user_id for update;
  if not found or export_row.status in ('expired', 'failed') then return jsonb_build_object('disposition', 'stale'); end if;
  if export_row.status = 'ready' then return jsonb_build_object('disposition', 'completed'); end if;
  if export_row.status = 'processing' and export_row.lease_expires_at > statement_timestamp() then
    return jsonb_build_object('disposition', 'active');
  end if;
  update wali.account_exports set status = 'processing', lease_owner = worker_identity,
    lease_expires_at = lease_until, safe_error_code = null where id = export_row.id;
  return jsonb_build_object('disposition', 'started', 'path', export_row.storage_path);
end $$;

create or replace function wali.worker_read_account_export(
  export_id uuid, user_id uuid, worker_identity text
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare document jsonb;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not exists (select 1 from wali.account_exports e
    where e.id = worker_read_account_export.export_id and e.user_id = worker_read_account_export.user_id
      and e.status = 'processing' and e.lease_owner = worker_read_account_export.worker_identity
      and e.lease_expires_at > statement_timestamp()) then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_LEASE_INVALID';
  end if;
  select jsonb_build_object(
    'schema_version', 1, 'export_id', worker_read_account_export.export_id,
    'user_id', worker_read_account_export.user_id,
    'exported_at', (select to_char(date_trunc('second', e.created_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      from wali.account_exports e where e.id = worker_read_account_export.export_id),
    'account_identity', (select jsonb_build_object(
      'email', case when u.email is not null and char_length(u.email) between 1 and 320
        and u.email !~ '[[:cntrl:]]' then u.email else null end,
      'providers', coalesce((select jsonb_agg(provider order by provider) from (
        select distinct i.provider
        from auth.identities i
        where i.user_id = u.id and i.provider = any (array[
          'email', 'phone', 'anonymous', 'apple', 'azure', 'bitbucket', 'discord',
          'facebook', 'figma', 'fly', 'github', 'gitlab', 'google', 'kakao',
          'keycloak', 'linkedin', 'linkedin_oidc', 'notion', 'slack', 'spotify',
          'sso', 'twitch', 'twitter', 'workos', 'zoom'
        ]::text[])
        order by i.provider limit 8
      ) providers), '[]'::jsonb),
      'created_at', case when u.created_at is null then null else
        to_char(date_trunc('second', u.created_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') end,
      'last_sign_in_at', case when u.last_sign_in_at is null then null else
        to_char(date_trunc('second', u.last_sign_in_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') end
    ) from auth.users u where u.id = worker_read_account_export.user_id),
    'profile', (select jsonb_build_object('handle', p.handle::text, 'display_name', p.display_name,
      'status', p.status, 'created_at', p.created_at, 'updated_at', p.updated_at)
      from wali.profiles p where p.id = worker_read_account_export.user_id),
    'creator_profile', (select to_jsonb(x) from (select bio, website_url, verification_status,
      created_at, updated_at from wali.creator_profiles where user_id = worker_read_account_export.user_id) x),
    'preferences', (select to_jsonb(x) from (select rating_ceiling, locale, personalization_opt_out,
      marketing_opt_out, revision, created_at, updated_at from wali.user_preferences where user_id = worker_read_account_export.user_id) x),
    'terms_acceptances', coalesce((select jsonb_agg(to_jsonb(x) order by accepted_at, document_kind, document_version)
      from (select document_kind, document_version, accepted_at from wali.terms_acceptances
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'favorites', coalesce((select jsonb_agg(to_jsonb(x) order by wallpaper_id)
      from (select wallpaper_id, active, revision, created_at, updated_at from wali.favorites
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'saved_wallpapers', coalesce((select jsonb_agg(to_jsonb(x) order by wallpaper_id)
      from (select wallpaper_id, active, revision, created_at, updated_at from wali.saved_wallpapers
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'creator_follows', coalesce((select jsonb_agg(to_jsonb(x) order by creator_id)
      from (select creator_id, active, revision, created_at, updated_at from wali.creator_follows
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'install_receipts', coalesce((select jsonb_agg(to_jsonb(x) order by issued_at, id)
      from (select id, release_id, issued_at, expires_at, consumed_at from wali.install_receipts
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'engagement_events', coalesce((select jsonb_agg(to_jsonb(x) order by occurred_at, id)
      from (select id, wallpaper_id, release_id, kind, occurred_at, coarse_source from wali.engagement_events
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'upload_sessions', coalesce((select jsonb_agg(to_jsonb(x) order by created_at, id)
      from (select id, original_filename, declared_byte_count, received_byte_count, detected_media_type,
        status, created_at, completed_at from wali.upload_sessions where creator_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'submissions', coalesce((select jsonb_agg(to_jsonb(x) order by created_at, id)
      from (select id, wallpaper_id, proposed_title, proposed_description, primary_category_id,
        license_id, rights_holder, attribution_text, source_url, content_rating_warning,
        status, generation, revision, submitted_at, decided_at, created_at, updated_at
        from wali.submissions where creator_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'rights_declarations', coalesce((select jsonb_agg(to_jsonb(x) order by submission_id)
      from (select r.submission_id, r.basis, r.rights_holder, r.license_id, r.source_url,
        r.attribution_text, r.attested_at, r.creator_terms_version, r.review_status, r.revision
        from wali.rights_declarations r join wali.submissions s on s.id = r.submission_id
        where s.creator_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'reports', coalesce((select jsonb_agg(to_jsonb(x) order by created_at, id)
      from (select id, wallpaper_id, release_id, kind, detail, status, resolution_code, created_at, resolved_at
        from wali.reports where reporter_id = worker_read_account_export.user_id) x), '[]'::jsonb)
  ) into document;
  if octet_length(document::text) > 10485760 then raise exception using errcode = 'P0001', message = 'WALI_EXPORT_TOO_LARGE'; end if;
  return document;
end $$;

create or replace function wali.worker_complete_export(
  export_id uuid, user_id uuid, worker_identity text, byte_count bigint, digest text
) returns boolean language plpgsql security definer set search_path = '' as $$
declare export_row wali.account_exports%rowtype;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if byte_count not between 2 and 104857600 or digest !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID';
  end if;
  select * into export_row from wali.account_exports e
   where e.id = worker_complete_export.export_id and e.user_id = worker_complete_export.user_id for update;
  if not found then return false; end if;
  if export_row.status = 'ready' then return export_row.byte_count = byte_count and export_row.digest = digest; end if;
  if export_row.status <> 'processing' or export_row.lease_owner <> worker_identity
     or export_row.lease_expires_at <= statement_timestamp() then return false; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'exports-private'
    and o.name = export_row.storage_path and not coalesce(o.is_delete_marker, false)
    and coalesce((o.metadata ->> 'size')::bigint, 0) = byte_count) then
    raise exception using errcode = 'P0001', message = 'WALI_EXPORT_OBJECT_INVALID';
  end if;
  update wali.account_exports set status = 'ready', byte_count = worker_complete_export.byte_count,
    digest = worker_complete_export.digest, completed_at = statement_timestamp(),
    lease_owner = null, lease_expires_at = null where id = export_row.id;
  return true;
end $$;

create or replace function wali.worker_fail_export(
  export_id uuid, user_id uuid, worker_identity text, safe_error_code text
) returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if safe_error_code !~ '^WALI_[A-Z0-9_]{2,96}$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  update wali.account_exports set status = 'failed', safe_error_code = worker_fail_export.safe_error_code,
    lease_owner = null, lease_expires_at = null
    where wali.account_exports.id = worker_fail_export.export_id
      and wali.account_exports.user_id = worker_fail_export.user_id
      and wali.account_exports.status = 'processing'
      and wali.account_exports.lease_owner = worker_fail_export.worker_identity;
  return found;
end $$;

create or replace function wali.enqueue_object_cleanup(
  object_bucket text, object_path text, cleanup_reason text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare cleanup_id uuid;
begin
  if object_bucket not in ('uploads-private', 'exports-private', 'processing-private', 'moderation-private')
     or cleanup_reason not in ('expired_upload', 'expired_export', 'account_deletion', 'staged_artifact_retention')
     or not wali.plain_text_is_valid(object_path, 1, 768) or object_path ~ '(^|/)\.\.(/|$)'
     or (object_bucket = 'uploads-private' and object_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/source$')
     or (object_bucket = 'exports-private' and object_path !~ '^exports/[0-9a-f-]{36}/[0-9a-f-]{36}/account[.]json$')
     or (object_bucket = 'processing-private' and object_path !~ '^sha256/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{64}/[a-z0-9-]+[.](jpg|jpeg|png|mp4)$') then
    raise exception using errcode = 'P0001', message = 'WALI_CLEANUP_PATH_INVALID';
  end if;
  insert into wali.cleanup_object_intents (bucket_id, storage_path, reason)
  values (object_bucket, object_path, cleanup_reason)
  on conflict (bucket_id, storage_path) do update set
    reason = excluded.reason, status = 'queued', lease_owner = null, lease_expires_at = null,
    safe_error_code = null, completed_at = null
  where wali.cleanup_object_intents.status in ('completed', 'failed')
  returning id into cleanup_id;
  if cleanup_id is null then
    select id into cleanup_id from wali.cleanup_object_intents
     where bucket_id = object_bucket and storage_path = object_path;
  elsif not exists (
    select 1 from pgmq.q_wali_cleanup queued
    where queued.message ->> 'kind' = 'storage_object'
      and queued.message ->> 'cleanup_id' = cleanup_id::text
  ) then
    perform pgmq.send('wali_cleanup', jsonb_build_object(
      'schema_version', 1, 'kind', 'storage_object', 'cleanup_id', cleanup_id
    ));
  end if;
  return cleanup_id;
end $$;

create or replace function wali.worker_begin_cleanup(
  cleanup_id uuid, worker_identity text, lease_until timestamptz
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare cleanup wali.cleanup_object_intents%rowtype;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.plain_text_is_valid(worker_identity, 1, 128)
     or lease_until <= statement_timestamp() or lease_until > statement_timestamp() + interval '5 minutes' then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_LEASE_INVALID';
  end if;
  select * into cleanup from wali.cleanup_object_intents intent where intent.id = cleanup_id for update;
  if not found then return jsonb_build_object('disposition', 'stale'); end if;
  if cleanup.status = 'completed' then return jsonb_build_object('disposition', 'completed'); end if;
  if cleanup.status = 'processing' and cleanup.lease_expires_at > statement_timestamp() then
    return jsonb_build_object('disposition', 'active');
  end if;
  update wali.cleanup_object_intents set status = 'processing', lease_owner = worker_identity,
    lease_expires_at = lease_until, safe_error_code = null where id = cleanup.id;
  return jsonb_build_object('disposition', 'started', 'bucket', cleanup.bucket_id, 'path', cleanup.storage_path);
end $$;

create or replace function wali.worker_complete_cleanup(
  cleanup_id uuid, worker_identity text
) returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  update wali.cleanup_object_intents cleanup set status = 'completed', completed_at = statement_timestamp(),
    lease_owner = null, lease_expires_at = null
   where cleanup.id = worker_complete_cleanup.cleanup_id and cleanup.status = 'processing'
     and cleanup.lease_owner = worker_complete_cleanup.worker_identity
     and cleanup.lease_expires_at > statement_timestamp()
     and not exists (select 1 from storage.objects object
       where object.bucket_id = cleanup.bucket_id and object.name = cleanup.storage_path
         and not coalesce(object.is_delete_marker, false));
  return found;
end $$;

create or replace function wali.worker_fail_cleanup(
  cleanup_id uuid, worker_identity text, safe_error_code text
) returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if safe_error_code !~ '^WALI_[A-Z0-9_]{2,96}$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  update wali.cleanup_object_intents cleanup set status = 'failed',
    safe_error_code = worker_fail_cleanup.safe_error_code, lease_owner = null, lease_expires_at = null
   where cleanup.id = worker_fail_cleanup.cleanup_id and cleanup.status = 'processing'
     and cleanup.lease_owner = worker_fail_cleanup.worker_identity;
  return found;
end $$;

create or replace function wali.expire_account_exports(effective_clock timestamptz)
returns bigint language plpgsql security definer set search_path = '' as $$
declare affected bigint;
begin
  perform wali.enqueue_object_cleanup('exports-private', export.storage_path, 'expired_export')
    from wali.account_exports export
   where export.expires_at <= effective_clock and export.status <> 'expired'
     and exists (select 1 from storage.objects object
       where object.bucket_id = 'exports-private' and object.name = export.storage_path);
  update wali.account_exports set status = 'expired', lease_owner = null, lease_expires_at = null
   where expires_at <= effective_clock and status <> 'expired';
  get diagnostics affected = row_count;
  return affected;
end $$;

create or replace function wali.cleanup_expired_marketplace_objects(effective_clock timestamptz)
returns bigint language plpgsql security definer set search_path = '' as $$
declare affected bigint;
begin
  perform wali.enqueue_object_cleanup('uploads-private', upload.storage_path, 'expired_upload')
    from wali.upload_sessions upload
   where ((upload.status in ('issued', 'uploading') and upload.expires_at <= effective_clock)
       or (upload.status = 'completed' and upload.updated_at <= effective_clock - interval '30 days'))
     and exists (select 1 from storage.objects object
       where object.bucket_id = 'uploads-private' and object.name = upload.storage_path)
     and not exists (select 1 from wali.submissions submission
       join wali.processing_attempts attempt on attempt.submission_id = submission.id
        and attempt.generation = submission.generation
       where submission.upload_session_id = upload.id
         and attempt.status in ('queued', 'leased', 'downloading', 'transcoding', 'verifying', 'classifying'))
     and not exists (select 1 from wali.submissions submission
       join wali.copyright_cases copyright on copyright.target_wallpaper_id = submission.wallpaper_id
       where submission.upload_session_id = upload.id and copyright.status in ('open', 'triaged', 'appealed'));
  update wali.upload_sessions set status = 'expired'
   where status in ('issued', 'uploading') and expires_at <= effective_clock;
  get diagnostics affected = row_count;
  perform wali.expire_account_exports(effective_clock);
  delete from wali.command_idempotency command where command.ctid in
    (select candidate.ctid from wali.command_idempotency candidate where candidate.expires_at < effective_clock
      order by candidate.expires_at, candidate.actor_id, candidate.operation, candidate.idempotency_key limit 1000);
  delete from wali.rate_limit_buckets bucket where bucket.ctid in
    (select candidate.ctid from wali.rate_limit_buckets candidate where candidate.expires_at < effective_clock
      order by candidate.expires_at, candidate.subject_hash, candidate.operation limit 1000);
  delete from wali.install_receipts receipt where receipt.ctid in (
    select candidate.ctid from wali.install_receipts candidate
     where candidate.expires_at < effective_clock - interval '30 days'
       and not exists (select 1 from wali.engagement_events event where event.install_receipt_id = candidate.id)
     order by candidate.expires_at, candidate.id limit 1000
  );
  delete from wali.publication_intents intent where intent.ctid in
    (select candidate.ctid from wali.publication_intents candidate
      where candidate.expires_at < effective_clock - interval '1 day' order by candidate.expires_at, candidate.id limit 1000);
  delete from wali.staged_upload_intents intent where intent.ctid in
    (select candidate.ctid from wali.staged_upload_intents candidate
      where coalesce(candidate.consumed_at, candidate.expires_at) < effective_clock - interval '1 day'
      order by coalesce(candidate.consumed_at, candidate.expires_at), candidate.attempt_id, candidate.role limit 1000);
  delete from wali.cleanup_object_intents cleanup where cleanup.ctid in (
    select candidate.ctid from wali.cleanup_object_intents candidate
     where (candidate.status = 'completed' and candidate.completed_at < effective_clock - interval '7 days')
        or (candidate.status = 'failed' and candidate.created_at < effective_clock - interval '30 days')
     order by coalesce(candidate.completed_at, candidate.created_at), candidate.id limit 1000
  );
  return affected;
end $$;

create or replace function wali.worker_begin_backup_verification(
  run_id uuid, worker_identity text, lease_until timestamptz
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare run wali.backup_verification_runs%rowtype;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.plain_text_is_valid(worker_identity, 1, 128)
     or lease_until <= statement_timestamp() or lease_until > statement_timestamp() + interval '15 minutes' then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_LEASE_INVALID';
  end if;
  select * into run from wali.backup_verification_runs candidate where candidate.id = run_id for update;
  if not found then return jsonb_build_object('disposition', 'stale'); end if;
  if run.status in ('passed', 'failed') then return jsonb_build_object('disposition', 'completed'); end if;
  if run.status = 'running' and run.lease_expires_at > statement_timestamp() then
    return jsonb_build_object('disposition', 'active');
  end if;
  update wali.backup_verification_runs set status = 'running', lease_owner = worker_identity,
    lease_expires_at = lease_until, started_at = coalesce(started_at, statement_timestamp()),
    safe_error_code = null where id = run.id;
  return jsonb_build_object('disposition', 'started');
end $$;

create or replace function wali.worker_read_backup_verification_targets(
  run_id uuid, worker_identity text, after_path text, page_limit integer
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare page jsonb; next_cursor text;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if page_limit not between 1 and 100 or octet_length(after_path) > 768
     or not exists (select 1 from wali.backup_verification_runs run
       where run.id = worker_read_backup_verification_targets.run_id and run.status = 'running'
         and run.lease_owner = worker_read_backup_verification_targets.worker_identity
         and run.lease_expires_at > statement_timestamp()) then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_LEASE_INVALID';
  end if;
  with targets as (
    select artifact.storage_path as path, artifact.digest, artifact.byte_count
      from wali.artifacts artifact
     where artifact.storage_bucket = 'catalog-public' and artifact.storage_path > after_path
     order by artifact.storage_path limit page_limit
  ) select coalesce(jsonb_agg(jsonb_build_object(
      'bucket', 'catalog-public', 'path', target.path, 'digest', target.digest,
      'byte_count', target.byte_count
    ) order by target.path), '[]'::jsonb), max(target.path)
    into page, next_cursor from targets target;
  return jsonb_build_object('items', page, 'next_cursor', coalesce(next_cursor, ''));
end $$;

create or replace function wali.worker_complete_backup_verification(
  run_id uuid, worker_identity text, checked_count bigint, mismatch_count bigint, report_digest text
) returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if checked_count < 0 or mismatch_count < 0 or mismatch_count > checked_count
     or report_digest !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID';
  end if;
  update wali.backup_verification_runs run set
    status = case when worker_complete_backup_verification.mismatch_count = 0 then 'passed' else 'failed' end,
    checked_object_count = checked_count, mismatch_count = worker_complete_backup_verification.mismatch_count,
    report_digest = worker_complete_backup_verification.report_digest,
    safe_error_code = case when worker_complete_backup_verification.mismatch_count = 0 then null else 'WALI_BACKUP_MISMATCH' end,
    finished_at = statement_timestamp(), lease_owner = null, lease_expires_at = null
   where run.id = worker_complete_backup_verification.run_id and run.status = 'running'
     and run.lease_owner = worker_complete_backup_verification.worker_identity
     and run.lease_expires_at > statement_timestamp();
  return found;
end $$;

create or replace function wali.worker_fail_backup_verification(
  run_id uuid, worker_identity text, safe_error_code text
) returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if safe_error_code !~ '^WALI_[A-Z0-9_]{2,96}$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  update wali.backup_verification_runs run set status = 'failed',
    safe_error_code = worker_fail_backup_verification.safe_error_code,
    finished_at = statement_timestamp(), lease_owner = null, lease_expires_at = null
   where run.id = worker_fail_backup_verification.run_id and run.status = 'running'
     and run.lease_owner = worker_fail_backup_verification.worker_identity;
  return found;
end $$;

create or replace function wali.worker_begin_account_deletion(
  deletion_id uuid, user_id uuid, worker_identity text, lease_until timestamptz
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare deletion wali.account_deletion_requests%rowtype; pending_cleanup boolean;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.plain_text_is_valid(worker_identity, 1, 128)
     or lease_until <= statement_timestamp() or lease_until > statement_timestamp() + interval '5 minutes' then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_LEASE_INVALID';
  end if;
  select * into deletion from wali.account_deletion_requests request
   where request.id = worker_begin_account_deletion.deletion_id
     and request.user_id = worker_begin_account_deletion.user_id for update;
  if not found or deletion.status in ('cancelled', 'failed') then return jsonb_build_object('disposition', 'stale'); end if;
  if deletion.status in ('awaiting_auth_cleanup', 'completed') then return jsonb_build_object('disposition', 'completed'); end if;
  if deletion.auth_identity_status <> 'sessions_revoked' or deletion.sessions_revoked_at is null then
    return jsonb_build_object('disposition', 'cleanup_pending');
  end if;
  if exists (select 1 from wali.copyright_cases copyright
    join wali.wallpapers wallpaper on wallpaper.id = copyright.target_wallpaper_id
    where wallpaper.creator_id = worker_begin_account_deletion.user_id
      and copyright.status in ('open', 'triaged', 'appealed')) then
    update wali.account_deletion_requests set status = 'held', lease_owner = null, lease_expires_at = null
     where id = deletion.id;
    return jsonb_build_object('disposition', 'held');
  end if;
  if deletion.status = 'processing' and deletion.lease_expires_at > statement_timestamp() then
    return jsonb_build_object('disposition', 'active');
  end if;
  perform wali.enqueue_object_cleanup('uploads-private', upload.storage_path, 'account_deletion')
    from wali.upload_sessions upload where upload.creator_id = worker_begin_account_deletion.user_id
      and exists (select 1 from storage.objects object
        where object.bucket_id = 'uploads-private' and object.name = upload.storage_path);
  perform wali.enqueue_object_cleanup('exports-private', export.storage_path, 'account_deletion')
    from wali.account_exports export where export.user_id = worker_begin_account_deletion.user_id
      and exists (select 1 from storage.objects object
        where object.bucket_id = 'exports-private' and object.name = export.storage_path);
  select exists (
    select 1 from wali.cleanup_object_intents cleanup
     where cleanup.status <> 'completed'
       and ((cleanup.bucket_id = 'uploads-private' and exists (
         select 1 from wali.upload_sessions upload where upload.creator_id = worker_begin_account_deletion.user_id
           and upload.storage_path = cleanup.storage_path
       )) or (cleanup.bucket_id = 'exports-private' and exists (
         select 1 from wali.account_exports export where export.user_id = worker_begin_account_deletion.user_id
           and export.storage_path = cleanup.storage_path
       )))
  ) into pending_cleanup;
  if pending_cleanup then
    update wali.account_deletion_requests set status = 'pending', lease_owner = null, lease_expires_at = null
     where id = deletion.id;
    return jsonb_build_object('disposition', 'cleanup_pending');
  end if;
  update wali.account_deletion_requests set status = 'processing', lease_owner = worker_identity,
    lease_expires_at = lease_until, safe_error_code = null where id = deletion.id;
  return jsonb_build_object('disposition', 'ready');
end $$;

create or replace function wali.worker_complete_account_deletion(
  deletion_id uuid, user_id uuid, worker_identity text
) returns boolean language plpgsql security definer set search_path = '' as $$
declare request wali.account_deletion_requests%rowtype;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  select * into request from wali.account_deletion_requests deletion
   where deletion.id = worker_complete_account_deletion.deletion_id
     and deletion.user_id = worker_complete_account_deletion.user_id for update;
  if not found then return false; end if;
  if request.status = 'completed' then return true; end if;
  if request.status <> 'processing' or request.lease_owner <> worker_identity
     or request.lease_expires_at <= statement_timestamp() then return false; end if;
  if exists (select 1 from wali.copyright_cases copyright
    join wali.wallpapers wallpaper on wallpaper.id = copyright.target_wallpaper_id
    where wallpaper.creator_id = worker_complete_account_deletion.user_id
      and copyright.status in ('open', 'triaged', 'appealed'))
     or exists (select 1 from wali.cleanup_object_intents cleanup
       where cleanup.status <> 'completed'
         and (exists (select 1 from wali.upload_sessions upload where upload.creator_id = worker_complete_account_deletion.user_id
           and upload.storage_path = cleanup.storage_path)
          or exists (select 1 from wali.account_exports export where export.user_id = worker_complete_account_deletion.user_id
           and export.storage_path = cleanup.storage_path)))
     or exists (select 1 from storage.objects object join wali.upload_sessions upload
       on upload.storage_path = object.name and upload.creator_id = worker_complete_account_deletion.user_id
       where object.bucket_id = 'uploads-private' and not coalesce(object.is_delete_marker, false))
     or exists (select 1 from storage.objects object join wali.account_exports export
       on export.storage_path = object.name and export.user_id = worker_complete_account_deletion.user_id
       where object.bucket_id = 'exports-private' and not coalesce(object.is_delete_marker, false)) then
    return false;
  end if;
  delete from wali.user_preferences preference where preference.user_id = worker_complete_account_deletion.user_id;
  delete from wali.favorites favorite where favorite.user_id = worker_complete_account_deletion.user_id;
  delete from wali.saved_wallpapers saved where saved.user_id = worker_complete_account_deletion.user_id;
  delete from wali.creator_follows follow where follow.user_id = worker_complete_account_deletion.user_id;
  delete from wali.user_interest_profiles interest where interest.user_id = worker_complete_account_deletion.user_id;
  update wali.install_receipts receipt set user_id = null
   where receipt.user_id = worker_complete_account_deletion.user_id;
  update wali.engagement_events event set user_id = null where event.user_id = worker_complete_account_deletion.user_id;
  update wali.reports report set reporter_id = null where report.reporter_id = worker_complete_account_deletion.user_id;
  update wali.upload_sessions upload set original_filename = 'deleted-upload.mp4'
   where upload.creator_id = worker_complete_account_deletion.user_id;
  update wali.creator_profiles creator set bio = '', website_url = null
   where creator.user_id = worker_complete_account_deletion.user_id;
  update wali.role_grants role_grant set revoked_at = coalesce(role_grant.revoked_at, statement_timestamp()),
    revoked_by = coalesce(role_grant.revoked_by, worker_complete_account_deletion.user_id),
    reason = case when role_grant.revoked_at is null then 'account deletion completed' else role_grant.reason end
   where role_grant.user_id = worker_complete_account_deletion.user_id;
  update wali.profiles profile set handle = ('deleted_' || left(replace(profile.id::text, '-', ''), 24))::extensions.citext,
    display_name = 'Deleted User', avatar_path = null, status = 'deleted', deleted_at = statement_timestamp()
   where profile.id = worker_complete_account_deletion.user_id;
  update wali.account_deletion_requests deletion set status = 'awaiting_auth_cleanup', completed_at = null,
    auth_identity_status = 'operator_cleanup_required', lease_owner = null, lease_expires_at = null,
    revision = deletion.revision + 1
   where deletion.id = worker_complete_account_deletion.deletion_id;
  return true;
end $$;

create or replace function wali.worker_fail_account_deletion(
  deletion_id uuid, user_id uuid, worker_identity text, safe_error_code text
) returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if safe_error_code !~ '^WALI_[A-Z0-9_]{2,96}$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  update wali.account_deletion_requests deletion set status = 'failed',
    safe_error_code = worker_fail_account_deletion.safe_error_code,
    lease_owner = null, lease_expires_at = null
   where deletion.id = worker_fail_account_deletion.deletion_id
     and deletion.user_id = worker_fail_account_deletion.user_id
     and deletion.status = 'processing' and deletion.lease_owner = worker_fail_account_deletion.worker_identity;
  return found;
end $$;

create or replace function public.wali_edge_catalog_security_state_v1()
returns jsonb language sql stable security definer set search_path = '' as $$
  with latest_revocations as (
    select * from wali.catalog_signed_documents where kind = 'revocations'
    order by revision desc limit 1
  ), latest_transition as (
    select * from wali.catalog_signed_documents where kind = 'trust_transition'
    order by revision desc limit 1
  )
  select jsonb_build_object(
    'trust_transition', (select jsonb_build_object(
      'revision', revision,
      'body', translate(encode(body, 'base64'), E'+/=\n\r', '-_'),
      'signature', translate(encode(signature, 'base64'), E'+/=\n\r', '-_'),
      'key_id', signing_key_id
    ) from latest_transition),
    'revocations', (select jsonb_build_object(
      'revision', revision,
      'body', translate(encode(body, 'base64'), E'+/=\n\r', '-_'),
      'signature', translate(encode(signature, 'base64'), E'+/=\n\r', '-_'),
      'key_id', signing_key_id
    ) from latest_revocations)
  )
$$;

create or replace function public.wali_edge_prepare_publication_v1(
  actor_id uuid, actor_aal text, request_id uuid, idempotency_key text,
  submission_id uuid, expected_revision bigint, expected_generation bigint,
  expected_wallpaper_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare submission_row wali.submissions%rowtype; wallpaper_row wali.wallpapers%rowtype;
  release_row wali.wallpaper_releases%rowtype; key_row wali.catalog_signing_keys%rowtype;
  rights_row wali.rights_declarations%rowtype; intent wali.publication_intents%rowtype;
  artifact_digest text; metadata_set_digest text; promotion_id uuid;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if actor_aal <> 'aal2' or not (wali.edge_actor_has_role(actor_id, 'moderator') or wali.edge_actor_has_role(actor_id, 'admin')) then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATOR_AAL2_REQUIRED';
  end if;
  select * into intent from wali.publication_intents publication_intent
   where publication_intent.actor_id = wali_edge_prepare_publication_v1.actor_id
     and publication_intent.idempotency_key = wali_edge_prepare_publication_v1.idempotency_key
   for update;
  if found and intent.consumed_at is not null then
    if intent.submission_id <> wali_edge_prepare_publication_v1.submission_id
       or intent.submission_revision <> expected_revision
       or intent.generation <> expected_generation
       or intent.wallpaper_revision <> expected_wallpaper_revision then
      raise exception using errcode = 'P0001', message = 'WALI_IDEMPOTENCY_CONFLICT';
    end if;
    return jsonb_build_object('replayed', true, 'response', intent.response);
  end if;
  select * into submission_row from wali.submissions s where s.id = submission_id for update;
  if not found or submission_row.status <> 'approved' then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_READY'; end if;
  if submission_row.revision <> expected_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if submission_row.generation <> expected_generation then raise exception using errcode = 'P0001', message = 'WALI_STALE_PROCESSING_GENERATION'; end if;
  select * into wallpaper_row from wali.wallpapers w where w.id = submission_row.wallpaper_id for update;
  if wallpaper_row.revision <> expected_wallpaper_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  select * into rights_row from wali.rights_declarations rights
   where rights.submission_id = submission_row.id and rights.review_status = 'approved' for share;
  if not found or rights_row.license_id <> submission_row.license_id
     or rights_row.rights_holder <> submission_row.rights_holder
     or rights_row.attribution_text is distinct from submission_row.attribution_text
     or rights_row.source_url is distinct from submission_row.source_url then
    raise exception using errcode = 'P0001', message = 'WALI_PUBLICATION_RIGHTS_INVALID';
  end if;
  metadata_set_digest := encode(extensions.digest(jsonb_build_object(
    'title', submission_row.proposed_title, 'description', submission_row.proposed_description,
    'primary_category_id', submission_row.primary_category_id, 'license_id', rights_row.license_id,
    'rights_holder', rights_row.rights_holder, 'attribution_text', rights_row.attribution_text,
    'source_url', rights_row.source_url, 'content_rating', submission_row.content_rating_warning,
    'creator_tags', coalesce((select jsonb_agg(suggestion.tag_id order by suggestion.tag_id)
      from wali.submission_tag_suggestions suggestion where suggestion.submission_id = submission_row.id
        and suggestion.source = 'creator'), '[]'::jsonb)
  )::text, 'sha256'), 'hex');
  select * into release_row from wali.wallpaper_releases r where r.source_submission_id = submission_row.id for update;
  if not found or release_row.status <> 'approved' then raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_AVAILABLE'; end if;
  if (select count(*) from wali.release_artifacts ra where ra.release_id = release_row.id
      and ra.role in ('thumbnail','poster','preview','video_default')) <> 4 then
    if (select count(*) from wali.release_staged_artifacts rsa where rsa.release_id = release_row.id
        and rsa.role in ('thumbnail','poster','preview','video_default')) <> 4 then
      raise exception using errcode = 'P0001', message = 'WALI_ARTIFACT_SET_INVALID';
    end if;
    insert into wali.artifact_promotions (release_id) values (release_row.id)
    on conflict (release_id) do update set status = case
      when wali.artifact_promotions.status = 'failed' then 'queued' else wali.artifact_promotions.status end,
      safe_error_code = case when wali.artifact_promotions.status = 'failed' then null else wali.artifact_promotions.safe_error_code end
    returning id into promotion_id;
    if not exists (select 1 from pgmq.q_wali_promotions q where (q.message ->> 'promotion_id')::uuid = promotion_id) then
      perform pgmq.send('wali_promotions', jsonb_build_object('schema_version', 1, 'promotion_id', promotion_id));
    end if;
    return jsonb_build_object('status', 'promotion_pending', 'promotion_id', promotion_id, 'retry_after_seconds', 2);
  end if;
  select string_agg(ra.role::text || ':' || ra.artifact_digest, ',' order by ra.sort_order, ra.role)
    into artifact_digest from wali.release_artifacts ra where ra.release_id = release_row.id;
  artifact_digest := encode(extensions.digest(artifact_digest, 'sha256'), 'hex');
  select * into key_row from wali.catalog_signing_keys k where k.status = 'active'
    and statement_timestamp() between k.valid_from and coalesce(k.valid_until, 'infinity')
    order by k.valid_from desc, k.key_id limit 1;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_SIGNING_KEY_UNAVAILABLE'; end if;
  select * into intent from wali.publication_intents p
   where p.actor_id = wali_edge_prepare_publication_v1.actor_id
     and p.idempotency_key = wali_edge_prepare_publication_v1.idempotency_key for update;
  if found and (intent.submission_id <> submission_row.id or intent.submission_revision <> expected_revision
    or intent.generation <> expected_generation or intent.wallpaper_revision <> expected_wallpaper_revision
    or intent.artifact_set_digest <> artifact_digest or intent.metadata_set_digest <> metadata_set_digest) then
    raise exception using errcode = 'P0001', message = 'WALI_IDEMPOTENCY_CONFLICT';
  end if;
  if not found then
    insert into wali.publication_intents (actor_id, idempotency_key, request_id, submission_id,
      release_id, wallpaper_id, submission_revision, generation, wallpaper_revision,
      artifact_set_digest, metadata_set_digest, signing_key_id, issued_at, expires_at)
    values (wali_edge_prepare_publication_v1.actor_id, wali_edge_prepare_publication_v1.idempotency_key,
      wali_edge_prepare_publication_v1.request_id, submission_row.id, release_row.id,
      wallpaper_row.id, expected_revision, expected_generation, expected_wallpaper_revision,
      artifact_digest, metadata_set_digest, key_row.key_id, date_trunc('second', statement_timestamp()),
      statement_timestamp() + interval '5 minutes') returning * into intent;
  elsif intent.expires_at <= statement_timestamp() or intent.signing_key_id <> key_row.key_id then
    update wali.publication_intents set request_id = wali_edge_prepare_publication_v1.request_id,
      signing_key_id = key_row.key_id, issued_at = date_trunc('second', statement_timestamp()),
      expires_at = statement_timestamp() + interval '5 minutes'
      where id = intent.id and consumed_at is null returning * into intent;
    if not found then raise exception using errcode = 'P0001', message = 'WALI_RELEASE_ALREADY_PUBLISHED'; end if;
  end if;
  return jsonb_build_object(
    'wallpaper_id', wallpaper_row.id, 'release_id', release_row.id, 'edition', release_row.edition,
    'issued_at', to_char(intent.issued_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'key_id', intent.signing_key_id,
    'public_key', translate(encode(key_row.public_key, 'base64'), E'+/=\n\r', '-_'),
    'title', submission_row.proposed_title,
    'creator', (select jsonb_build_object('id', p.id, 'handle', p.handle::text, 'display_name', p.display_name)
      from wali.profiles p where p.id = wallpaper_row.creator_id),
    'rights_holder', rights_row.rights_holder,
    'attribution', jsonb_build_object('text', coalesce(rights_row.attribution_text, ''),
      'source_url', coalesce(rights_row.source_url, ''),
      'license_code', (select l.code from wali.licenses l where l.id = rights_row.license_id)),
    'artifacts', (select jsonb_agg(jsonb_build_object(
      'role', ra.role, 'url', cfg.catalog_public_base_url || '/' || a.storage_path,
      'sha256', a.digest, 'byte_count', a.byte_count, 'media_type', a.media_type,
      'width', a.width, 'height', a.height, 'duration_ms', coalesce(a.duration_ms, 0)
    ) order by ra.sort_order, ra.role) from wali.release_artifacts ra
      join wali.artifacts a on a.digest = ra.artifact_digest
      cross join wali.runtime_configuration cfg where ra.release_id = release_row.id)
  );
end $$;

create or replace function public.wali_edge_finalize_publication_v1(
  actor_id uuid, actor_aal text, request_id uuid, idempotency_key text,
  submission_id uuid, expected_revision bigint, expected_generation bigint,
  expected_wallpaper_revision bigint, manifest_body text, metadata_body text,
  manifest_digest text, metadata_digest text, manifest_signature text, signing_key_id text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare intent wali.publication_intents%rowtype; release_row wali.wallpaper_releases%rowtype;
  submission_row wali.submissions%rowtype; wallpaper_row wali.wallpapers%rowtype;
  rights_row wali.rights_declarations%rowtype; creator_row wali.profiles%rowtype;
  manifest_bytes bytea; metadata_bytes bytea; signature_bytes bytea; manifest jsonb; metadata jsonb;
  current_artifact_digest text; current_metadata_set_digest text; result_document jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if actor_aal <> 'aal2' or not (wali.edge_actor_has_role(actor_id, 'moderator') or wali.edge_actor_has_role(actor_id, 'admin')) then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATOR_AAL2_REQUIRED';
  end if;
  select * into intent from wali.publication_intents p
   where p.actor_id = wali_edge_finalize_publication_v1.actor_id
     and p.idempotency_key = wali_edge_finalize_publication_v1.idempotency_key for update;
  if not found or intent.submission_id <> submission_id then raise exception using errcode = 'P0001', message = 'WALI_PUBLICATION_INTENT_INVALID'; end if;
  if intent.consumed_at is not null then return intent.response; end if;
  if intent.expires_at <= statement_timestamp() or intent.submission_revision <> expected_revision
     or intent.generation <> expected_generation or intent.wallpaper_revision <> expected_wallpaper_revision
     or intent.signing_key_id <> signing_key_id then raise exception using errcode = 'P0001', message = 'WALI_PUBLICATION_INTENT_STALE'; end if;
  begin
    manifest_bytes := decode(translate(manifest_body, '-_', '+/') || repeat('=', (4 - length(manifest_body) % 4) % 4), 'base64');
    metadata_bytes := decode(translate(metadata_body, '-_', '+/') || repeat('=', (4 - length(metadata_body) % 4) % 4), 'base64');
    signature_bytes := decode(translate(manifest_signature, '-_', '+/') || repeat('=', (4 - length(manifest_signature) % 4) % 4), 'base64');
    manifest := convert_from(manifest_bytes, 'UTF8')::jsonb;
    metadata := convert_from(metadata_bytes, 'UTF8')::jsonb;
  exception when others then raise exception using errcode = 'P0001', message = 'WALI_MANIFEST_INVALID'; end;
  if octet_length(manifest_bytes) > 65536 or octet_length(metadata_bytes) > 16384 or octet_length(signature_bytes) <> 64
     or encode(extensions.digest(manifest_bytes, 'sha256'), 'hex') <> manifest_digest
     or encode(extensions.digest(metadata_bytes, 'sha256'), 'hex') <> metadata_digest
     or manifest ->> 'wallpaper_id' <> intent.wallpaper_id::text or manifest ->> 'release_id' <> intent.release_id::text
     or manifest ->> 'key_id' <> signing_key_id or manifest ->> 'metadata_digest' <> metadata_digest
     or metadata ->> 'schema' <> 'wali.catalog.install-metadata.v1'
     or metadata ->> 'wallpaper_id' <> intent.wallpaper_id::text or metadata ->> 'release_id' <> intent.release_id::text then
    raise exception using errcode = 'P0001', message = 'WALI_MANIFEST_INVALID';
  end if;
  select * into submission_row from wali.submissions s where s.id = intent.submission_id for update;
  select * into wallpaper_row from wali.wallpapers w where w.id = intent.wallpaper_id for update;
  select * into release_row from wali.wallpaper_releases r where r.id = intent.release_id for update;
  select * into rights_row from wali.rights_declarations rights where rights.submission_id = submission_row.id for share;
  select * into creator_row from wali.profiles profile where profile.id = submission_row.creator_id for share;
  current_metadata_set_digest := encode(extensions.digest(jsonb_build_object(
    'title', submission_row.proposed_title, 'description', submission_row.proposed_description,
    'primary_category_id', submission_row.primary_category_id, 'license_id', rights_row.license_id,
    'rights_holder', rights_row.rights_holder, 'attribution_text', rights_row.attribution_text,
    'source_url', rights_row.source_url, 'content_rating', submission_row.content_rating_warning,
    'creator_tags', coalesce((select jsonb_agg(suggestion.tag_id order by suggestion.tag_id)
      from wali.submission_tag_suggestions suggestion where suggestion.submission_id = submission_row.id
        and suggestion.source = 'creator'), '[]'::jsonb)
  )::text, 'sha256'), 'hex');
  select encode(extensions.digest(string_agg(ra.role::text || ':' || ra.artifact_digest, ',' order by ra.sort_order, ra.role), 'sha256'), 'hex')
    into current_artifact_digest from wali.release_artifacts ra where ra.release_id = release_row.id;
  if submission_row.status <> 'approved' or submission_row.revision <> intent.submission_revision
     or submission_row.generation <> intent.generation or wallpaper_row.revision <> intent.wallpaper_revision
     or release_row.status <> 'approved' or current_artifact_digest <> intent.artifact_set_digest
     or rights_row.review_status <> 'approved' or current_metadata_set_digest <> intent.metadata_set_digest
     or metadata ->> 'title' <> submission_row.proposed_title
     or metadata ->> 'rights_holder' <> rights_row.rights_holder
     or metadata ->> 'attribution_text' <> coalesce(rights_row.attribution_text, '')
     or metadata ->> 'creator_name' <> creator_row.display_name
     or metadata ->> 'creator_handle' <> creator_row.handle::text
     or not exists (select 1 from wali.catalog_signing_keys k where k.key_id = signing_key_id and k.status = 'active'
       and statement_timestamp() between k.valid_from and coalesce(k.valid_until, 'infinity')) then
    raise exception using errcode = 'P0001', message = 'WALI_PUBLICATION_INTENT_STALE';
  end if;
  update wali.wallpapers set title = submission_row.proposed_title,
    description = submission_row.proposed_description,
    primary_category_id = submission_row.primary_category_id,
    license_id = rights_row.license_id, rights_holder_display = rights_row.rights_holder,
    attribution_text = rights_row.attribution_text, source_url = rights_row.source_url,
    content_rating = submission_row.content_rating_warning
    where id = wallpaper_row.id returning * into wallpaper_row;
  delete from wali.wallpaper_tags tag
   where tag.wallpaper_id = wallpaper_row.id and tag.source = 'creator';
  insert into wali.wallpaper_tags (wallpaper_id, tag_id, source, status, decided_by, decided_at)
  select wallpaper_row.id, suggestion.tag_id, 'creator'::wali.taxonomy_source, 'approved'::wali.suggestion_status,
    actor_id, statement_timestamp() from wali.submission_tag_suggestions suggestion
   where suggestion.submission_id = submission_row.id and suggestion.source = 'creator';
  update wali.wallpaper_releases set manifest_body = manifest_bytes,
    manifest_digest = wali_edge_finalize_publication_v1.manifest_digest,
    manifest_signature = signature_bytes,
    signing_key_id = wali_edge_finalize_publication_v1.signing_key_id,
    metadata_body = metadata_bytes,
    metadata_digest = wali_edge_finalize_publication_v1.metadata_digest, status = 'published'
    where id = release_row.id;
  update wali.wallpapers set current_release_id = release_row.id, status = 'published',
    published_at = coalesce(published_at, statement_timestamp()) where id = wallpaper_row.id returning * into wallpaper_row;
  update wali.submissions set status = 'published' where id = submission_row.id;
  result_document := jsonb_build_object('wallpaper_id', wallpaper_row.id, 'release_id', release_row.id,
    'edition', release_row.edition, 'manifest_digest', wali_edge_finalize_publication_v1.manifest_digest,
    'key_id', wali_edge_finalize_publication_v1.signing_key_id,
    'wallpaper_revision', wallpaper_row.revision,
    'published_at', to_char(statement_timestamp() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  update wali.publication_intents set consumed_at = statement_timestamp(), response = result_document where id = intent.id;
  insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
  values (wali_edge_finalize_publication_v1.actor_id, 'release.published', 'release', release_row.id,
    wali_edge_finalize_publication_v1.request_id,
    jsonb_build_object('manifest_digest', wali_edge_finalize_publication_v1.manifest_digest,
      'key_id', wali_edge_finalize_publication_v1.signing_key_id));
  return result_document;
end $$;

create or replace function public.wali_edge_prepare_catalog_revocation_v1(
  actor_id uuid, actor_aal text, idempotency_key text, release_id uuid, artifact_digest text,
  expected_list_revision bigint, expected_keyset_revision bigint, reason wali.revocation_reason
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare list_revision bigint; keyset_revision bigint; key_row wali.catalog_signing_keys%rowtype;
  issued timestamptz := date_trunc('second', statement_timestamp()); entries jsonb;
  request_hash text; command_row wali.command_idempotency%rowtype;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if actor_aal <> 'aal2' or not wali.edge_actor_has_role(actor_id, 'admin')
     or not exists (select 1 from wali.security_response_grants grant_row
       where grant_row.user_id = actor_id and grant_row.revoked_at is null) then
    raise exception using errcode = 'P0001', message = 'WALI_SECURITY_RESPONSE_AAL2_REQUIRED';
  end if;
  if char_length(idempotency_key) not between 16 and 64 or idempotency_key !~ '^[A-Za-z0-9_-]+$' then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  request_hash := encode(extensions.digest(release_id::text || ':' || artifact_digest || ':' || reason::text || ':' ||
    expected_list_revision::text || ':' || expected_keyset_revision::text, 'sha256'), 'hex');
  select * into command_row from wali.command_idempotency command
   where command.actor_id = wali_edge_prepare_catalog_revocation_v1.actor_id
     and command.operation = 'issue_catalog_revocation'
     and command.idempotency_key = wali_edge_prepare_catalog_revocation_v1.idempotency_key;
  if found then
    if command_row.request_digest <> request_hash then
      raise exception using errcode = 'P0001', message = 'WALI_IDEMPOTENCY_CONFLICT';
    end if;
    if command_row.status = 'completed' then
      return jsonb_build_object('replayed', true, 'response', command_row.response);
    end if;
    raise exception using errcode = 'P0001', message = 'WALI_COMMAND_IN_PROGRESS';
  end if;
  if reason not in ('critical_security', 'corrupt_artifact', 'signing_compromise')
     or artifact_digest !~ '^[0-9a-f]{64}$'
     or not exists (select 1 from wali.wallpaper_releases release
       join wali.release_artifacts artifact on artifact.release_id = release.id
       where release.id = wali_edge_prepare_catalog_revocation_v1.release_id
         and release.status = 'published'
         and artifact.artifact_digest = wali_edge_prepare_catalog_revocation_v1.artifact_digest) then
    raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_PUBLISHED';
  end if;
  select coalesce(max(document.revision), 0) into list_revision
    from wali.catalog_signed_documents document where document.kind = 'revocations';
  select coalesce(max(document.revision), 0) into keyset_revision
    from wali.catalog_signed_documents document where document.kind = 'trust_transition';
  if list_revision <> expected_list_revision or keyset_revision <> expected_keyset_revision then
    raise exception using errcode = 'P0001', message = 'WALI_REVOCATION_STALE';
  end if;
  if exists (select 1 from wali.catalog_revocations revocation
    where revocation.release_id = wali_edge_prepare_catalog_revocation_v1.release_id
      and revocation.artifact_digest = wali_edge_prepare_catalog_revocation_v1.artifact_digest) then
    raise exception using errcode = 'P0001', message = 'WALI_RELEASE_ALREADY_REVOKED';
  end if;
  select * into key_row from wali.catalog_signing_keys key
   where key.status = 'active' and issued between key.valid_from and coalesce(key.valid_until, 'infinity')
   order by key.valid_from desc, key.key_id limit 1;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_SIGNING_KEY_UNAVAILABLE'; end if;
  select jsonb_agg(entry order by entry ->> 'release_id', entry ->> 'artifact_sha256') into entries from (
    select jsonb_build_object('release_id', revocation.release_id, 'artifact_sha256', revocation.artifact_digest,
      'reason', revocation.reason, 'issued_at', to_char(revocation.issued_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) entry
      from wali.catalog_revocations revocation
    union all
    select jsonb_build_object('release_id', release_id, 'artifact_sha256', artifact_digest,
      'reason', reason, 'issued_at', to_char(issued at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
  ) cumulative;
  return jsonb_build_object(
    'revision', list_revision + 1, 'keyset_revision', keyset_revision,
    'issued_at', to_char(issued at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'key_id', key_row.key_id,
    'public_key', translate(encode(key_row.public_key, 'base64'), E'+/=\n\r', '-_'),
    'revocations', entries
  );
end $$;

create or replace function public.wali_edge_finalize_catalog_revocation_v1(
  actor_id uuid, actor_aal text, request_id uuid, idempotency_key text,
  release_id uuid, artifact_digest text, expected_list_revision bigint,
  expected_keyset_revision bigint, reason wali.revocation_reason,
  canonical_body text, detached_signature text, signing_key_id text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare body_bytes bytea; signature_bytes bytea; document jsonb; issued timestamptz;
  current_list_revision bigint; current_keyset_revision bigint; expected_entries jsonb;
  request_hash text; replay jsonb; response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if actor_aal <> 'aal2' or not wali.edge_actor_has_role(actor_id, 'admin')
     or not exists (select 1 from wali.security_response_grants grant_row
       where grant_row.user_id = actor_id and grant_row.revoked_at is null) then
    raise exception using errcode = 'P0001', message = 'WALI_SECURITY_RESPONSE_AAL2_REQUIRED';
  end if;
  if reason not in ('critical_security', 'corrupt_artifact', 'signing_compromise')
     or canonical_body !~ '^[A-Za-z0-9_-]+$' or detached_signature !~ '^[A-Za-z0-9_-]{86}$'
     or artifact_digest !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  begin
    body_bytes := decode(translate(canonical_body, '-_', '+/') || repeat('=', (4 - length(canonical_body) % 4) % 4), 'base64');
    signature_bytes := decode(translate(detached_signature, '-_', '+/') || repeat('=', (4 - length(detached_signature) % 4) % 4), 'base64');
    document := convert_from(body_bytes, 'UTF8')::jsonb;
    issued := (document ->> 'issued_at')::timestamptz;
  exception when others then
    raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_INVALID';
  end;
  if octet_length(body_bytes) > 1048576 or octet_length(signature_bytes) <> 64
     or (select array_agg(key order by key) from jsonb_object_keys(document) key) <>
       array['issued_at','key_id','revision','revocations','schema']::text[]
     or document -> 'schema' <> '{"epoch":1,"revision":0}'::jsonb
     or document ->> 'key_id' <> signing_key_id
     or document ->> 'revision' <> (expected_list_revision + 1)::text
     or document ->> 'issued_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
     or jsonb_typeof(document -> 'revocations') <> 'array'
     or jsonb_array_length(document -> 'revocations') not between 1 and 4096
     or not exists (select 1 from wali.catalog_signing_keys key where key.key_id = signing_key_id
       and key.status = 'active' and issued between key.valid_from and coalesce(key.valid_until, 'infinity')) then
    raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_INVALID';
  end if;
  request_hash := encode(extensions.digest(release_id::text || ':' || artifact_digest || ':' || reason::text || ':' ||
    expected_list_revision::text || ':' || expected_keyset_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'issue_catalog_revocation', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('wali.catalog_signed_documents:revocations', 0));
  select coalesce(max(revision), 0) into current_list_revision from wali.catalog_signed_documents where kind = 'revocations';
  select coalesce(max(revision), 0) into current_keyset_revision from wali.catalog_signed_documents where kind = 'trust_transition';
  if current_list_revision <> expected_list_revision or current_keyset_revision <> expected_keyset_revision then
    raise exception using errcode = 'P0001', message = 'WALI_REVOCATION_STALE';
  end if;
  if not exists (select 1 from wali.wallpaper_releases release
    join wali.release_artifacts artifact on artifact.release_id = release.id
    where release.id = wali_edge_finalize_catalog_revocation_v1.release_id
      and release.status = 'published' and artifact.artifact_digest = wali_edge_finalize_catalog_revocation_v1.artifact_digest) then
    raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_PUBLISHED';
  end if;
  select jsonb_agg(entry order by entry ->> 'release_id', entry ->> 'artifact_sha256') into expected_entries from (
    select jsonb_build_object('release_id', revocation.release_id, 'artifact_sha256', revocation.artifact_digest,
      'reason', revocation.reason, 'issued_at', to_char(revocation.issued_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) entry
      from wali.catalog_revocations revocation
    union all
    select jsonb_build_object('release_id', release_id, 'artifact_sha256', artifact_digest,
      'reason', reason, 'issued_at', document ->> 'issued_at')
  ) cumulative;
  if document -> 'revocations' <> expected_entries then
    raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_INVALID';
  end if;
  insert into wali.catalog_signed_documents (kind, revision, issued_at, body, body_digest,
    signature, signing_key_id, created_by, request_id)
  values ('revocations', expected_list_revision + 1, issued, body_bytes,
    encode(extensions.digest(body_bytes, 'sha256'), 'hex'), signature_bytes, signing_key_id, actor_id, request_id);
  insert into wali.catalog_revocations (release_id, artifact_digest, reason, issued_at,
    signing_key_id, signature_batch_revision, request_id)
  values (release_id, artifact_digest, reason, issued, signing_key_id, expected_list_revision + 1, request_id);
  update wali.wallpaper_releases
     set status = 'revoked', revoked_at = issued, revocation_reason = reason
   where id = release_id;
  insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
  values (actor_id, 'catalog.revocation.issued', 'release', release_id, request_id,
    jsonb_build_object('artifact_digest', artifact_digest, 'reason', reason,
      'list_revision', expected_list_revision + 1, 'keyset_revision', expected_keyset_revision));
  response := jsonb_build_object('release_id', release_id, 'artifact_digest', artifact_digest,
    'reason', reason, 'revision', expected_list_revision + 1, 'key_id', signing_key_id,
    'body_digest', encode(extensions.digest(body_bytes, 'sha256'), 'hex'));
  perform wali.complete_command(actor_id, 'issue_catalog_revocation', idempotency_key, response);
  return response;
end $$;

create or replace function public.wali_edge_publish_security_document_v1(
  actor_id uuid, actor_aal text, request_id uuid, document_kind text,
  document_revision bigint, canonical_body text, detached_signature text,
  signing_key_id text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare body_bytes bytea; signature_bytes bytea; document jsonb; prior_revision bigint; issued timestamptz;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if actor_aal <> 'aal2' or not wali.edge_actor_has_role(actor_id, 'admin') then
    raise exception using errcode = 'P0001', message = 'WALI_ADMIN_AAL2_REQUIRED';
  end if;
  if document_kind <> 'trust_transition'
     or document_revision not between 1 and 2147483647
     or canonical_body !~ '^[A-Za-z0-9_-]+$' or detached_signature !~ '^[A-Za-z0-9_-]{86}$' then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  begin
    body_bytes := decode(translate(canonical_body, '-_', '+/') || repeat('=', (4 - length(canonical_body) % 4) % 4), 'base64');
    signature_bytes := decode(translate(detached_signature, '-_', '+/') || repeat('=', (4 - length(detached_signature) % 4) % 4), 'base64');
    document := convert_from(body_bytes, 'UTF8')::jsonb;
  exception when others then
    raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_INVALID';
  end;
  if octet_length(signature_bytes) <> 64
     or octet_length(body_bytes) > (case when document_kind = 'trust_transition' then 32768 else 1048576 end)
     or document ->> 'revision' <> document_revision::text
     or document ->> 'issued_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' then
    raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_INVALID';
  end if;
  issued := (document ->> 'issued_at')::timestamptz;
  if document_kind = 'trust_transition' then
    if document ->> 'schema' <> 'wali.catalog.trust-transition.v1'
       or jsonb_typeof(document -> 'keys') <> 'array'
       or jsonb_array_length(document -> 'keys') not between 1 and 32
       or not exists (select 1 from wali.catalog_signing_keys k where k.key_id = signing_key_id
         and k.status = 'active' and k.rotated_from_key_id is null and issued between k.valid_from and coalesce(k.valid_until, 'infinity')) then
      raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_INVALID';
    end if;
  else
    if document -> 'schema' <> '{"epoch":1,"revision":0}'::jsonb
       or document ->> 'key_id' <> signing_key_id
       or jsonb_typeof(document -> 'revocations') <> 'array'
       or jsonb_array_length(document -> 'revocations') > 4096
       or not exists (select 1 from wali.catalog_signing_keys k where k.key_id = signing_key_id
         and k.status = 'active' and issued between k.valid_from and coalesce(k.valid_until, 'infinity')) then
      raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_INVALID';
    end if;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('wali.catalog_signed_documents:' || document_kind, 0));
  select coalesce(max(revision), 0) into prior_revision from wali.catalog_signed_documents where kind = document_kind;
  if document_revision <> prior_revision + 1 then
    raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_REVISION_INVALID';
  end if;
  insert into wali.catalog_signed_documents (kind, revision, issued_at, body, body_digest,
    signature, signing_key_id, created_by, request_id)
  values (document_kind, document_revision, issued, body_bytes,
    encode(extensions.digest(body_bytes, 'sha256'), 'hex'), signature_bytes,
    signing_key_id, actor_id, request_id);
  insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
  values (actor_id, 'catalog.security_document.published', 'signing_key', actor_id, request_id,
    jsonb_build_object('kind', document_kind, 'revision', document_revision, 'key_id', signing_key_id));
  return jsonb_build_object('kind', document_kind, 'revision', document_revision,
    'body_digest', encode(extensions.digest(body_bytes, 'sha256'), 'hex'));
end $$;

create or replace function wali.creator_processing_projection(
  target_submission_id uuid, target_generation integer
) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'submission_id', submission.id,
    'revision', submission.revision,
    'generation', submission.generation,
    'state', submission.status,
    'progress', case attempt.status
      when 'queued' then 0.05 when 'leased' then 0.1 when 'downloading' then 0.2
      when 'transcoding' then 0.45 when 'verifying' then 0.7
      when 'classifying' then 0.85 when 'completed' then 1.0 else null end,
    'safe_error_code', coalesce(attempt.safe_error_code, submission.last_safe_error_code),
    'media_facts', case when media.digest is null then null else jsonb_build_object(
      'container', case media.media_type when 'video/mp4' then 'mp4' else media.media_type end,
      'codec', media.codec, 'width', media.width, 'height', media.height,
      'frame_rate', case when media.frame_rate_denominator > 0
        then media.frame_rate_numerator::numeric / media.frame_rate_denominator else null end,
      'duration_ms', media.duration_ms
    ) end,
    'generated_variants', coalesce(variants.items, '[]'::jsonb),
    'duplicate_warning', false,
    'suggestions', coalesce(suggestions.items, '[]'::jsonb),
    'findings', case when coalesce(attempt.safe_error_code, submission.last_safe_error_code) is null
      then '[]'::jsonb else jsonb_build_array(jsonb_build_object(
        'code', coalesce(attempt.safe_error_code, submission.last_safe_error_code),
        'message', 'Processing could not complete safely.', 'severity', 'blocking')) end
  )
  from wali.submissions submission
  left join wali.processing_attempts attempt
    on attempt.submission_id = submission.id and attempt.generation = target_generation
  left join wali.wallpaper_releases release
    on release.source_submission_id = submission.id
  left join lateral (
    select staged.* from wali.release_staged_artifacts link
    join wali.staged_artifacts staged on staged.digest = link.artifact_digest
    join wali.processing_attempts verified on verified.id = staged.verified_by_attempt_id
    where link.release_id = release.id and link.role = 'video_default'
      and verified.submission_id = submission.id and verified.generation = target_generation limit 1
  ) media on true
  left join lateral (
    select jsonb_agg(jsonb_build_object('role', link.role, 'width', staged.width,
      'height', staged.height) order by link.sort_order, link.role) as items
    from wali.release_staged_artifacts link
    join wali.staged_artifacts staged on staged.digest = link.artifact_digest
    join wali.processing_attempts verified on verified.id = staged.verified_by_attempt_id
    where link.release_id = release.id
      and verified.submission_id = submission.id and verified.generation = target_generation
  ) variants on true
  left join lateral (
    select jsonb_agg(jsonb_build_object(
      'kind', 'tag', 'value', tag.label, 'confidence', suggestion.confidence,
      'model_id', suggestion.model_id, 'model_revision', suggestion.model_revision
    ) order by suggestion.confidence desc nulls last, tag.slug) as items
    from wali.submission_tag_suggestions suggestion
    join wali.tags tag on tag.id = suggestion.tag_id
    where suggestion.submission_id = submission.id and suggestion.source = 'classifier'
  ) suggestions on true
  where submission.id = target_submission_id and submission.generation = target_generation
$$;

create or replace function public.creator_metadata_v1()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor_id uuid := auth.uid(); response jsonb;
begin
  if actor_id is null or not exists (select 1 from wali.profiles profile
    where profile.id = actor_id and profile.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  select jsonb_build_object(
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', category.id, 'name', category.name, 'slug', category.slug
    ) order by category.sort_order, category.slug), '[]'::jsonb) from wali.categories category where category.active),
    'tags', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', tag.id, 'name', tag.label, 'slug', tag.slug
    ) order by tag.slug), '[]'::jsonb) from wali.tags tag where tag.active),
    'licenses', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', license.id, 'name', license.name, 'code', license.code,
      'requirements', jsonb_build_object(
        'requires_source_url', false,
        'requires_attribution', license.attribution_required,
        'requires_proof', false)
    ) order by license.code), '[]'::jsonb) from wali.licenses license
      where license.active and license.redistribution_allowed),
    'rights_bases', jsonb_build_array(
      jsonb_build_object('basis', 'original', 'available', true,
        'requires_source_url', false, 'requires_proof', false),
      jsonb_build_object('basis', 'public_domain', 'available', true,
        'requires_source_url', true, 'requires_proof', false),
      jsonb_build_object('basis', 'licensed', 'available', false,
        'requires_source_url', true, 'requires_proof', true),
      jsonb_build_object('basis', 'other', 'available', false,
        'requires_source_url', false, 'requires_proof', true)
    ),
    'current_creator_terms_version', (select config.creator_terms_version
      from wali.runtime_configuration config where config.singleton)
  ) into response;
  return response;
end $$;

create or replace function public.moderation_metadata_v1()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not wali.has_moderation_access() then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATOR_AAL2_REQUIRED';
  end if;
  return jsonb_build_object(
    'checklist_revision', 1,
    'creator_note_required', true,
    'reason_codes', jsonb_build_array(
      jsonb_build_object('code', 'policy_pass', 'label', 'Meets publication policy',
        'decisions', jsonb_build_array('approved')),
      jsonb_build_object('code', 'rights_incomplete', 'label', 'Rights information is incomplete',
        'decisions', jsonb_build_array('changes_requested', 'rejected')),
      jsonb_build_object('code', 'technical_quality', 'label', 'Canonical media quality issue',
        'decisions', jsonb_build_array('changes_requested', 'rejected')),
      jsonb_build_object('code', 'metadata_inaccurate', 'label', 'Metadata needs correction',
        'decisions', jsonb_build_array('changes_requested')),
      jsonb_build_object('code', 'unsafe_content', 'label', 'Content violates safety policy',
        'decisions', jsonb_build_array('rejected')),
      jsonb_build_object('code', 'duplicate_content', 'label', 'Duplicate or substantially similar content',
        'decisions', jsonb_build_array('changes_requested', 'rejected'))
    )
  );
end $$;

create or replace function public.creator_processing_status_v1(
  submission_id uuid, generation bigint
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor_id uuid := auth.uid(); response jsonb;
begin
  if generation not between 1 and 2147483647
     or not exists (select 1 from wali.submissions submission
       join wali.profiles profile on profile.id = submission.creator_id
       where submission.id = creator_processing_status_v1.submission_id
         and submission.creator_id = actor_id and profile.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_FOUND';
  end if;
  response := wali.creator_processing_projection(submission_id, generation::integer);
  if response is null then raise exception using errcode = 'P0001', message = 'WALI_PROCESSING_GENERATION_STALE'; end if;
  return response;
end $$;

create or replace function public.my_creator_submissions_v1(
  cursor text default null, page_limit integer default 24
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor_id uuid := auth.uid(); cursor_id uuid; cursor_time timestamptz;
  items jsonb; next_cursor text;
begin
  if page_limit not between 1 and 50
     or actor_id is null
     or not exists (select 1 from wali.profiles profile where profile.id = actor_id and profile.status = 'active')
     or not wali.has_active_role('creator') then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_ROLE_REQUIRED';
  end if;
  if cursor is not null then
    begin cursor_id := cursor::uuid; exception when others then
      raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end;
    select submission.updated_at into cursor_time from wali.submissions submission
      where submission.id = cursor_id and submission.creator_id = actor_id;
    if not found then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
  end if;
  with page as (
    select submission.* from wali.submissions submission
    where submission.creator_id = actor_id
      and (cursor_id is null or (submission.updated_at, submission.id) < (cursor_time, cursor_id))
    order by submission.updated_at desc, submission.id desc limit page_limit
  ), projected as (
    select page.id, page.updated_at, jsonb_build_object(
      'submission_id', page.id, 'wallpaper_id', page.wallpaper_id,
      'revision', page.revision, 'generation', page.generation, 'state', page.status,
      'draft', case when rights.id is null then null else jsonb_build_object(
        'title', page.proposed_title, 'description', page.proposed_description,
        'primary_category_id', page.primary_category_id,
        'suggested_tag_ids', coalesce(tags.ids, '[]'::jsonb),
        'content_warning', page.content_warning,
        'rights', jsonb_build_object(
          'basis', rights.basis, 'rights_holder', rights.rights_holder,
          'license_id', rights.license_id, 'source_url', rights.source_url,
          'attribution_text', rights.attribution_text,
          'proof_object_ids', to_jsonb(rights.proof_object_ids), 'attests_rights', true,
          'requirements', jsonb_build_object(
            'requires_source_url', rights.basis = 'public_domain',
            'requires_attribution', license.attribution_required,
            'requires_proof', false)
        )) end,
      'processing', wali.creator_processing_projection(page.id, page.generation),
      'moderation_reason_codes', coalesce(review.reason_codes, '[]'::jsonb),
      'creator_facing_note', review.public_note,
      'created_at', to_char(page.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'updated_at', to_char(page.updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ) as item
    from page
    left join wali.rights_declarations rights on rights.submission_id = page.id
    left join wali.licenses license on license.id = rights.license_id
    left join lateral (select jsonb_agg(suggestion.tag_id order by suggestion.tag_id) as ids
      from wali.submission_tag_suggestions suggestion
      where suggestion.submission_id = page.id and suggestion.source = 'creator') tags on true
    left join lateral (select to_jsonb(review_row.reason_codes) as reason_codes, review_row.public_note
      from wali.moderation_reviews review_row where review_row.submission_id = page.id
      order by review_row.created_at desc, review_row.id desc limit 1) review on true
  ) select coalesce(jsonb_agg(item order by updated_at desc, id desc), '[]'::jsonb),
      case when count(*) = page_limit then (array_agg(id order by updated_at desc, id desc))[count(*)]::text else null end
    into items, next_cursor from projected;
  return jsonb_build_object('items', items, 'next_cursor', next_cursor);
end $$;

create or replace function public.moderation_queue_v1(
  actor_id uuid, actor_aal text,
  queue_status text default 'pending', queue_sort text default 'oldest_submitted',
  cursor text default null, page_limit integer default 24
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare cursor_id uuid; cursor_time timestamptz; items jsonb; next_cursor text;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if actor_aal <> 'aal2' or not exists (select 1 from wali.profiles profile
       where profile.id = actor_id and profile.status = 'active')
     or not (wali.edge_actor_has_role(actor_id, 'moderator') or wali.edge_actor_has_role(actor_id, 'admin')) then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATOR_AAL2_REQUIRED';
  end if;
  if queue_status not in ('pending', 'under_review') or queue_sort not in ('oldest_submitted', 'newest_submitted', 'risk_priority')
     or page_limit not between 1 and 50 then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  if cursor is not null then
    begin cursor_id := cursor::uuid; exception when others then
      raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end;
    select submission.submitted_at into cursor_time from wali.submissions submission where submission.id = cursor_id;
    if not found then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
  end if;
  with page as (
    select submission.* from wali.submissions submission
    where (case when queue_status = 'pending' then submission.status in ('submitted', 'under_review')
      else submission.status = 'under_review' end)
      and (cursor_id is null or case when queue_sort = 'newest_submitted'
        then (submission.submitted_at, submission.id) < (cursor_time, cursor_id)
        else (submission.submitted_at, submission.id) > (cursor_time, cursor_id) end)
    order by
      case when queue_sort = 'newest_submitted' then submission.submitted_at end desc,
      case when queue_sort <> 'newest_submitted' then submission.submitted_at end asc,
      submission.id asc limit page_limit
  ), projected as (
    select page.id, page.submitted_at, jsonb_build_object(
      'submission_id', page.id, 'revision', page.revision, 'generation', page.generation,
      'creator', jsonb_build_object('id', creator.id, 'handle', creator.handle::text,
        'display_name', creator.display_name),
      'proposed_title', page.proposed_title, 'proposed_description', page.proposed_description,
      'primary_category_name', category.name,
      'tag_names', coalesce(tags.names, '[]'::jsonb),
      'content_rating', page.content_rating_warning,
      'attribution_text', page.attribution_text, 'source_url', page.source_url,
      'rights_summary', rights.basis::text || ' · ' || license.name,
      'proof_status', 'not_required',
      'canonical_artifacts', coalesce(artifacts.items, '[]'::jsonb),
      'media_facts', wali.creator_processing_projection(page.id, page.generation) -> 'media_facts',
      'findings', wali.creator_processing_projection(page.id, page.generation) -> 'findings',
      'model_suggestions', wali.creator_processing_projection(page.id, page.generation) -> 'suggestions',
      'submitted_at', to_char(page.submitted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ) as item
    from page join wali.profiles creator on creator.id = page.creator_id
    join wali.categories category on category.id = page.primary_category_id
    join wali.rights_declarations rights on rights.submission_id = page.id
    join wali.licenses license on license.id = rights.license_id
    left join lateral (select jsonb_agg(tag.label order by tag.slug) as names
      from wali.submission_tag_suggestions suggestion join wali.tags tag on tag.id = suggestion.tag_id
      where suggestion.submission_id = page.id and suggestion.source = 'creator') tags on true
    left join lateral (select jsonb_agg(jsonb_build_object(
      'role', link.role, 'storage_path', staged.storage_path,
      'sha256', staged.digest, 'byte_count', staged.byte_count,
      'media_type', staged.media_type, 'width', staged.width, 'height', staged.height,
      'duration_ms', coalesce(staged.duration_ms, 0)
    ) order by link.sort_order, link.role) as items
      from wali.wallpaper_releases release
      join wali.release_staged_artifacts link on link.release_id = release.id
      join wali.staged_artifacts staged on staged.digest = link.artifact_digest
      join wali.processing_attempts verified on verified.id = staged.verified_by_attempt_id
      where release.source_submission_id = page.id
        and verified.submission_id = page.id and verified.generation = page.generation) artifacts on true
  ) select coalesce(jsonb_agg(item order by
        case when queue_sort = 'newest_submitted' then submitted_at end desc,
        case when queue_sort <> 'newest_submitted' then submitted_at end asc,
        id
      ), '[]'::jsonb),
      case when count(*) = page_limit then (array_agg(id order by
        case when queue_sort = 'newest_submitted' then submitted_at end desc,
        case when queue_sort <> 'newest_submitted' then submitted_at end asc,
        id
      ))[count(*)]::text else null end
    into items, next_cursor from projected;
  return jsonb_build_object('items', items, 'next_cursor', next_cursor);
end $$;

create or replace function public.moderation_reports_v1(
  actor_id uuid, actor_aal text, cursor text default null, page_limit integer default 24
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare cursor_id uuid; cursor_time timestamptz; items jsonb; next_cursor text;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if actor_aal <> 'aal2' or not exists (select 1 from wali.profiles profile
       where profile.id = actor_id and profile.status = 'active')
     or not (wali.edge_actor_has_role(actor_id, 'moderator') or wali.edge_actor_has_role(actor_id, 'admin')) then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATOR_AAL2_REQUIRED';
  end if;
  if page_limit not between 1 and 50 then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  if cursor is not null then
    begin cursor_id := cursor::uuid; exception when others then
      raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end;
    select report.created_at into cursor_time from wali.reports report where report.id = cursor_id;
    if not found then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
  end if;
  with page as (
    select report.* from wali.reports report where report.status in ('open', 'triaged', 'appealed')
      and (cursor_id is null or (report.created_at, report.id) > (cursor_time, cursor_id))
    order by report.created_at, report.id limit page_limit
  ) select coalesce(jsonb_agg(jsonb_build_object(
      'report_id', page.id, 'revision', 1, 'reason_code', page.kind,
      'safe_summary', left(page.detail, 500),
      'created_at', to_char(page.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ) order by page.created_at, page.id), '[]'::jsonb),
    case when count(*) = page_limit then (array_agg(page.id order by page.created_at, page.id))[count(*)]::text else null end
    into items, next_cursor from page;
  return jsonb_build_object('items', items, 'next_cursor', next_cursor);
end $$;

revoke execute on function public.request_install_v1(uuid, uuid, bigint, text) from public, anon, authenticated;

do $privileges$
declare function_row record;
begin
  for function_row in select p.oid::regprocedure signature from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'wali_edge_%'
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', function_row.signature);
    execute format('grant execute on function %s to service_role', function_row.signature);
  end loop;
end $privileges$;

do $privileges$
declare function_row record;
begin
  for function_row in select p.oid::regprocedure signature from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace where n.nspname = 'wali'
  loop execute format('revoke execute on function %s from public, anon, authenticated', function_row.signature); end loop;
end $privileges$;
grant execute on function wali.current_user_id() to authenticated;
grant execute on function wali.current_aal() to authenticated;
grant execute on function wali.has_active_role(wali.role_name) to authenticated;
grant execute on function wali.has_moderation_access() to authenticated;
grant execute on function wali.can_insert_rights_proof(text) to authenticated;
grant execute on function wali.encode_catalog_cursor(timestamptz, uuid, numeric, text) to anon, authenticated;
grant execute on function wali.decode_catalog_cursor(text) to anon, authenticated;
grant execute on function wali.moderator_can_preview_canonical(text, text) to authenticated;
revoke execute on function public.creator_authorization_v1() from public, anon;
grant execute on function public.creator_authorization_v1() to authenticated;
revoke execute on function public.creator_metadata_v1() from public, anon;
revoke execute on function public.creator_processing_status_v1(uuid, bigint) from public, anon;
revoke execute on function public.moderation_metadata_v1() from public, anon;
revoke execute on function public.my_creator_submissions_v1(text, integer) from public, anon;
revoke execute on function public.moderation_queue_v1(uuid, text, text, text, text, integer) from public, anon, authenticated;
revoke execute on function public.moderation_reports_v1(uuid, text, text, integer) from public, anon, authenticated;
grant execute on function public.creator_metadata_v1() to authenticated;
grant execute on function public.creator_processing_status_v1(uuid, bigint) to authenticated;
grant execute on function public.moderation_metadata_v1() to authenticated;
grant execute on function public.my_creator_submissions_v1(text, integer) to authenticated;
grant execute on function public.moderation_queue_v1(uuid, text, text, text, text, integer) to service_role;
grant execute on function public.moderation_reports_v1(uuid, text, text, integer) to service_role;

grant execute on function wali.storage_worker_can_select(text, text, text) to wali_storage_worker;
grant execute on function wali.storage_worker_can_insert(text, text, text) to wali_storage_worker;
grant execute on function wali.storage_worker_can_delete(text, text, text) to wali_storage_worker;
grant execute on function wali.transition_submission(uuid, wali.submission_status, bigint, uuid) to service_role;
grant execute on function wali.record_moderation_decision(uuid, wali.review_decision, bigint, uuid, text, text, text[]) to service_role;
grant execute on function wali.advance_processing_attempt(uuid, wali.processing_status, wali.processing_status, text, integer, jsonb, text) to service_role;
grant execute on function wali.refresh_marketplace_aggregates(timestamptz) to service_role;
grant execute on function wali.fail_queue_message(text, bigint, integer, jsonb, text) to service_role;
grant execute on function wali.recover_stale_processing_attempts(timestamptz) to service_role;
grant execute on function wali.expire_account_exports(timestamptz) to service_role;
grant execute on function wali.cleanup_expired_marketplace_objects(timestamptz) to service_role;
grant execute on function wali.enqueue_object_cleanup(text, text, text) to service_role;
grant execute on function wali.observe_orphan_catalog_objects(timestamptz) to service_role;
grant execute on function wali.enqueue_backup_verification(timestamptz) to service_role;
grant execute on function public.wali_edge_catalog_security_state_v1() to anon, authenticated;

grant execute on function wali.worker_queue_read(text, integer) to wali_worker, service_role;
grant execute on function wali.worker_queue_ack(text, bigint) to wali_worker, service_role;
grant execute on function wali.worker_queue_nack(text, bigint, integer) to wali_worker, service_role;
grant execute on function wali.worker_queue_reject(text, bigint) to wali_worker, service_role;
grant execute on function wali.worker_enqueue_cleanup(text, text) to wali_worker, service_role;
grant execute on function wali.worker_begin_attempt(uuid, uuid, integer, text, timestamptz) to wali_worker, service_role;
grant execute on function wali.worker_heartbeat_attempt(uuid, integer, text, timestamptz) to wali_worker, service_role;
grant execute on function wali.worker_read_classification_input(uuid, integer, text) to wali_worker, service_role;
grant execute on function wali.worker_authorize_staged_artifact(uuid, integer, text, jsonb) to wali_worker, service_role;
grant execute on function wali.worker_complete_attempt(uuid, integer, text, jsonb) to wali_worker, service_role;
grant execute on function wali.worker_fail_attempt(uuid, integer, text, text) to wali_worker, service_role;
grant execute on function wali.worker_begin_promotion(uuid, text, timestamptz) to wali_worker, service_role;
grant execute on function wali.worker_complete_promotion(uuid, text, jsonb) to wali_worker, service_role;
grant execute on function wali.worker_fail_promotion(uuid, text, text) to wali_worker, service_role;
grant execute on function wali.worker_begin_export(uuid, uuid, text, timestamptz) to wali_worker, service_role;
grant execute on function wali.worker_read_account_export(uuid, uuid, text) to wali_worker, service_role;
grant execute on function wali.worker_complete_export(uuid, uuid, text, bigint, text) to wali_worker, service_role;
grant execute on function wali.worker_fail_export(uuid, uuid, text, text) to wali_worker, service_role;
grant execute on function wali.worker_begin_cleanup(uuid, text, timestamptz) to wali_worker, service_role;
grant execute on function wali.worker_complete_cleanup(uuid, text) to wali_worker, service_role;
grant execute on function wali.worker_fail_cleanup(uuid, text, text) to wali_worker, service_role;
grant execute on function wali.worker_begin_backup_verification(uuid, text, timestamptz) to wali_worker, service_role;
grant execute on function wali.worker_read_backup_verification_targets(uuid, text, text, integer) to wali_worker, service_role;
grant execute on function wali.worker_complete_backup_verification(uuid, text, bigint, bigint, text) to wali_worker, service_role;
grant execute on function wali.worker_fail_backup_verification(uuid, text, text) to wali_worker, service_role;
grant execute on function wali.worker_begin_account_deletion(uuid, uuid, text, timestamptz) to wali_worker, service_role;
grant execute on function wali.worker_complete_account_deletion(uuid, uuid, text) to wali_worker, service_role;
grant execute on function wali.worker_fail_account_deletion(uuid, uuid, text, text) to wali_worker, service_role;
