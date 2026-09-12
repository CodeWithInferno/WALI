-- ADR 0023: independent, authenticated staff admission; existing worker/publication contracts remain unchanged.
begin;

alter table wali.runtime_configuration alter column creator_terms_version drop not null;
alter table wali.runtime_configuration add column catalog_license_attestation_version text;
alter table wali.runtime_configuration add constraint runtime_catalog_attestation_version check (
  catalog_license_attestation_version is null or catalog_license_attestation_version = '2026-09-12'
);
alter table wali.upload_sessions add column admission_kind text not null default 'creator'
  check (admission_kind in ('creator', 'staff_curated'));
alter table wali.rights_declarations add column attestation_document_kind text not null default 'creator_terms'
  check (attestation_document_kind in ('creator_terms', 'catalog_license_attestation'));
comment on column wali.rights_declarations.creator_terms_version is
  'Document version paired with attestation_document_kind; historical creator_terms values retain their meaning.';

create function wali.guard_upload_admission() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.admission_kind is distinct from old.admission_kind
     or (old.admission_kind = 'staff_curated' and
       (new.creator_id is distinct from old.creator_id or new.id is distinct from old.id
        or new.storage_path is distinct from old.storage_path)) then
    raise exception using errcode = 'P0001', message = 'WALI_ADMISSION_IMMUTABLE';
  end if;
  return new;
end $$;
create trigger upload_admission_immutable before update on wali.upload_sessions
for each row execute function wali.guard_upload_admission();

create function wali.guard_submission_admission() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and (new.creator_id is distinct from old.creator_id
     or new.upload_session_id is distinct from old.upload_session_id) then
    raise exception using errcode = 'P0001', message = 'WALI_ADMISSION_IMMUTABLE';
  end if;
  if not exists (select 1 from wali.upload_sessions u
    where u.id = new.upload_session_id and u.creator_id = new.creator_id) then
    raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_TARGET_INVALID';
  end if;
  return new;
end $$;
create trigger submission_admission_binding before insert or update of creator_id, upload_session_id
on wali.submissions for each row execute function wali.guard_submission_admission();

create function wali.guard_rights_attestation() returns trigger
language plpgsql security definer set search_path = '' as $$
declare owner_id uuid; admission text; expected_kind text;
begin
  select s.creator_id, u.admission_kind into owner_id, admission
    from wali.submissions s join wali.upload_sessions u on u.id = s.upload_session_id
    where s.id = new.submission_id;
  expected_kind := case admission when 'creator' then 'creator_terms'
    when 'staff_curated' then 'catalog_license_attestation' end;
  if expected_kind is null or new.attestation_document_kind is distinct from expected_kind
     or not exists (select 1 from wali.terms_acceptances t where t.user_id = owner_id
       and t.document_kind = expected_kind and t.document_version = new.creator_terms_version) then
    raise exception using errcode = 'P0001', message = 'WALI_ATTESTATION_BINDING_INVALID';
  end if;
  if admission = 'staff_curated' and (new.basis <> 'licensed'
     or new.proof_storage_path is not null or cardinality(new.proof_object_ids) <> 0
     or new.creator_terms_version <> '2026-09-12'
     or new.source_url is null or not wali.plain_text_is_valid(new.attribution_text, 1, 500)
     or not exists (select 1 from wali.licenses l where l.id = new.license_id
       and l.active and l.redistribution_allowed)) then
    raise exception using errcode = 'P0001', message = 'WALI_RIGHTS_INCOMPLETE';
  end if;
  return new;
end $$;
create trigger rights_attestation_binding before insert or update on wali.rights_declarations
for each row execute function wali.guard_rights_attestation();

-- This lock also serializes ordinary completion against curated capacity checks for a dual-role account.
create function wali.require_creator_admission(actor_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare current_version text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if not wali.edge_actor_has_role(actor_id, 'creator') then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_ROLE_REQUIRED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('wali.admission:' || actor_id::text, 0));
  select c.creator_terms_version into current_version from wali.runtime_configuration c where c.singleton for share;
  if current_version is null or not exists (select 1 from wali.terms_acceptances t
    where t.user_id = actor_id and t.document_kind = 'creator_terms' and t.document_version = current_version) then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_TERMS_REQUIRED';
  end if;
end $$;

create function wali.validate_curated_draft(actor_id uuid, draft jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare required_keys text[] := array['title','description','primary_category_id','suggested_tag_ids',
  'content_warning','rights_basis','rights_holder','license_id','source_url','attribution_text',
  'proof_object_ids','attests_rights','attestation_version'];
begin
  if jsonb_typeof(draft) is distinct from 'object' or octet_length(draft::text) > 16384
     or not (draft ?& required_keys) or (draft - required_keys) <> '{}'::jsonb then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  if exists (select 1 from unnest(array['title','description','primary_category_id','rights_basis',
    'rights_holder','license_id','source_url','attribution_text','attestation_version']) k
    where jsonb_typeof(draft -> k) is distinct from 'string')
     or jsonb_typeof(draft -> 'suggested_tag_ids') is distinct from 'array'
     or draft -> 'proof_object_ids' is distinct from '[]'::jsonb
     or draft -> 'attests_rights' is distinct from 'true'::jsonb
     or jsonb_typeof(draft -> 'content_warning') not in ('string','null') then
    raise exception using errcode = 'P0001', message = 'WALI_RIGHTS_INCOMPLETE';
  end if;
  if draft ->> 'attestation_version' is distinct from
       (select c.catalog_license_attestation_version from wali.runtime_configuration c where c.singleton)
     or draft ->> 'attestation_version' <> '2026-09-12'
     or not exists (select 1 from wali.terms_acceptances t where t.user_id = actor_id
       and t.document_kind = 'catalog_license_attestation'
       and t.document_version = draft ->> 'attestation_version') then
    raise exception using errcode = 'P0001', message = 'WALI_CATALOG_ATTESTATION_REQUIRED';
  end if;
  if draft ->> 'rights_basis' <> 'licensed'
     or not wali.plain_text_is_valid(draft ->> 'title', 1, 120)
     or not wali.plain_text_is_valid(draft ->> 'description', 1, 2000)
     or not wali.plain_text_is_valid(draft ->> 'rights_holder', 1, 160)
     or not wali.plain_text_is_valid(draft ->> 'attribution_text', 1, 500)
     or not wali.https_url_is_valid(draft ->> 'source_url')
     or (draft ->> 'content_warning' is not null and
       not wali.plain_text_is_valid(draft ->> 'content_warning', 1, 500))
     or not exists (select 1 from wali.licenses l where l.id = (draft ->> 'license_id')::uuid
       and l.active and l.redistribution_allowed)
     or not exists (select 1 from wali.categories c where c.id = (draft ->> 'primary_category_id')::uuid and c.active)
     or jsonb_array_length(draft -> 'suggested_tag_ids') > 20
     or jsonb_array_length(draft -> 'suggested_tag_ids') <>
       (select count(distinct value) from jsonb_array_elements(draft -> 'suggested_tag_ids'))
     or exists (select 1 from jsonb_array_elements(draft -> 'suggested_tag_ids') tag
       where jsonb_typeof(tag) <> 'string' or not exists
         (select 1 from wali.tags t where t.id = (tag #>> '{}')::uuid and t.active)) then
    raise exception using errcode = 'P0001', message = 'WALI_RIGHTS_INCOMPLETE';
  end if;
end $$;

-- Exact-path access to curated raw uploads always rechecks current real JWT AAL and admin status.
drop policy upload_sessions_owner_read on wali.upload_sessions;
create policy upload_sessions_owner_read on wali.upload_sessions for select to authenticated using (
  creator_id = auth.uid() and (admission_kind = 'creator' or
    (wali.current_aal() = 'aal2' and wali.has_active_role('admin')))
);
drop policy submissions_owner_read on wali.submissions;
create policy submissions_owner_read on wali.submissions for select to authenticated using (
  creator_id = auth.uid() and exists (select 1 from wali.upload_sessions u
    where u.id = upload_session_id and u.creator_id = auth.uid())
);
drop policy submissions_owner_draft_update on wali.submissions;
create policy submissions_owner_draft_update on wali.submissions for update to authenticated
using (creator_id = auth.uid() and status in ('draft','changes_requested')
  and exists (select 1 from wali.upload_sessions u where u.id = upload_session_id and u.admission_kind = 'creator')
  and exists (select 1 from wali.runtime_configuration c where c.singleton and c.creator_terms_version is not null))
with check (creator_id = auth.uid() and status in ('draft','changes_requested')
  and exists (select 1 from wali.upload_sessions u where u.id = upload_session_id and u.admission_kind = 'creator')
  and exists (select 1 from wali.runtime_configuration c where c.singleton and c.creator_terms_version is not null));
drop policy wali_upload_insert_exact_path on storage.objects;
create policy wali_upload_insert_exact_path on storage.objects for insert to authenticated with check (
  bucket_id = 'uploads-private' and exists (select 1 from wali.upload_sessions u
    where u.creator_id = auth.uid() and u.storage_path = name and u.status in ('issued','uploading')
      and u.expires_at > statement_timestamp()
      and ((u.admission_kind = 'creator' and exists (select 1 from wali.runtime_configuration c
          where c.singleton and c.creator_terms_version is not null))
        or (u.admission_kind = 'staff_curated' and wali.current_aal() = 'aal2' and wali.has_active_role('admin')
        and exists (select 1 from wali.runtime_configuration c
          where c.singleton and c.catalog_license_attestation_version = '2026-09-12'))))
);

create or replace view public.my_creator_submissions_v1
with (security_invoker = true, security_barrier = true) as
select s.id as submission_id, s.wallpaper_id, s.proposed_title, s.proposed_description,
  s.primary_category_id, s.license_id, s.rights_holder, s.attribution_text,
  s.source_url, s.content_rating_warning::text as content_rating_warning,
  s.status::text as status, s.generation, s.revision, s.submitted_at,
  s.decided_at, s.last_safe_error_code, s.created_at, s.updated_at
from wali.submissions s join wali.upload_sessions u on u.id = s.upload_session_id
where s.creator_id = auth.uid() and u.admission_kind = 'creator';


create or replace function public.wali_edge_accept_creator_terms_v1(
  actor_id uuid,
  expected_subject_id uuid,
  request_id uuid,
  idempotency_key text,
  creator_terms_version text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; current_version text; latest_revision bigint;
  grant_row wali.role_grants%rowtype; response jsonb; enrolled boolean := false;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if expected_subject_id is distinct from actor_id then
    raise exception using errcode = 'P0001', message = 'WALI_AUTH_SUBJECT_CHANGED';
  end if;
  if not exists (select 1 from wali.profiles p where p.id = actor_id and p.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  select cfg.creator_terms_version into current_version from wali.runtime_configuration cfg where cfg.singleton;
  if current_version is null or creator_terms_version is distinct from current_version then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_TERMS_REQUIRED';
  end if;
  select * into grant_row from wali.role_grants role_grant
   where role_grant.user_id = actor_id and role_grant.role = 'creator'
   order by role_grant.revision desc limit 1 for update;
  if grant_row.id is not null and grant_row.revoked_at is not null then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_ROLE_REVOKED';
  end if;
  request_hash := encode(extensions.digest(actor_id::text || ':' || creator_terms_version, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'accept_creator_terms', idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  insert into wali.terms_acceptances (user_id, document_kind, document_version, request_id)
  values (actor_id, 'creator_terms', creator_terms_version, request_id)
  on conflict (user_id, document_kind, document_version) do nothing;
  insert into wali.creator_profiles (user_id) values (actor_id) on conflict (user_id) do nothing;

  if grant_row.id is null then
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
  perform wali.require_creator_admission(actor_id);
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
  perform wali.require_creator_admission(actor_id);
  if exists (select 1 from wali.upload_sessions u where u.id = upload_session_id and u.admission_kind <> 'creator') then
    raise exception using errcode = 'P0001', message = 'WALI_ADMISSION_MISMATCH';
  end if;
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

create or replace function public.wali_edge_submit_wallpaper_v1(
  actor_id uuid, request_id uuid, idempotency_key text, submission_id uuid,
  expected_revision bigint, expected_generation bigint, creator_terms_version text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; current_row wali.submissions%rowtype; response jsonb;
begin
  perform wali.require_creator_admission(actor_id);
  if exists (select 1 from wali.submissions s join wali.upload_sessions u on u.id = s.upload_session_id
    where s.id = submission_id and u.admission_kind <> 'creator') then
    raise exception using errcode = 'P0001', message = 'WALI_ADMISSION_MISMATCH';
  end if;
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

create or replace function public.wali_edge_withdraw_submission_v1(
  actor_id uuid, request_id uuid, idempotency_key text, submission_id uuid, expected_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; current_row wali.submissions%rowtype; response jsonb;
begin
  perform wali.require_creator_admission(actor_id);
  if exists (select 1 from wali.submissions s join wali.upload_sessions u on u.id = s.upload_session_id
    where s.id = submission_id and u.admission_kind <> 'creator') then
    raise exception using errcode = 'P0001', message = 'WALI_ADMISSION_MISMATCH';
  end if;
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

create or replace function wali.complete_admitted_upload(
  actor_id uuid, request_id uuid, idempotency_key text,
  upload_session_id uuid, expected_session_revision bigint, admission_kind text, draft jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare
  request_hash text; replay jsonb; session_row wali.upload_sessions%rowtype; object_row storage.objects%rowtype;
  submission_id uuid; wallpaper_id uuid; attempt_id uuid; observed_size bigint; observed_type text;
  category_id uuid; license_id uuid; actor_name text; operation text;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if admission_kind not in ('creator','staff_curated') or admission_kind is null then
    raise exception using errcode = 'P0001', message = 'WALI_ADMISSION_MISMATCH';
  end if;
  if admission_kind = 'creator' then perform wali.require_creator_admission(actor_id);
  else perform wali.validate_curated_draft(actor_id, draft); end if;
  operation := case admission_kind when 'creator' then 'complete_upload' else 'curated.complete_upload' end;
  if exists (select 1 from wali.upload_sessions u where u.id = upload_session_id and u.admission_kind <> complete_admitted_upload.admission_kind) then
    raise exception using errcode = 'P0001', message = 'WALI_ADMISSION_MISMATCH';
  end if;
  request_hash := encode(extensions.digest(upload_session_id::text || ':' || expected_session_revision::text || case when admission_kind = 'staff_curated' then ':' || draft::text else '' end, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, operation, idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  if (select count(*) from wali.submissions s where s.creator_id = actor_id
    and s.status in ('processing','submitted','under_review')) >= 2 then
    raise exception using errcode = 'P0001', message = 'WALI_PROCESSING_CAPACITY_UNAVAILABLE';
  end if;
  select * into session_row from wali.upload_sessions s where s.id = upload_session_id and s.creator_id = actor_id
    and s.admission_kind = complete_admitted_upload.admission_kind for update;
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
  if admission_kind = 'staff_curated' then
    category_id := (draft ->> 'primary_category_id')::uuid;
    license_id := (draft ->> 'license_id')::uuid;
    actor_name := draft ->> 'rights_holder';
    insert into wali.creator_profiles (user_id) values (actor_id) on conflict (user_id) do nothing;
  end if;
  wallpaper_id := coalesce(session_row.target_wallpaper_id, gen_random_uuid());
  if session_row.target_wallpaper_id is null then
    insert into wali.wallpapers (
      id, creator_id, slug, title, description, primary_category_id, license_id,
      rights_holder_display, status, visibility, content_rating
    ) values (
      wallpaper_id, actor_id, ('draft-' || replace(wallpaper_id::text, '-', ''))::extensions.citext,
      case when admission_kind = 'staff_curated' then draft ->> 'title' else left(session_row.original_filename, 120) end,
      case when admission_kind = 'staff_curated' then draft ->> 'description' else 'Complete the wallpaper description before submission.' end,
      category_id, license_id, actor_name, 'draft', 'public', 'everyone'
    );
  end if;
  submission_id := gen_random_uuid(); attempt_id := gen_random_uuid();
  insert into wali.submissions (
    id, creator_id, wallpaper_id, proposed_title, proposed_description, primary_category_id, license_id,
    rights_holder, upload_session_id, status, generation, source_url, attribution_text, content_warning
  ) select submission_id, actor_id, wallpaper_id,
      case when admission_kind = 'staff_curated' then draft ->> 'title' else w.title end,
      case when admission_kind = 'staff_curated' then draft ->> 'description' else w.description end,
      case when admission_kind = 'staff_curated' then category_id else w.primary_category_id end,
      case when admission_kind = 'staff_curated' then license_id else w.license_id end,
      case when admission_kind = 'staff_curated' then actor_name else w.rights_holder_display end,
      session_row.id, 'processing', 1, draft ->> 'source_url', draft ->> 'attribution_text', draft ->> 'content_warning'
    from wali.wallpapers w where w.id = wallpaper_id and w.creator_id = actor_id;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_TARGET_INVALID'; end if;
  if admission_kind = 'staff_curated' then
    insert into wali.rights_declarations (submission_id, basis, rights_holder, license_id, source_url,
      attribution_text, attested_at, creator_terms_version, attestation_document_kind)
    values (submission_id, 'licensed', draft ->> 'rights_holder', license_id, draft ->> 'source_url',
      draft ->> 'attribution_text', statement_timestamp(), draft ->> 'attestation_version', 'catalog_license_attestation');
    insert into wali.submission_tag_suggestions (submission_id, tag_id, source)
    select submission_id, value::uuid, 'creator'::wali.taxonomy_source
      from jsonb_array_elements_text(draft -> 'suggested_tag_ids');
  end if;
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
  perform wali.complete_command(actor_id, operation, idempotency_key, replay);
  return replay;
end $$;

create or replace function public.wali_edge_complete_upload_v1(
  actor_id uuid, request_id uuid, idempotency_key text,
  upload_session_id uuid, expected_session_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wali.require_creator_admission(actor_id);
  return wali.complete_admitted_upload(actor_id, request_id, idempotency_key,
    upload_session_id, expected_session_revision, 'creator', null);
end $$;

create or replace function wali.save_admitted_submission_draft(
  actor_id uuid, request_id uuid, idempotency_key text, submission_id uuid, expected_revision bigint,
  title text, description text, primary_category_id uuid, suggested_tag_ids uuid[], content_warning text,
  rights_basis wali.rights_basis, rights_holder text, license_id uuid, source_url text,
  attribution_text text, proof_object_ids uuid[], attests_rights boolean, creator_terms_version text, admission_kind text
) returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare request_hash text; replay jsonb; current_row wali.submissions%rowtype; target_status wali.submission_status;
  license_row wali.licenses%rowtype; response jsonb; operation text; document_kind text;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if admission_kind not in ('creator','staff_curated') or admission_kind is null then
    raise exception using errcode = 'P0001', message = 'WALI_ADMISSION_MISMATCH';
  end if;
  document_kind := case admission_kind when 'creator' then 'creator_terms' else 'catalog_license_attestation' end;
  operation := case admission_kind when 'creator' then 'save_submission_draft' else 'curated.save_draft' end;
  if admission_kind = 'creator' then perform wali.require_creator_admission(actor_id); end if;
  if exists (select 1 from wali.submissions s join wali.upload_sessions u on u.id = s.upload_session_id
    where s.id = submission_id and u.admission_kind <> save_admitted_submission_draft.admission_kind) then
    raise exception using errcode = 'P0001', message = 'WALI_ADMISSION_MISMATCH';
  end if;
  -- Licensed/other declarations stay closed until every proof object is issued,
  -- scanned, observed and bound to this submission. UUIDs alone are not proof.
  if (admission_kind = 'creator' and rights_basis in ('licensed', 'other'))
     or (admission_kind = 'staff_curated' and rights_basis <> 'licensed')
     or cardinality(proof_object_ids) is distinct from 0 then
    raise exception using errcode = 'P0001', message = 'WALI_RIGHTS_WORKFLOW_UNAVAILABLE';
  end if;
  if creator_terms_version is null or creator_terms_version is distinct from (select case admission_kind when 'creator' then cfg.creator_terms_version else cfg.catalog_license_attestation_version end from wali.runtime_configuration cfg where cfg.singleton)
     or not exists (select 1 from wali.terms_acceptances t where t.user_id = actor_id and t.document_kind = document_kind and t.document_version = creator_terms_version) then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_TERMS_REQUIRED';
  end if;
  select * into license_row from wali.licenses license where license.id = license_id and license.active;
  if not found or attests_rights is distinct from true
     or (admission_kind = 'staff_curated' and (not license_row.redistribution_allowed
       or not wali.plain_text_is_valid(attribution_text, 1, 500))) or not wali.plain_text_is_valid(title, 1, 120)
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
  replay := wali.reserve_command(actor_id, operation, idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select * into current_row from wali.submissions s where s.id = submission_id and s.creator_id = actor_id
    and exists (select 1 from wali.upload_sessions u where u.id = s.upload_session_id
      and u.admission_kind = save_admitted_submission_draft.admission_kind) for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_FOUND'; end if;
  if current_row.revision <> expected_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if current_row.status not in ('draft', 'ready_for_submission', 'changes_requested') then
    raise exception using errcode = 'P0001', message = 'WALI_INVALID_TRANSITION';
  end if;
  target_status := current_row.status;
  if current_row.status = 'changes_requested' then
    if not wali.submission_has_verified_media(current_row.id, current_row.generation) then
      raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_READY';
    end if;
    target_status := 'ready_for_submission';
  end if;
  update wali.submissions set proposed_title = save_admitted_submission_draft.title,
    proposed_description = save_admitted_submission_draft.description,
    primary_category_id = save_admitted_submission_draft.primary_category_id,
    license_id = save_admitted_submission_draft.license_id,
    rights_holder = save_admitted_submission_draft.rights_holder,
    attribution_text = save_admitted_submission_draft.attribution_text,
    source_url = save_admitted_submission_draft.source_url,
    content_warning = save_admitted_submission_draft.content_warning,
    status = target_status where id = current_row.id returning * into current_row;
  insert into wali.rights_declarations (submission_id, basis, rights_holder, license_id, source_url,
    attribution_text, proof_object_ids, attested_at, creator_terms_version, attestation_document_kind)
  values (current_row.id, rights_basis, rights_holder, license_id, source_url, attribution_text,
    proof_object_ids, statement_timestamp(), creator_terms_version, document_kind)
  on conflict on constraint rights_declarations_submission_id_key do update set basis = excluded.basis, rights_holder = excluded.rights_holder,
    license_id = excluded.license_id, source_url = excluded.source_url, attribution_text = excluded.attribution_text,
    proof_object_ids = excluded.proof_object_ids, attested_at = excluded.attested_at,
    creator_terms_version = excluded.creator_terms_version, attestation_document_kind = excluded.attestation_document_kind, review_status = 'pending',
    reviewed_by = null, reviewed_at = null;
  delete from wali.submission_tag_suggestions suggestion
   where suggestion.submission_id = current_row.id and suggestion.source = 'creator';
  insert into wali.submission_tag_suggestions (submission_id, tag_id, source)
  select current_row.id, tag_id, 'creator'::wali.taxonomy_source from unnest(suggested_tag_ids) tag_id;
  response := jsonb_build_object('submission_id', current_row.id, 'revision', current_row.revision,
    'generation', current_row.generation, 'state', current_row.status, 'field_errors', '[]'::jsonb);
  perform wali.complete_command(actor_id, operation, idempotency_key, response);
  return response;
end $$;

create or replace function public.wali_edge_save_submission_draft_v1(
  actor_id uuid, request_id uuid, idempotency_key text, submission_id uuid, expected_revision bigint,
  title text, description text, primary_category_id uuid, suggested_tag_ids uuid[], content_warning text,
  rights_basis wali.rights_basis, rights_holder text, license_id uuid, source_url text,
  attribution_text text, proof_object_ids uuid[], attests_rights boolean, creator_terms_version text
) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wali.require_creator_admission(actor_id);
  return wali.save_admitted_submission_draft(actor_id, request_id, idempotency_key, submission_id,
    expected_revision, title, description, primary_category_id, suggested_tag_ids, content_warning,
    rights_basis, rights_holder, license_id, source_url, attribution_text, proof_object_ids,
    attests_rights, creator_terms_version, 'creator');
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
      where submission.id = cursor_id and submission.creator_id = actor_id and exists (select 1 from wali.upload_sessions u
        where u.id = submission.upload_session_id and u.admission_kind = 'creator');
    if not found then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
  end if;
  with page as (
    select submission.* from wali.submissions submission
    where submission.creator_id = actor_id and exists (select 1 from wali.upload_sessions u
        where u.id = submission.upload_session_id and u.admission_kind = 'creator')
      and (cursor_id is null or (submission.updated_at, submission.id) < (cursor_time, cursor_id))
    order by submission.updated_at desc, submission.id desc limit page_limit
  ), projected as (
    select page.id, page.updated_at, jsonb_build_object(
      'submission_id', page.id, 'wallpaper_id', page.wallpaper_id,
      'wallpaper_status', wallpaper.status,
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
    left join wali.wallpapers wallpaper on wallpaper.id = page.wallpaper_id
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

create or replace function public.creator_processing_status_v1(
  submission_id uuid, generation bigint
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor_id uuid := auth.uid(); response jsonb;
begin
  if generation not between 1 and 2147483647
     or not exists (select 1 from wali.submissions submission
       join wali.profiles profile on profile.id = submission.creator_id
       where submission.id = creator_processing_status_v1.submission_id
         and submission.creator_id = actor_id and profile.status = 'active'
         and exists (select 1 from wali.upload_sessions u where u.id = submission.upload_session_id
           and u.admission_kind = 'creator')) then
    raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_FOUND';
  end if;
  response := wali.creator_processing_projection(submission_id, generation::integer);
  if response is null then raise exception using errcode = 'P0001', message = 'WALI_PROCESSING_GENERATION_STALE'; end if;
  return response;
end $$;

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
    'attestation_document_kind', rights_row.attestation_document_kind,
    'attestation_version', rights_row.creator_terms_version,
    'attested_at', rights_row.attested_at, 'rights_revision', rights_row.revision,
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
      perform pgmq.send('wali_promotions', jsonb_build_object(
        'schema_version', 1, 'promotion_id', promotion_id, 'release_id', release_row.id,
        'artifacts', (select jsonb_agg(jsonb_build_object(
          'role', link.role, 'digest', staged.digest, 'byte_count', staged.byte_count,
          'media_type', staged.media_type, 'source_bucket', 'processing-private',
          'source_path', staged.storage_path, 'destination_bucket', 'catalog-public',
          'destination_path', staged.storage_path
        ) order by link.sort_order, link.role)
          from wali.release_staged_artifacts link
          join wali.staged_artifacts staged on staged.digest = link.artifact_digest
          where link.release_id = release_row.id)
      ));
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
    'attestation_document_kind', rights_row.attestation_document_kind,
    'attestation_version', rights_row.creator_terms_version,
    'attested_at', rights_row.attested_at, 'rights_revision', rights_row.revision,
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
  if queue_status not in ('pending', 'under_review', 'approved') or queue_sort not in ('oldest_submitted', 'newest_submitted', 'risk_priority')
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
      else submission.status::text = queue_status end)
      and (queue_status <> 'approved' or exists (
        select 1 from wali.wallpaper_releases release
        where release.source_submission_id = submission.id and release.status = 'approved'
      ))
      and (cursor_id is null or case when queue_sort = 'newest_submitted'
        then (submission.submitted_at < cursor_time or
          (submission.submitted_at = cursor_time and submission.id > cursor_id))
        else (submission.submitted_at, submission.id) > (cursor_time, cursor_id) end)
    order by
      case when queue_sort = 'newest_submitted' then submission.submitted_at end desc,
      case when queue_sort <> 'newest_submitted' then submission.submitted_at end asc,
      submission.id asc limit page_limit
  ), projected as (
    select page.id, page.submitted_at, jsonb_build_object(
      'submission_id', page.id, 'revision', page.revision, 'generation', page.generation,
      'state', page.status, 'wallpaper_id', page.wallpaper_id, 'wallpaper_revision', wallpaper.revision,
      'creator', jsonb_build_object('id', creator.id, 'handle', creator.handle::text,
        'display_name', creator.display_name),
      'proposed_title', page.proposed_title, 'proposed_description', page.proposed_description,
      'primary_category_name', category.name,
      'tag_names', coalesce(tags.names, '[]'::jsonb),
      'content_rating', page.content_rating_warning,
      'attribution_text', page.attribution_text, 'source_url', page.source_url,
      'rights_summary', rights.basis::text || ' · ' || license.name ||
        case when rights.attestation_document_kind = 'catalog_license_attestation' then
          ' · Catalog License Attestation ' || rights.creator_terms_version || ' · attested ' ||
          to_char(rights.attested_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') else '' end,
      'proof_status', 'not_required',
      'canonical_artifacts', coalesce(artifacts.items, '[]'::jsonb),
      'media_facts', wali.creator_processing_projection(page.id, page.generation) -> 'media_facts',
      'findings', wali.creator_processing_projection(page.id, page.generation) -> 'findings',
      'model_suggestions', wali.creator_processing_projection(page.id, page.generation) -> 'suggestions',
      'submitted_at', to_char(page.submitted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ) as item
    from page join wali.wallpapers wallpaper on wallpaper.id = page.wallpaper_id
    join wali.profiles creator on creator.id = page.creator_id
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
        and link.role in ('poster', 'preview', 'video_default')
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
        status, admission_kind, created_at, completed_at from wali.upload_sessions where creator_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'submissions', coalesce((select jsonb_agg(to_jsonb(x) order by created_at, id)
      from (select id, wallpaper_id, proposed_title, proposed_description, primary_category_id,
        license_id, rights_holder, attribution_text, source_url, content_rating_warning,
        status, generation, revision, submitted_at, decided_at, created_at, updated_at
        from wali.submissions where creator_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'rights_declarations', coalesce((select jsonb_agg(to_jsonb(x) order by submission_id)
      from (select r.submission_id, r.basis, r.rights_holder, r.license_id, r.source_url,
        r.attribution_text, r.attested_at, r.creator_terms_version, r.attestation_document_kind,
        r.creator_terms_version as attestation_version, r.review_status, r.revision
        from wali.rights_declarations r join wali.submissions s on s.id = r.submission_id
        where s.creator_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'reports', coalesce((select jsonb_agg(to_jsonb(x) order by created_at, id)
      from (select id, wallpaper_id, release_id, kind, detail, status, resolution_code, created_at, resolved_at
        from wali.reports where reporter_id = worker_read_account_export.user_id) x), '[]'::jsonb)
  ) into document;
  if octet_length(document::text) > 10485760 then raise exception using errcode = 'P0001', message = 'WALI_EXPORT_TOO_LARGE'; end if;
  return document;
end $$;

-- Only this service-role wrapper admits staff-curated operations. actor_id/actor_aal are verified by Edge.
-- bind_upload is server-only; the public HTTP action allowlist excludes it.
create function public.wali_edge_curated_catalog_command_v1(
  actor_id uuid, actor_aal text, request_id uuid, idempotency_key text, command text, payload jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare keys text[]; key text; current_version text; operation text; request_hash text;
  response jsonb; replay jsonb; session_row wali.upload_sessions%rowtype;
  submission_row wali.submissions%rowtype; draft jsonb; target jsonb;
  session_id uuid; submission_id uuid; target_id uuid;
  byte_count bigint; target_kind text; target_revision bigint; target_for_audit uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if actor_id is null or actor_aal is distinct from 'aal2' then
    raise exception using errcode = 'P0001', message = 'WALI_ADMIN_AAL2_REQUIRED';
  end if;
  -- Hold active-account/grant rows through the mutation: concurrent revocation cannot race admission.
  perform 1 from wali.profiles p where p.id = actor_id and p.status = 'active' for share;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_ADMIN_AAL2_REQUIRED'; end if;
  perform 1 from wali.role_grants g where g.user_id = actor_id and g.role = 'admin' and g.revoked_at is null for share;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_ADMIN_AAL2_REQUIRED'; end if;
  if request_id is null or idempotency_key is null or char_length(idempotency_key) not between 16 and 64
     or idempotency_key !~ '^[A-Za-z0-9_-]+$'
     or command is null or command not in ('accept_attestation','create_upload','bind_upload','complete_upload','save_draft','submit','status','withdraw')
     or jsonb_typeof(payload) is distinct from 'object' or octet_length(payload::text) > 24576 then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  keys := case command
    when 'accept_attestation' then array['expected_subject_id','attestation_version']
    when 'create_upload' then array['declared_byte_count','container_hint','original_filename','target']
    when 'bind_upload' then array['upload_session_id','expected_session_revision','upload_endpoint']
    when 'complete_upload' then array['upload_session_id','expected_session_revision','draft']
    when 'save_draft' then array['submission_id','expected_revision','draft']
    when 'submit' then array['submission_id','expected_revision','expected_generation','attestation_version']
    when 'status' then array['upload_session_id']
    when 'withdraw' then array['submission_id','expected_revision'] end;
  if not (payload ?& keys) or (payload - keys) <> '{}'::jsonb then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  foreach key in array keys loop
    if key in ('expected_revision','expected_session_revision','expected_generation','declared_byte_count') then
      if jsonb_typeof(payload -> key) is distinct from 'number' or payload ->> key !~ '^[0-9]+$'
         or (payload ->> key)::numeric > 9007199254740991 then
        raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
      end if;
    elsif key not in ('draft','target') and jsonb_typeof(payload -> key) is distinct from 'string' then
      raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
    end if;
  end loop;
  perform pg_advisory_xact_lock(hashtextextended('wali.admission:' || actor_id::text, 0));
  select c.catalog_license_attestation_version into current_version
    from wali.runtime_configuration c where c.singleton for share;
  if command not in ('status','withdraw') then
    if current_version is distinct from '2026-09-12' then
      raise exception using errcode = 'P0001', message = 'WALI_CATALOG_ADMISSION_UNAVAILABLE';
    end if;
    if command <> 'accept_attestation' and not exists (select 1 from wali.terms_acceptances t
      where t.user_id = actor_id and t.document_kind = 'catalog_license_attestation'
        and t.document_version = current_version) then
      raise exception using errcode = 'P0001', message = 'WALI_CATALOG_ATTESTATION_REQUIRED';
    end if;
  end if;
  if command in ('accept_attestation','submit') and payload ->> 'attestation_version' is distinct from current_version then
    raise exception using errcode = 'P0001', message = 'WALI_CATALOG_ATTESTATION_REQUIRED';
  end if;
  if command = 'accept_attestation' and (payload ->> 'expected_subject_id')::uuid is distinct from actor_id then
    raise exception using errcode = 'P0001', message = 'WALI_AUTH_SUBJECT_CHANGED';
  end if;
  if command in ('complete_upload','save_draft') then
    draft := payload -> 'draft';
    perform wali.validate_curated_draft(actor_id, draft);
  end if;
  if payload ? 'upload_session_id' then
    session_id := (payload ->> 'upload_session_id')::uuid;
    select * into session_row from wali.upload_sessions u where u.id = session_id
      and u.creator_id = actor_id and u.admission_kind = 'staff_curated' for update;
    if not found then raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_TARGET_INVALID'; end if;
  end if;
  if payload ? 'submission_id' then
    submission_id := (payload ->> 'submission_id')::uuid;
    select s.* into submission_row from wali.submissions s join lateral
      (select u.admission_kind from wali.upload_sessions u where u.id = s.upload_session_id) admission on true
      where s.id = submission_id and s.creator_id = actor_id and admission.admission_kind = 'staff_curated' for update of s;
    if not found then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_FOUND'; end if;
  end if;
  operation := 'curated.' || command;
  request_hash := encode(extensions.digest(payload::text, 'sha256'), 'hex');
  if command not in ('status','complete_upload','save_draft') then
    replay := wali.reserve_command(actor_id, operation, idempotency_key, request_hash);
    if replay is not null then
      if command = 'create_upload' then
        select * into session_row from wali.upload_sessions u where u.id = (replay ->> 'upload_session_id')::uuid
          and u.creator_id = actor_id and u.admission_kind = 'staff_curated';
        if not found then raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_TARGET_INVALID'; end if;
        return replay || jsonb_build_object('revision', session_row.revision, 'upload_endpoint', session_row.upload_endpoint);
      end if;
      return replay;
    end if;
  end if;
  case command
    when 'accept_attestation' then
      insert into wali.terms_acceptances (user_id, document_kind, document_version, request_id)
      values (actor_id, 'catalog_license_attestation', current_version, request_id)
      on conflict (user_id,document_kind,document_version) do nothing;
      response := jsonb_build_object('document_kind','catalog_license_attestation',
        'accepted_attestation_version',current_version,'current_attestation_version',current_version);
      target_for_audit := actor_id;
    when 'create_upload' then
      byte_count := (payload ->> 'declared_byte_count')::bigint;
      target := payload -> 'target';
      if byte_count not between 1 and 1073741824
         or payload ->> 'container_hint' not in ('video/mp4','video/quicktime')
         or not wali.plain_text_is_valid(payload ->> 'original_filename',1,255)
         or payload ->> 'original_filename' ~ '[/\\]' or payload ->> 'original_filename' in ('.','..')
         or jsonb_typeof(target) is distinct from 'object' then
        raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
      end if;
      target_kind := target ->> 'kind';
      if target_kind = 'new' and target = '{"kind":"new"}'::jsonb then target_id := null;
      elsif target_kind = 'wallpaper_update' and target ?& array['kind','wallpaper_id','expected_revision']
         and (target - array['kind','wallpaper_id','expected_revision']) = '{}'::jsonb
         and jsonb_typeof(target -> 'wallpaper_id') = 'string'
         and jsonb_typeof(target -> 'expected_revision') = 'number'
         and target ->> 'expected_revision' ~ '^[0-9]+$' then
        target_id := (target ->> 'wallpaper_id')::uuid;
        target_revision := (target ->> 'expected_revision')::bigint;
        if target_revision not between 0 and 9007199254740991 or not exists (select 1 from wali.wallpapers w
          where w.id = target_id and w.creator_id = actor_id and w.revision = target_revision) then
          raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_TARGET_INVALID';
        end if;
      else raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
      if (select count(*) from wali.upload_sessions u where u.creator_id = actor_id
        and u.admission_kind = 'staff_curated' and u.created_at > statement_timestamp() - interval '24 hours') >= 24 then
        raise exception using errcode = 'P0001', message = 'WALI_CATALOG_UPLOAD_QUOTA_EXCEEDED';
      end if;
      if (select count(*) from wali.submissions s where s.creator_id = actor_id
        and s.status in ('processing','submitted','under_review')) >= 2 then
        raise exception using errcode = 'P0001', message = 'WALI_PROCESSING_CAPACITY_UNAVAILABLE';
      end if;
      session_id := gen_random_uuid();
      insert into wali.upload_sessions (id, creator_id, storage_path, original_filename, declared_byte_count,
        declared_media_type, target_wallpaper_id, status, expires_at, idempotency_key, admission_kind)
      values (session_id, actor_id, actor_id::text || '/' || session_id::text || '/source',
        payload ->> 'original_filename', byte_count, payload ->> 'container_hint', target_id,
        'issued', statement_timestamp() + interval '24 hours', 'curated:' || idempotency_key, 'staff_curated')
      returning * into session_row;
      response := jsonb_build_object('upload_session_id', session_row.id, 'storage_path', session_row.storage_path,
        'expires_at',to_char(session_row.expires_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'revision',session_row.revision,'upload_endpoint',session_row.upload_endpoint);
      target_for_audit := actor_id;
    when 'bind_upload' then
      if session_row.status not in ('issued','uploading') then
        raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_ALREADY_BOUND';
      end if;
      if session_row.expires_at <= statement_timestamp() then
        raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_EXPIRED';
      end if;
      if not (payload ->> 'upload_endpoint' ~ '^https://[^[:space:][:cntrl:]@]+/storage/v1/upload/resumable/[A-Za-z0-9._~/?=&%-]+$'
        or payload ->> 'upload_endpoint' ~ '^http://(127[.]0[.]0[.]1|localhost)(:[0-9]{2,5})?/storage/v1/upload/resumable/[A-Za-z0-9._~/?=&%-]+$')
        or char_length(payload ->> 'upload_endpoint') > 2048 then
        raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
      end if;
      if session_row.upload_endpoint is distinct from payload ->> 'upload_endpoint' then
        if session_row.upload_endpoint is not null or session_row.revision <> (payload ->> 'expected_session_revision')::bigint then
          raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH';
        end if;
        update wali.upload_sessions set upload_endpoint = payload ->> 'upload_endpoint'
          where id = session_row.id returning * into session_row;
      end if;
      response := jsonb_build_object('revision',session_row.revision);
      target_for_audit := actor_id;
    when 'complete_upload' then
      response := wali.complete_admitted_upload(actor_id,request_id,idempotency_key,session_id,
        (payload ->> 'expected_session_revision')::bigint,'staff_curated',draft);
      target_for_audit := (response ->> 'submission_id')::uuid;
    when 'save_draft' then
      response := wali.save_admitted_submission_draft(actor_id,request_id,idempotency_key,submission_id,
        (payload ->> 'expected_revision')::bigint,draft ->> 'title',draft ->> 'description',
        (draft ->> 'primary_category_id')::uuid,
        array(select value::uuid from jsonb_array_elements_text(draft -> 'suggested_tag_ids')),
        draft ->> 'content_warning','licensed',draft ->> 'rights_holder',(draft ->> 'license_id')::uuid,
        draft ->> 'source_url',draft ->> 'attribution_text','{}'::uuid[],true,draft ->> 'attestation_version','staff_curated');
      target_for_audit := submission_id;
    when 'submit' then
      if submission_row.revision <> (payload ->> 'expected_revision')::bigint then
        raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH';
      end if;
      if (payload ->> 'expected_generation')::bigint not between 1 and 2147483647
        or submission_row.generation <> (payload ->> 'expected_generation')::bigint then
        raise exception using errcode = 'P0001', message = 'WALI_STALE_PROCESSING_GENERATION';
      end if;
      if submission_row.status <> 'ready_for_submission'
        or not wali.submission_has_verified_media(submission_id,submission_row.generation)
        or not exists (select 1 from wali.rights_declarations r where r.submission_id = submission_id
          and r.attestation_document_kind = 'catalog_license_attestation'
          and r.creator_terms_version = current_version and r.basis = 'licensed') then
        raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_READY';
      end if;
      update wali.submissions set status = 'submitted', submitted_at = statement_timestamp()
        where id = submission_id returning * into submission_row;
      response := jsonb_build_object('submission_id',submission_id,'revision',submission_row.revision,
        'generation',submission_row.generation,'state',submission_row.status);
      target_for_audit := submission_id;
    when 'withdraw' then
      if submission_row.revision <> (payload ->> 'expected_revision')::bigint then
        raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH';
      end if;
      if submission_row.status not in ('draft','uploading','uploaded','processing','processing_failed',
        'ready_for_submission','submitted','under_review','changes_requested') then
        raise exception using errcode = 'P0001', message = 'WALI_INVALID_TRANSITION';
      end if;
      update wali.submissions set status = 'withdrawn' where id = submission_id returning * into submission_row;
      update wali.processing_attempts p set status = 'failed', safe_error_code = 'WALI_WITHDRAWN',
        finished_at = statement_timestamp(), lease_owner = null, lease_expires_at = null
        where p.submission_id = submission_row.id and p.status not in ('completed','failed','timed_out');
      response := jsonb_build_object('submission_id',submission_id,'revision',submission_row.revision,
        'generation',submission_row.generation,'state',submission_row.status,'field_errors','[]'::jsonb);
      target_for_audit := submission_id;
    when 'status' then
      select * into submission_row from wali.submissions s where s.upload_session_id = session_row.id and s.creator_id = actor_id;
      return jsonb_build_object('upload_session_id',session_row.id,'revision',session_row.revision,
        'upload_state',session_row.status,
        'expires_at',to_char(session_row.expires_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'submission',case when submission_row.id is null then null else jsonb_build_object(
          'submission_id',submission_row.id,'revision',submission_row.revision,
          'generation',submission_row.generation,'state',submission_row.status,
          'processing',wali.creator_processing_projection(submission_row.id,submission_row.generation)) end);
  end case;
  if command not in ('complete_upload','save_draft') then
    perform wali.complete_command(actor_id,operation,idempotency_key,response);
  end if;
  if coalesce((response ->> 'replayed')::boolean,false) = false then
    insert into wali.audit_events (actor_id,action,target_type,target_id,request_id,metadata)
    values (actor_id,'catalog.curated.' || command,
      case when command in ('accept_attestation','create_upload','bind_upload') then 'account'::wali.moderation_target_type else 'submission'::wali.moderation_target_type end,
      target_for_audit,request_id,jsonb_build_object('admission_kind','staff_curated',
        'attestation_document_kind','catalog_license_attestation','attestation_version',case when command = 'withdraw' then
          (select r.creator_terms_version from wali.rights_declarations r where r.submission_id = submission_row.id)
          else current_version end,
        'upload_session_id',case when command in ('create_upload','bind_upload') then session_row.id else null end));
  end if;
  return response;
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
end $$;


revoke all on function wali.guard_upload_admission(), wali.guard_submission_admission(),
  wali.guard_rights_attestation(), wali.require_creator_admission(uuid), wali.validate_curated_draft(uuid,jsonb),
  wali.complete_admitted_upload(uuid,uuid,text,uuid,bigint,text,jsonb),
  wali.save_admitted_submission_draft(uuid,uuid,text,uuid,bigint,text,text,uuid,uuid[],text,wali.rights_basis,text,uuid,text,text,uuid[],boolean,text,text)
  from public, anon, authenticated, service_role;
revoke all on function public.wali_edge_curated_catalog_command_v1(uuid,text,uuid,text,text,jsonb)
  from public, anon, authenticated;
grant execute on function public.wali_edge_curated_catalog_command_v1(uuid,text,uuid,text,text,jsonb) to service_role;
commit;
