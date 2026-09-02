-- WALI Marketplace foundation: upload sessions, creator submissions, processing, and idempotent state commands.

create table wali.upload_sessions (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references wali.profiles(id) on delete restrict,
  storage_path text not null unique,
  original_filename text not null,
  declared_byte_count bigint not null check (declared_byte_count between 1 and 1073741824),
  received_byte_count bigint,
  source_digest text,
  detected_media_type text,
  status wali.upload_status not null default 'issued',
  expires_at timestamptz not null,
  completed_at timestamptz,
  idempotency_key text not null,
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (creator_id, idempotency_key),
  constraint upload_sessions_path_opaque check (
    storage_path = ('uploads/' || id::text || '/source')
  ),
  constraint upload_sessions_filename_private check (
    wali.plain_text_is_valid(original_filename, 1, 255) and original_filename !~ '[/\\]'
  ),
  constraint upload_sessions_received_bound check (
    received_byte_count is null or received_byte_count between 1 and declared_byte_count
  ),
  constraint upload_sessions_digest check (source_digest is null or source_digest ~ '^[0-9a-f]{64}$'),
  constraint upload_sessions_media_type check (
    detected_media_type is null or detected_media_type in ('video/mp4', 'video/quicktime')
  ),
  constraint upload_sessions_completion check (
    (status = 'completed') =
    (completed_at is not null and received_byte_count is not null and source_digest is not null and detected_media_type is not null)
  ),
  constraint upload_sessions_expiry check (expires_at > created_at)
);

create table wali.submissions (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references wali.profiles(id) on delete restrict,
  wallpaper_id uuid references wali.wallpapers(id) on delete restrict,
  proposed_title text not null,
  proposed_description text not null,
  primary_category_id uuid not null references wali.categories(id) on delete restrict,
  license_id uuid not null references wali.licenses(id) on delete restrict,
  rights_holder text not null,
  attribution_text text,
  source_url text,
  content_rating_warning wali.content_rating not null default 'everyone',
  upload_session_id uuid not null unique references wali.upload_sessions(id) on delete restrict,
  status wali.submission_status not null default 'draft',
  generation integer not null default 1 check (generation > 0),
  revision bigint not null default 1 check (revision > 0),
  submitted_at timestamptz,
  decided_at timestamptz,
  last_safe_error_code text,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint submissions_title_plain check (wali.plain_text_is_valid(proposed_title, 1, 120)),
  constraint submissions_description_plain check (wali.plain_text_is_valid(proposed_description, 1, 2000)),
  constraint submissions_rights_holder_plain check (wali.plain_text_is_valid(rights_holder, 1, 160)),
  constraint submissions_attribution_plain check (
    attribution_text is null or wali.plain_text_is_valid(attribution_text, 1, 500)
  ),
  constraint submissions_source_https check (wali.https_url_is_valid(source_url)),
  constraint submissions_safe_error_format check (
    last_safe_error_code is null or last_safe_error_code ~ '^WALI_[A-Z0-9_]{2,96}$'
  ),
  constraint submissions_submit_timestamp check (
    status not in ('submitted', 'under_review', 'changes_requested', 'approved', 'rejected', 'published')
    or submitted_at is not null
  ),
  constraint submissions_decision_timestamp check (
    status not in ('approved', 'rejected', 'published') or decided_at is not null
  )
);

create table wali.rights_declarations (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null unique references wali.submissions(id) on delete restrict,
  basis wali.rights_basis not null,
  rights_holder text not null,
  license_id uuid not null references wali.licenses(id) on delete restrict,
  source_url text,
  attribution_text text,
  proof_storage_path text,
  attested_at timestamptz not null,
  creator_terms_version text not null,
  review_status wali.rights_review_status not null default 'pending',
  reviewed_by uuid references wali.profiles(id) on delete restrict,
  reviewed_at timestamptz,
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint rights_holder_plain check (wali.plain_text_is_valid(rights_holder, 1, 160)),
  constraint rights_source_https check (wali.https_url_is_valid(source_url)),
  constraint rights_attribution_plain check (
    attribution_text is null or wali.plain_text_is_valid(attribution_text, 1, 500)
  ),
  constraint rights_proof_generated check (
    proof_storage_path is null or proof_storage_path ~ '^rights/[0-9a-f-]{36}/[0-9a-f-]{36}/proof\.[a-z0-9]{2,8}$'
  ),
  constraint rights_external_source check (basis not in ('licensed', 'public_domain') or source_url is not null),
  constraint rights_review_pair check (
    (review_status = 'pending') = (reviewed_by is null and reviewed_at is null)
  )
);

create table wali.processing_attempts (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references wali.submissions(id) on delete restrict,
  generation integer not null check (generation > 0),
  queue_message_id bigint,
  status wali.processing_status not null default 'queued',
  lease_owner text,
  lease_expires_at timestamptz,
  worker_build text,
  media_image_digest text,
  classifier_image_digest text,
  safe_error_code text,
  started_at timestamptz,
  finished_at timestamptz,
  output_summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (submission_id, generation),
  constraint processing_attempts_lease_pair check ((lease_owner is null) = (lease_expires_at is null)),
  constraint processing_attempts_worker_plain check (
    worker_build is null or wali.plain_text_is_valid(worker_build, 1, 128)
  ),
  constraint processing_attempts_media_digest check (
    media_image_digest is null or media_image_digest ~ '^[0-9a-f]{64}$'
  ),
  constraint processing_attempts_classifier_digest check (
    classifier_image_digest is null or classifier_image_digest ~ '^[0-9a-f]{64}$'
  ),
  constraint processing_attempts_safe_error check (
    safe_error_code is null or safe_error_code ~ '^WALI_[A-Z0-9_]{2,96}$'
  ),
  constraint processing_attempts_output_object check (
    jsonb_typeof(output_summary) = 'object' and octet_length(output_summary::text) <= 32768
  ),
  constraint processing_attempts_terminal_time check (
    status not in ('completed', 'failed', 'timed_out') or finished_at is not null
  )
);

create unique index processing_attempts_one_active
  on wali.processing_attempts (submission_id)
  where status in ('queued', 'leased', 'downloading', 'transcoding', 'verifying', 'classifying');

create table wali.model_registry (
  model_id text not null,
  model_revision text not null,
  task text not null,
  source_url text not null,
  upstream_license text not null,
  artifact_digest text not null,
  embedding_dimension integer,
  taxonomy_revision text,
  approved_labels jsonb not null default '[]'::jsonb,
  approved_by uuid references wali.profiles(id) on delete restrict,
  approved_at timestamptz,
  status wali.model_status not null default 'pending',
  created_at timestamptz not null default statement_timestamp(),
  primary key (model_id, model_revision),
  constraint model_registry_id check (model_id ~ '^[a-z0-9][a-z0-9._/-]{1,127}$'),
  constraint model_registry_revision check (char_length(model_revision) between 1 and 128),
  constraint model_registry_task check (task in ('classification', 'embedding')),
  constraint model_registry_source_https check (wali.https_url_is_valid(source_url)),
  constraint model_registry_license check (upstream_license ~ '^[A-Za-z0-9.+-]{2,64}$'),
  constraint model_registry_digest check (artifact_digest ~ '^[0-9a-f]{64}$'),
  constraint model_registry_dimension check (embedding_dimension is null or embedding_dimension between 1 and 4096),
  constraint model_registry_labels check (
    jsonb_typeof(approved_labels) = 'array' and jsonb_array_length(approved_labels) <= 512
  ),
  constraint model_registry_approval check (
    status <> 'active' or (approved_by is not null and approved_at is not null)
  )
);

create table wali.classification_runs (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references wali.processing_attempts(id) on delete restrict,
  model_id text not null,
  model_revision text not null,
  model_artifact_digest text not null,
  input_frame_set_digest text not null,
  status wali.classification_status not null default 'queued',
  started_at timestamptz,
  finished_at timestamptz,
  raw_result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default statement_timestamp(),
  unique (attempt_id, model_id, model_revision),
  foreign key (model_id, model_revision) references wali.model_registry(model_id, model_revision) on delete restrict,
  constraint classification_model_digest check (model_artifact_digest ~ '^[0-9a-f]{64}$'),
  constraint classification_frames_digest check (input_frame_set_digest ~ '^[0-9a-f]{64}$'),
  constraint classification_result_object check (
    jsonb_typeof(raw_result) = 'object' and octet_length(raw_result::text) <= 65536
  ),
  constraint classification_terminal_time check (
    status not in ('completed', 'failed') or finished_at is not null
  )
);

create table wali.command_idempotency (
  actor_id uuid not null,
  operation text not null,
  idempotency_key text not null,
  request_digest text not null,
  status text not null default 'in_progress',
  response jsonb,
  expires_at timestamptz not null default statement_timestamp() + interval '24 hours',
  created_at timestamptz not null default statement_timestamp(),
  completed_at timestamptz,
  primary key (actor_id, operation, idempotency_key),
  constraint idempotency_operation_format check (operation ~ '^[a-z][a-z0-9_.]{2,95}$'),
  constraint idempotency_key_format check (
    char_length(idempotency_key) between 16 and 64
    and idempotency_key ~ '^[A-Za-z0-9_-]+$'
  ),
  constraint idempotency_request_digest check (request_digest ~ '^[0-9a-f]{64}$'),
  constraint idempotency_status check (status in ('in_progress', 'completed')),
  constraint idempotency_response_object check (
    response is null or (jsonb_typeof(response) = 'object' and octet_length(response::text) <= 32768)
  ),
  constraint idempotency_completion_pair check ((status = 'completed') = (response is not null and completed_at is not null))
);

alter table wali.wallpaper_releases
  add constraint releases_source_submission_fk
  foreign key (source_submission_id) references wali.submissions(id) on delete restrict;
alter table wali.artifacts
  add constraint artifacts_verified_attempt_fk
  foreign key (verified_by_attempt_id) references wali.processing_attempts(id) on delete restrict;
alter table wali.wallpaper_embeddings
  add constraint wallpaper_embeddings_model_fk
  foreign key (model_id, model_revision) references wali.model_registry(model_id, model_revision) on delete restrict;
alter table wali.wallpaper_categories
  add constraint wallpaper_categories_model_run_fk
  foreign key (model_run_id) references wali.classification_runs(id) on delete restrict;
alter table wali.wallpaper_tags
  add constraint wallpaper_tags_model_run_fk
  foreign key (model_run_id) references wali.classification_runs(id) on delete restrict;

create index upload_sessions_creator_status_idx on wali.upload_sessions (creator_id, status, created_at desc);
create index submissions_creator_status_idx on wali.submissions (creator_id, status, updated_at desc, id);
create index submissions_review_queue_idx on wali.submissions (status, submitted_at, id)
  where status in ('submitted', 'under_review');
create index processing_attempts_status_idx on wali.processing_attempts (status, created_at, id);
create index command_idempotency_expiry_idx on wali.command_idempotency (expires_at);

create trigger upload_sessions_touch before update on wali.upload_sessions
for each row execute function wali.touch_mutable_row();
create trigger submissions_touch before update on wali.submissions
for each row execute function wali.touch_mutable_row();
create trigger rights_declarations_touch before update on wali.rights_declarations
for each row execute function wali.touch_mutable_row();
create trigger processing_attempts_touch before update on wali.processing_attempts
for each row execute function wali.touch_mutable_row();

create or replace function wali.submission_transition_allowed(
  old_status wali.submission_status,
  new_status wali.submission_status
) returns boolean
language sql
immutable
set search_path = ''
as $$
  select (old_status, new_status) in (
    ('draft', 'uploading'), ('draft', 'withdrawn'),
    ('uploading', 'uploaded'), ('uploading', 'withdrawn'),
    ('uploaded', 'processing'), ('uploaded', 'withdrawn'),
    ('processing', 'ready_for_submission'), ('processing', 'processing_failed'),
    ('processing_failed', 'processing'), ('processing_failed', 'withdrawn'),
    ('ready_for_submission', 'submitted'), ('ready_for_submission', 'withdrawn'),
    ('submitted', 'under_review'),
    ('under_review', 'changes_requested'), ('under_review', 'approved'), ('under_review', 'rejected'),
    ('changes_requested', 'draft'), ('changes_requested', 'withdrawn'),
    ('approved', 'published')
  )
$$;

create or replace function wali.reserve_command(
  command_actor uuid,
  command_operation text,
  command_key text,
  command_digest text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing wali.command_idempotency%rowtype;
begin
  select * into existing
    from wali.command_idempotency
   where actor_id = command_actor and operation = command_operation and idempotency_key = command_key
   for update;

  if found then
    if existing.request_digest <> command_digest then
      raise exception using errcode = 'P0001', message = 'WALI_IDEMPOTENCY_CONFLICT';
    end if;
    if existing.status = 'completed' then
      return existing.response || jsonb_build_object('replayed', true);
    end if;
    raise exception using errcode = 'P0001', message = 'WALI_COMMAND_IN_PROGRESS';
  end if;

  insert into wali.command_idempotency (actor_id, operation, idempotency_key, request_digest)
  values (command_actor, command_operation, command_key, command_digest);
  return null;
end
$$;

create or replace function wali.complete_command(
  command_actor uuid,
  command_operation text,
  command_key text,
  command_response jsonb
) returns void
language sql
security definer
set search_path = ''
as $$
  update wali.command_idempotency
     set status = 'completed', response = command_response, completed_at = statement_timestamp()
   where actor_id = command_actor and operation = command_operation and idempotency_key = command_key
$$;

create or replace function wali.transition_submission(
  target_submission_id uuid,
  target_status wali.submission_status,
  expected_revision bigint,
  command_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  command_actor uuid;
  request_hash text;
  replay jsonb;
  current_row wali.submissions%rowtype;
  result jsonb;
  service_call boolean := auth.role() = 'service_role';
begin
  command_actor := coalesce(actor, '00000000-0000-0000-0000-000000000000'::uuid);
  request_hash := encode(extensions.digest(
    target_submission_id::text || ':' || target_status::text || ':' || expected_revision::text,
    'sha256'
  ), 'hex');
  replay := wali.reserve_command(command_actor, 'transition_submission', command_key::text, request_hash);
  if replay is not null then return replay; end if;

  select * into current_row from wali.submissions where id = target_submission_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_FOUND';
  end if;
  if current_row.revision <> expected_revision then
    raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH';
  end if;
  if not wali.submission_transition_allowed(current_row.status, target_status) then
    raise exception using errcode = 'P0001', message = 'WALI_INVALID_TRANSITION';
  end if;

  if not service_call then
    if actor is null then
      raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED';
    end if;
    if current_row.creator_id = actor then
      if target_status not in ('uploading', 'withdrawn', 'submitted', 'draft') then
        raise exception using errcode = 'P0001', message = 'WALI_FORBIDDEN';
      end if;
    elsif wali.has_moderation_access() then
      if target_status <> 'under_review' then
        raise exception using errcode = 'P0001', message = 'WALI_FORBIDDEN';
      end if;
    else
      raise exception using errcode = 'P0001', message = 'WALI_FORBIDDEN';
    end if;
  end if;

  if target_status = 'submitted' then
    if not exists (
      select 1 from wali.processing_attempts pa
       where pa.submission_id = current_row.id and pa.generation = current_row.generation and pa.status = 'completed'
    ) or not exists (
      select 1 from wali.rights_declarations rd
       where rd.submission_id = current_row.id and rd.review_status = 'approved'
    ) then
      raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_READY';
    end if;
  end if;

  update wali.submissions
     set status = target_status,
         submitted_at = case when target_status = 'submitted' then statement_timestamp() else submitted_at end,
         decided_at = case when target_status in ('approved', 'rejected', 'published') then statement_timestamp() else decided_at end
   where id = current_row.id
  returning jsonb_build_object('id', id, 'status', status, 'revision', revision, 'replayed', false) into result;

  perform wali.complete_command(command_actor, 'transition_submission', command_key::text, result);
  return result;
end
$$;

create or replace function wali.advance_processing_attempt(
  target_attempt_id uuid,
  expected_status wali.processing_status,
  target_status wali.processing_status,
  worker_identity text,
  expected_generation integer,
  new_output_summary jsonb,
  new_safe_error_code text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  attempt_row wali.processing_attempts%rowtype;
  submission_row wali.submissions%rowtype;
  result jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if not wali.plain_text_is_valid(worker_identity, 1, 128) then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_IDENTITY_INVALID';
  end if;

  select * into attempt_row from wali.processing_attempts where id = target_attempt_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_ATTEMPT_NOT_FOUND'; end if;
  select * into submission_row from wali.submissions where id = attempt_row.submission_id for update;

  if attempt_row.generation <> expected_generation or submission_row.generation <> expected_generation then
    raise exception using errcode = 'P0001', message = 'WALI_STALE_PROCESSING_GENERATION';
  end if;
  if attempt_row.status <> expected_status then
    raise exception using errcode = 'P0001', message = 'WALI_ATTEMPT_STATE_MISMATCH';
  end if;
  if jsonb_typeof(new_output_summary) <> 'object' or octet_length(new_output_summary::text) > 32768 then
    raise exception using errcode = 'P0001', message = 'WALI_OUTPUT_SUMMARY_INVALID';
  end if;

  update wali.processing_attempts
     set status = target_status,
         lease_owner = case when target_status in ('leased', 'downloading', 'transcoding', 'verifying', 'classifying') then worker_identity else null end,
         lease_expires_at = case when target_status in ('leased', 'downloading', 'transcoding', 'verifying', 'classifying') then statement_timestamp() + interval '5 minutes' else null end,
         output_summary = new_output_summary,
         safe_error_code = new_safe_error_code,
         started_at = coalesce(started_at, statement_timestamp()),
         finished_at = case when target_status in ('completed', 'failed', 'timed_out') then statement_timestamp() else null end
   where id = target_attempt_id
  returning jsonb_build_object('id', id, 'status', status, 'generation', generation) into result;

  if target_status = 'completed' then
    update wali.submissions set status = 'ready_for_submission', last_safe_error_code = null
     where id = submission_row.id and generation = expected_generation;
  elsif target_status in ('failed', 'timed_out') then
    update wali.submissions set status = 'processing_failed', last_safe_error_code = new_safe_error_code
     where id = submission_row.id and generation = expected_generation;
  end if;
  return result;
end
$$;

alter table wali.upload_sessions enable row level security;
alter table wali.submissions enable row level security;
alter table wali.rights_declarations enable row level security;
alter table wali.processing_attempts enable row level security;
alter table wali.classification_runs enable row level security;
alter table wali.model_registry enable row level security;
alter table wali.command_idempotency enable row level security;

create policy upload_sessions_owner_read on wali.upload_sessions for select to authenticated
using (creator_id = auth.uid());
create policy submissions_owner_read on wali.submissions for select to authenticated
using (creator_id = auth.uid());
create policy submissions_owner_draft_update on wali.submissions for update to authenticated
using (creator_id = auth.uid() and status in ('draft', 'changes_requested'))
with check (creator_id = auth.uid() and status in ('draft', 'changes_requested'));
create policy model_registry_active_read on wali.model_registry for select to anon, authenticated
using (status = 'active');

grant select on wali.upload_sessions, wali.submissions to authenticated;
grant update (
  proposed_title, proposed_description, primary_category_id, license_id, rights_holder,
  attribution_text, source_url, content_rating_warning
) on wali.submissions to authenticated;
grant select on wali.model_registry to anon, authenticated;
grant execute on function wali.transition_submission(uuid, wali.submission_status, bigint, uuid) to authenticated, service_role;
grant execute on function wali.advance_processing_attempt(uuid, wali.processing_status, wali.processing_status, text, integer, jsonb, text) to service_role;

grant all on wali.upload_sessions, wali.submissions, wali.rights_declarations,
  wali.processing_attempts, wali.classification_runs, wali.model_registry,
  wali.command_idempotency to service_role;

revoke all on function wali.submission_transition_allowed(wali.submission_status, wali.submission_status) from public, anon, authenticated;
revoke all on function wali.reserve_command(uuid, text, text, text) from public, anon, authenticated;
revoke all on function wali.complete_command(uuid, text, text, jsonb) from public, anon, authenticated;
