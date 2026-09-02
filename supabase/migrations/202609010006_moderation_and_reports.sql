-- WALI Marketplace foundation: moderation, reports, signing metadata, revocations, and append-only audit.

create table wali.catalog_signing_keys (
  key_id text primary key,
  public_key bytea not null,
  valid_from timestamptz not null,
  valid_until timestamptz,
  status wali.signing_key_status not null default 'pending',
  rotated_from_key_id text references wali.catalog_signing_keys(key_id) on delete restrict,
  activated_by uuid references wali.profiles(id) on delete restrict,
  activated_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  constraint signing_keys_id_format check (key_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$'),
  constraint signing_keys_ed25519_size check (octet_length(public_key) = 32),
  constraint signing_keys_window check (valid_until is null or valid_until > valid_from),
  constraint signing_keys_activation check (
    status <> 'active' or (activated_by is not null and activated_at is not null)
  )
);

alter table wali.wallpaper_releases
  add constraint releases_signing_key_fk
  foreign key (signing_key_id) references wali.catalog_signing_keys(key_id) on delete restrict;

create table wali.moderation_reviews (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references wali.submissions(id) on delete restrict,
  moderator_id uuid not null references wali.profiles(id) on delete restrict,
  decision wali.review_decision not null,
  public_note text not null,
  private_note text,
  checklist_revision integer not null check (checklist_revision > 0),
  reason_codes text[] not null default '{}',
  request_id uuid not null,
  created_at timestamptz not null default statement_timestamp(),
  unique (moderator_id, request_id),
  constraint moderation_public_note_plain check (wali.plain_text_is_valid(public_note, 1, 2000)),
  constraint moderation_private_note_plain check (
    private_note is null or wali.plain_text_is_valid(private_note, 1, 4000)
  ),
  constraint moderation_reason_count check (cardinality(reason_codes) between 1 and 20)
);

create table wali.moderation_actions (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references wali.profiles(id) on delete restrict,
  action text not null,
  target_type wali.moderation_target_type not null,
  target_id uuid not null,
  reason_code text not null,
  request_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default statement_timestamp(),
  constraint moderation_action_name check (action ~ '^[a-z][a-z0-9_.]{2,95}$'),
  constraint moderation_reason_code check (reason_code ~ '^[a-z][a-z0-9_.-]{2,95}$'),
  constraint moderation_metadata_object check (
    jsonb_typeof(metadata) = 'object' and octet_length(metadata::text) <= 16384
  )
);

create table wali.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references wali.profiles(id) on delete set null,
  wallpaper_id uuid not null references wali.wallpapers(id) on delete restrict,
  release_id uuid references wali.wallpaper_releases(id) on delete restrict,
  kind wali.report_kind not null,
  detail text not null,
  status wali.case_status not null default 'open',
  assigned_moderator_id uuid references wali.profiles(id) on delete restrict,
  resolution_code text,
  resolved_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint reports_detail_plain check (wali.plain_text_is_valid(detail, 1, 2000)),
  constraint reports_resolution_code check (
    resolution_code is null or resolution_code ~ '^[a-z][a-z0-9_.-]{2,95}$'
  ),
  constraint reports_resolution_pair check ((status = 'closed') = (resolution_code is not null and resolved_at is not null))
);

create table wali.copyright_cases (
  id uuid primary key default gen_random_uuid(),
  target_wallpaper_id uuid not null references wali.wallpapers(id) on delete restrict,
  target_release_id uuid references wali.wallpaper_releases(id) on delete restrict,
  claimant_name text not null,
  claimant_email text not null,
  claimant_address text,
  notice_storage_path text not null,
  counter_notice_storage_path text,
  status wali.case_status not null default 'open',
  received_at timestamptz not null,
  action_due_at timestamptz,
  counter_notice_received_at timestamptz,
  assigned_reviewer_id uuid references wali.profiles(id) on delete restrict,
  resulting_action text,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint copyright_claimant_name_plain check (wali.plain_text_is_valid(claimant_name, 1, 160)),
  constraint copyright_claimant_email_format check (
    char_length(claimant_email) between 3 and 320 and claimant_email ~ '^[^[:space:]@]+@[^[:space:]@]+$'
  ),
  constraint copyright_notice_path check (
    notice_storage_path ~ '^copyright/[0-9a-f-]{36}/notice\.[a-z0-9]{2,8}$'
  ),
  constraint copyright_counter_path check (
    counter_notice_storage_path is null or counter_notice_storage_path ~ '^copyright/[0-9a-f-]{36}/counter-notice\.[a-z0-9]{2,8}$'
  )
);

create table wali.catalog_revocations (
  id uuid primary key default gen_random_uuid(),
  release_id uuid not null references wali.wallpaper_releases(id) on delete restrict,
  artifact_digest text not null references wali.artifacts(digest) on delete restrict,
  reason wali.revocation_reason not null,
  issued_at timestamptz not null,
  signing_key_id text not null references wali.catalog_signing_keys(key_id) on delete restrict,
  signature_batch_revision bigint not null check (signature_batch_revision > 0),
  request_id uuid not null unique,
  created_at timestamptz not null default statement_timestamp(),
  unique (release_id, artifact_digest)
);

create table wali.audit_events (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references wali.profiles(id) on delete set null,
  action text not null,
  target_type wali.moderation_target_type not null,
  target_id uuid not null,
  request_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default statement_timestamp(),
  constraint audit_action_name check (action ~ '^[a-z][a-z0-9_.]{2,95}$'),
  constraint audit_metadata_object check (
    jsonb_typeof(metadata) = 'object' and octet_length(metadata::text) <= 16384
  )
);

create index moderation_reviews_submission_idx on wali.moderation_reviews (submission_id, created_at desc, id);
create index moderation_actions_target_idx on wali.moderation_actions (target_type, target_id, created_at desc, id);
create index reports_open_idx on wali.reports (status, created_at, id) where status in ('open', 'triaged', 'appealed');
create index copyright_cases_open_idx on wali.copyright_cases (status, action_due_at, id) where status in ('open', 'triaged', 'appealed');
create index audit_events_time_idx on wali.audit_events (created_at desc, id);
create index catalog_revocations_revision_idx on wali.catalog_revocations (signature_batch_revision, id);

create trigger reports_touch before update on wali.reports
for each row execute function wali.touch_mutable_row();
create trigger copyright_cases_touch before update on wali.copyright_cases
for each row execute function wali.touch_mutable_row();

create or replace function wali.reject_append_only_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception using errcode = 'P0001', message = 'WALI_APPEND_ONLY';
end
$$;

create or replace function wali.reject_self_review()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if exists (
    select 1 from wali.submissions s
     where s.id = new.submission_id and s.creator_id = new.moderator_id
  ) then
    raise exception using errcode = 'P0001', message = 'WALI_SELF_REVIEW_FORBIDDEN';
  end if;
  return new;
end
$$;

create trigger moderation_actions_append_only before update or delete on wali.moderation_actions
for each row execute function wali.reject_append_only_mutation();
create trigger audit_events_append_only before update or delete on wali.audit_events
for each row execute function wali.reject_append_only_mutation();
create trigger moderation_reviews_no_self before insert or update on wali.moderation_reviews
for each row execute function wali.reject_self_review();

create or replace function wali.record_moderation_decision(
  target_submission_id uuid,
  decision wali.review_decision,
  expected_revision bigint,
  command_key uuid,
  public_note text,
  private_note text,
  reason_codes text[]
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  request_hash text;
  replay jsonb;
  current_row wali.submissions%rowtype;
  result jsonb;
  mapped_status wali.submission_status;
begin
  if not wali.has_moderation_access() then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATOR_AAL2_REQUIRED';
  end if;
  if not wali.plain_text_is_valid(public_note, 1, 2000)
     or (private_note is not null and not wali.plain_text_is_valid(private_note, 1, 4000))
     or cardinality(reason_codes) not between 1 and 20 then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATION_INPUT_INVALID';
  end if;

  request_hash := encode(extensions.digest(
    target_submission_id::text || ':' || decision::text || ':' || expected_revision::text || ':' ||
    public_note || ':' || coalesce(private_note, '') || ':' || array_to_string(reason_codes, ','),
    'sha256'
  ), 'hex');
  replay := wali.reserve_command(actor, 'moderate_submission', command_key::text, request_hash);
  if replay is not null then return replay; end if;

  select * into current_row from wali.submissions where id = target_submission_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_FOUND'; end if;
  if current_row.creator_id = actor then
    raise exception using errcode = 'P0001', message = 'WALI_SELF_REVIEW_FORBIDDEN';
  end if;
  if current_row.status <> 'under_review' then
    raise exception using errcode = 'P0001', message = 'WALI_INVALID_TRANSITION';
  end if;
  if current_row.revision <> expected_revision then
    raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH';
  end if;

  mapped_status := case decision
    when 'approved' then 'approved'::wali.submission_status
    when 'changes_requested' then 'changes_requested'::wali.submission_status
    else 'rejected'::wali.submission_status
  end;

  if decision = 'approved' and (
    not exists (
      select 1 from wali.processing_attempts pa
       where pa.submission_id = current_row.id and pa.generation = current_row.generation and pa.status = 'completed'
    ) or not exists (
      select 1 from wali.rights_declarations rd
       where rd.submission_id = current_row.id and rd.review_status = 'approved'
    )
  ) then
    raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_READY';
  end if;

  insert into wali.moderation_reviews (
    submission_id, moderator_id, decision, public_note, private_note,
    checklist_revision, reason_codes, request_id
  ) values (
    current_row.id, actor, decision, public_note, private_note, 1, reason_codes, command_key
  );

  insert into wali.moderation_actions (
    actor_id, action, target_type, target_id, reason_code, request_id, metadata
  ) values (
    actor, 'submission.' || decision::text, 'submission', current_row.id,
    reason_codes[1], command_key, jsonb_build_object('decision', decision)
  );

  insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
  values (
    actor, 'moderation.submission.' || decision::text, 'submission', current_row.id,
    command_key, jsonb_build_object('decision', decision)
  );

  update wali.submissions
     set status = mapped_status,
         decided_at = case when mapped_status in ('approved', 'rejected') then statement_timestamp() else null end
   where id = current_row.id
  returning jsonb_build_object('id', id, 'status', status, 'revision', revision, 'replayed', false) into result;

  perform wali.complete_command(actor, 'moderate_submission', command_key::text, result);
  return result;
end
$$;

alter table wali.catalog_signing_keys enable row level security;
alter table wali.moderation_reviews enable row level security;
alter table wali.moderation_actions enable row level security;
alter table wali.reports enable row level security;
alter table wali.copyright_cases enable row level security;
alter table wali.catalog_revocations enable row level security;
alter table wali.audit_events enable row level security;

create policy signing_keys_public_active_read on wali.catalog_signing_keys for select to anon, authenticated
using (status in ('active', 'retired', 'compromised'));
create policy revocations_public_read on wali.catalog_revocations for select to anon, authenticated using (true);
create policy reports_owner_read on wali.reports for select to authenticated using (reporter_id = auth.uid());

grant select on wali.catalog_signing_keys, wali.catalog_revocations to anon, authenticated;
grant select on wali.reports to authenticated;
grant execute on function wali.record_moderation_decision(
  uuid, wali.review_decision, bigint, uuid, text, text, text[]
) to authenticated;

grant all on wali.catalog_signing_keys, wali.moderation_reviews, wali.moderation_actions,
  wali.reports, wali.copyright_cases, wali.catalog_revocations, wali.audit_events to service_role;

revoke all on function wali.reject_append_only_mutation() from public, anon, authenticated;
revoke all on function wali.reject_self_review() from public, anon, authenticated;
