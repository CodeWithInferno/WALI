-- ADR 0025: verified-email Creator admission and system-owned automatic publication.
-- No human reviewer identity, AAL2 assertion, signing key, or secret is synthesized.
begin;

create extension if not exists pg_net;

create function wali.creator_email_is_verified(actor_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists (select 1 from auth.users u join wali.profiles p on p.id=u.id
   where u.id=actor_id and p.status='active' and nullif(u.email,'') is not null
     and u.email_confirmed_at is not null and not coalesce(u.is_anonymous,false))
$$;
revoke all on function wali.creator_email_is_verified(uuid) from public,anon,authenticated;

alter table wali.submissions add column automatic_publication_requested boolean not null default false;
create table wali.automatic_publication_decisions (
 id uuid primary key default gen_random_uuid(),
 submission_id uuid not null references wali.submissions(id),
 generation integer not null check (generation>0),
 submission_revision bigint not null check (submission_revision>0),
 attempt_id uuid not null references wali.processing_attempts(id),
 policy_version text not null check (policy_version='automatic-publication-2026-09-12'),
 authority text not null default 'automatic_publication' check (authority='automatic_publication'),
 submission_snapshot jsonb not null check(jsonb_typeof(submission_snapshot)='object' and octet_length(submission_snapshot::text)<=32768),
 rights_snapshot jsonb not null check (jsonb_typeof(rights_snapshot)='object' and octet_length(rights_snapshot::text)<=32768),
 artifact_set_digest text not null check (artifact_set_digest ~ '^[0-9a-f]{64}$'),
 created_at timestamptz not null default statement_timestamp()
);
create trigger automatic_decisions_append_only before update or delete on wali.automatic_publication_decisions
 for each row execute function wali.reject_append_only_mutation();
alter table wali.automatic_publication_decisions enable row level security;
grant select,insert on wali.automatic_publication_decisions to service_role;

create table wali.automatic_publication_jobs (
 id uuid primary key default gen_random_uuid(),
 submission_id uuid not null references wali.submissions(id),
 generation integer not null check (generation>0),
 status text not null default 'queued' check(status in ('queued','leased','completed','failed','cancelled')),
 decision_id uuid references wali.automatic_publication_decisions(id),
 lease_token uuid, lease_expires_at timestamptz,
 attempts integer not null default 0 check(attempts>=0),
 next_attempt_at timestamptz not null default statement_timestamp(),
 safe_error_code text check(safe_error_code is null or safe_error_code ~ '^WALI_[A-Z0-9_]{2,96}$'),
 created_at timestamptz not null default statement_timestamp(),
 completed_at timestamptz,
 unique(submission_id,generation),
 check ((status='leased')=(lease_token is not null and lease_expires_at is not null))
);
create index automatic_publication_due on wali.automatic_publication_jobs(next_attempt_at,created_at)
 where status in ('queued','leased');
alter table wali.automatic_publication_jobs enable row level security;
grant select,insert,update on wali.automatic_publication_jobs to service_role;

alter table wali.rights_declarations add column system_publication_decision_id uuid references wali.automatic_publication_decisions(id);
alter table wali.rights_declarations drop constraint rights_review_pair;
alter table wali.rights_declarations add constraint rights_review_authority check (
 (review_status='pending' and reviewed_by is null and reviewed_at is null and system_publication_decision_id is null)
 or (review_status<>'pending' and reviewed_at is not null and
   ((reviewed_by is not null and system_publication_decision_id is null)
    or (review_status='approved' and reviewed_by is null and system_publication_decision_id is not null)))
);
alter table wali.wallpaper_tags add column system_publication_decision_id uuid references wali.automatic_publication_decisions(id);
alter table wali.wallpaper_tags drop constraint wallpaper_tags_decision_pair;
alter table wali.wallpaper_tags drop constraint wallpaper_tags_approved_actor;
alter table wali.wallpaper_tags add constraint wallpaper_tags_decision_authority check (
 (status='suggested' and decided_by is null and decided_at is null and system_publication_decision_id is null)
 or (status<>'suggested' and decided_at is not null and
   ((decided_by is not null and system_publication_decision_id is null)
    or (status='approved' and decided_by is null and system_publication_decision_id is not null)))
);
alter table wali.publication_intents alter column actor_id drop not null;
alter table wali.publication_intents add column system_publication_decision_id uuid references wali.automatic_publication_decisions(id);
alter table wali.publication_intents add constraint publication_intent_authority check (
 (actor_id is not null) <> (system_publication_decision_id is not null)
);
alter table wali.publication_intents drop constraint publication_intent_expiry;
alter table wali.publication_intents add constraint publication_intent_expiry check (expires_at>issued_at and expires_at<=issued_at+interval '5 minutes 1 second');
create unique index automatic_publication_intent_key on wali.publication_intents(idempotency_key)
 where actor_id is null;

create function wali.enqueue_automatic_publication() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.automatic_publication_requested and new.status='ready_for_submission' then
   insert into wali.automatic_publication_jobs(submission_id,generation)
    values(new.id,new.generation) on conflict(submission_id,generation) do nothing;
 end if;
 return new;
end $$;
create trigger submission_automatic_publication after insert or update of status on wali.submissions
 for each row execute function wali.enqueue_automatic_publication();
create function wali.guard_automatic_publication_request() returns trigger
language plpgsql set search_path = '' as $$
begin
 if ((TG_OP='INSERT' and new.automatic_publication_requested)
   or (TG_OP='UPDATE' and new.automatic_publication_requested is distinct from old.automatic_publication_requested))
   and auth.role() is distinct from 'service_role' then
   raise exception using errcode='P0001',message='WALI_SERVICE_ROLE_REQUIRED';
 end if;
 return new;
end $$;
create trigger guard_automatic_publication_request before insert or update on wali.submissions
 for each row execute function wali.guard_automatic_publication_request();

create function wali.validate_creator_upload_draft(actor_id uuid,draft jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare license_row wali.licenses%rowtype;
begin
 perform wali.require_creator_admission(actor_id);
 if jsonb_typeof(draft) is distinct from 'object' or
   (select array_agg(k order by k) from jsonb_object_keys(draft) k) is distinct from
   array['attests_rights','attribution_text','content_warning','creator_terms_version','description','license_id','primary_category_id','proof_object_ids','rights_basis','rights_holder','source_url','suggested_tag_ids','title']::text[]
   or (draft->'attests_rights') is distinct from 'true'::jsonb
   or (draft->'proof_object_ids') is distinct from '[]'::jsonb
   or draft->>'rights_basis' not in ('original','licensed','public_domain')
   or not wali.plain_text_is_valid(draft->>'title',1,120)
   or not wali.plain_text_is_valid(draft->>'description',1,2000)
   or not wali.plain_text_is_valid(draft->>'rights_holder',1,160)
   or (draft->>'content_warning' is not null and not wali.plain_text_is_valid(draft->>'content_warning',1,500))
   or (draft->>'attribution_text' is not null and not wali.plain_text_is_valid(draft->>'attribution_text',1,500))
   or not wali.https_url_is_valid(draft->>'source_url')
   or (draft->>'rights_basis' in ('licensed','public_domain') and draft->>'source_url' is null)
   or jsonb_typeof(draft->'suggested_tag_ids') is distinct from 'array'
   or jsonb_array_length(draft->'suggested_tag_ids')>20 then
   raise exception using errcode='P0001',message='WALI_RIGHTS_INCOMPLETE';
 end if;
 if draft->>'creator_terms_version' is distinct from (select c.creator_terms_version from wali.runtime_configuration c where c.singleton) then
   raise exception using errcode='P0001',message='WALI_CREATOR_TERMS_REQUIRED';
 end if;
 if not exists(select 1 from wali.categories c where c.id=(draft->>'primary_category_id')::uuid and c.active)
   or exists(select 1 from jsonb_array_elements_text(draft->'suggested_tag_ids') id where not exists(select 1 from wali.tags t where t.id=id::uuid and t.active))
   or jsonb_array_length(draft->'suggested_tag_ids')<>(select count(distinct id) from jsonb_array_elements_text(draft->'suggested_tag_ids') id) then
   raise exception using errcode='P0001',message='WALI_REQUEST_INVALID';
 end if;
 select * into license_row from wali.licenses l where l.id=(draft->>'license_id')::uuid and l.active and l.redistribution_allowed;
 if not found or (license_row.attribution_required and draft->>'attribution_text' is null) then
   raise exception using errcode='P0001',message='WALI_RIGHTS_INCOMPLETE';
 end if;
end $$;


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
  if not wali.creator_email_is_verified(actor_id) then raise exception using errcode='P0001',message='WALI_VERIFIED_EMAIL_REQUIRED'; end if;
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

create or replace function wali.require_creator_admission(actor_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare current_version text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if not wali.creator_email_is_verified(actor_id) then raise exception using errcode='P0001',message='WALI_VERIFIED_EMAIL_REQUIRED'; end if;
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
  if admission_kind = 'creator' then perform wali.validate_creator_upload_draft(actor_id,draft);
  else perform wali.validate_curated_draft(actor_id, draft); end if;
  operation := case admission_kind when 'creator' then 'complete_upload' else 'curated.complete_upload' end;
  if exists (select 1 from wali.upload_sessions u where u.id = upload_session_id and u.admission_kind <> complete_admitted_upload.admission_kind) then
    raise exception using errcode = 'P0001', message = 'WALI_ADMISSION_MISMATCH';
  end if;
  request_hash := encode(extensions.digest(upload_session_id::text || ':' || expected_session_revision::text || ':' || draft::text, 'sha256'), 'hex');
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
  if true then
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
      draft ->> 'title',
      draft ->> 'description',
      category_id, license_id, actor_name, 'draft', 'public', 'everyone'
    );
  end if;
  submission_id := gen_random_uuid(); attempt_id := gen_random_uuid();
  insert into wali.submissions (
    id, creator_id, wallpaper_id, proposed_title, proposed_description, primary_category_id, license_id,
    rights_holder, upload_session_id, status, generation, source_url, attribution_text, content_warning, automatic_publication_requested
  ) select submission_id, actor_id, wallpaper_id,
      draft ->> 'title',
      draft ->> 'description',
      category_id,
      license_id,
      actor_name,
      session_row.id, 'processing', 1, draft ->> 'source_url', draft ->> 'attribution_text', draft ->> 'content_warning', true
    from wali.wallpapers w where w.id = wallpaper_id and w.creator_id = actor_id;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_TARGET_INVALID'; end if;
  if true then
    insert into wali.rights_declarations (submission_id, basis, rights_holder, license_id, source_url,
      attribution_text, attested_at, creator_terms_version, attestation_document_kind)
    values (submission_id, (draft ->> 'rights_basis')::wali.rights_basis, draft ->> 'rights_holder', license_id, draft ->> 'source_url',
      draft ->> 'attribution_text', statement_timestamp(),
      case admission_kind when 'creator' then draft ->> 'creator_terms_version' else draft ->> 'attestation_version' end,
      case admission_kind when 'creator' then 'creator_terms' else 'catalog_license_attestation' end);
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
    'submission_id', submission_id, 'revision', (select s.revision from wali.submissions s where s.id=submission_id), 'generation', 1, 'state', 'processing',
    'processing_status_key', submission_id::text || ':1'
  );
  perform wali.complete_command(actor_id, operation, idempotency_key, replay);
  return replay;
end $$;


-- Old clients must supply a reviewed draft rather than publishing placeholder metadata.
create or replace function public.wali_edge_complete_upload_v1(
 actor_id uuid,request_id uuid,idempotency_key text,upload_session_id uuid,expected_session_revision bigint
) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform wali.require_creator_admission(actor_id);
 if exists (select 1 from wali.upload_sessions u where u.id=upload_session_id and u.admission_kind<>'creator') then
  raise exception using errcode='P0001',message='WALI_ADMISSION_MISMATCH';
 end if;
 raise exception using errcode='P0001',message='WALI_UPLOAD_DRAFT_REQUIRED';
end $$;
create function public.wali_edge_complete_upload_v1(
 actor_id uuid,request_id uuid,idempotency_key text,upload_session_id uuid,expected_session_revision bigint,draft jsonb
) returns jsonb language sql security definer set search_path='' as $$
 select wali.complete_admitted_upload(actor_id,request_id,idempotency_key,upload_session_id,expected_session_revision,'creator',draft)
$$;


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
  if (admission_kind = 'creator' and rights_basis = 'other')
     or (admission_kind = 'staff_curated' and rights_basis <> 'licensed')
     or cardinality(proof_object_ids) is distinct from 0 then
    raise exception using errcode = 'P0001', message = 'WALI_RIGHTS_WORKFLOW_UNAVAILABLE';
  end if;
  if creator_terms_version is null or creator_terms_version is distinct from (select case admission_kind when 'creator' then cfg.creator_terms_version else cfg.catalog_license_attestation_version end from wali.runtime_configuration cfg where cfg.singleton)
     or not exists (select 1 from wali.terms_acceptances t where t.user_id = actor_id and t.document_kind = document_kind and t.document_version = creator_terms_version) then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_TERMS_REQUIRED';
  end if;
  select * into license_row from wali.licenses license where license.id = license_id and license.active;
  if not found or not license_row.redistribution_allowed or attests_rights is distinct from true
     or (admission_kind = 'staff_curated' and (not license_row.redistribution_allowed
       or not wali.plain_text_is_valid(attribution_text, 1, 500))) or not wali.plain_text_is_valid(title, 1, 120)
     or not wali.plain_text_is_valid(description, 1, 2000)
     or not wali.plain_text_is_valid(rights_holder, 1, 160)
     or (content_warning is not null and not wali.plain_text_is_valid(content_warning, 1, 500))
     or (attribution_text is not null and not wali.plain_text_is_valid(attribution_text, 1, 500))
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
    reviewed_by = null, reviewed_at = null, system_publication_decision_id=null;
  delete from wali.submission_tag_suggestions suggestion
   where suggestion.submission_id = current_row.id and suggestion.source = 'creator';
  insert into wali.submission_tag_suggestions (submission_id, tag_id, source)
  select current_row.id, tag_id, 'creator'::wali.taxonomy_source from unnest(suggested_tag_ids) tag_id;
  response := jsonb_build_object('submission_id', current_row.id, 'revision', current_row.revision,
    'generation', current_row.generation, 'state', current_row.status, 'field_errors', '[]'::jsonb);
  perform wali.complete_command(actor_id, operation, idempotency_key, response);
  return response;
end $$;

create function wali.automatic_publication_snapshot(target_submission_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('title',s.proposed_title,'description',s.proposed_description,
 'category',s.primary_category_id,'content_rating',s.content_rating_warning,
 'rights',to_jsonb(r)-array['review_status','reviewed_by','reviewed_at','revision','updated_at','system_publication_decision_id'],
 'tags',coalesce((select jsonb_agg(t.tag_id order by t.tag_id) from wali.submission_tag_suggestions t where t.submission_id=s.id and t.source='creator'),'[]'::jsonb))
 from wali.submissions s join wali.rights_declarations r on r.submission_id=s.id where s.id=target_submission_id
$$;
create function wali.require_automatic_publication_lease(target_job_id uuid,target_lease_token uuid)
returns wali.automatic_publication_jobs language plpgsql security definer set search_path='' as $$
declare job wali.automatic_publication_jobs%rowtype;
begin
 if auth.role() is distinct from 'service_role' then raise exception using errcode='P0001',message='WALI_SERVICE_ROLE_REQUIRED'; end if;
 select * into job from wali.automatic_publication_jobs j where j.id=target_job_id for update;
 if not found or job.status<>'leased' or job.lease_token is distinct from target_lease_token
   or job.lease_expires_at<=statement_timestamp() then
   raise exception using errcode='P0001',message='WALI_PUBLICATION_LEASE_LOST';
 end if;
 return job;
end $$;
create function public.wali_edge_claim_automatic_publication_v1() returns jsonb
language plpgsql security definer set search_path='' as $$
declare job wali.automatic_publication_jobs%rowtype;
begin
 if auth.role() is distinct from 'service_role' then raise exception using errcode='P0001',message='WALI_SERVICE_ROLE_REQUIRED'; end if;
 select * into job from wali.automatic_publication_jobs j
 where (j.status='queued' and j.next_attempt_at<=statement_timestamp())
    or (j.status='leased' and j.lease_expires_at<=statement_timestamp())
 order by j.next_attempt_at,j.created_at,j.id for update skip locked limit 1;
 if not found then return jsonb_build_object('job',null); end if;
 update wali.automatic_publication_jobs set status='leased',lease_token=gen_random_uuid(),
  lease_expires_at=statement_timestamp()+interval '3 minutes',attempts=attempts+1 where id=job.id returning * into job;
 return jsonb_build_object('job',jsonb_build_object('id',job.id,'lease_token',job.lease_token));
end $$;

create function wali.prepare_automatic_publication_decision(target_job_id uuid,target_lease_token uuid) returns void
language plpgsql security definer set search_path='' as $$
declare job wali.automatic_publication_jobs%rowtype; s wali.submissions%rowtype;
 r wali.rights_declarations%rowtype; upload wali.upload_sessions%rowtype;
 decision wali.automatic_publication_decisions%rowtype; attempt_id uuid; digest text; current_terms text;
begin
 job:=wali.require_automatic_publication_lease(target_job_id,target_lease_token);
 select * into s from wali.submissions where id=job.submission_id for update;
 select * into r from wali.rights_declarations where submission_id=s.id for update;
 select * into upload from wali.upload_sessions where id=s.upload_session_id for share;
 if not s.automatic_publication_requested or s.generation<>job.generation
   or s.status not in ('ready_for_submission','approved','published')
   or not wali.creator_email_is_verified(s.creator_id)
   or not exists(select 1 from wali.wallpapers w where w.id=s.wallpaper_id and w.status in ('draft','published'))
   or not exists(select 1 from wali.categories c where c.id=s.primary_category_id and c.active)
   or not exists(select 1 from wali.licenses l where l.id=r.license_id and l.active and l.redistribution_allowed)
   or r.id is null or r.review_status='rejected' then
   raise exception using errcode='P0001',message='WALI_AUTOMATIC_PUBLICATION_NOT_ELIGIBLE';
 end if;
 select case upload.admission_kind when 'creator' then cfg.creator_terms_version else cfg.catalog_license_attestation_version end
 into current_terms from wali.runtime_configuration cfg where cfg.singleton;
 if current_terms is null or r.creator_terms_version is distinct from current_terms
   or not exists(select 1 from wali.terms_acceptances t where t.user_id=s.creator_id
       and t.document_kind=r.attestation_document_kind and t.document_version=r.creator_terms_version)
   or (upload.admission_kind='creator' and not wali.edge_actor_has_role(s.creator_id,'creator')) then
   raise exception using errcode='P0001',message='WALI_AUTOMATIC_PUBLICATION_NOT_ELIGIBLE';
 end if;
 if not wali.submission_has_verified_media(s.id,s.generation) then
   raise exception using errcode='P0001',message='WALI_SUBMISSION_NOT_READY';
 end if;
 if job.decision_id is not null then
   select * into decision from wali.automatic_publication_decisions where id=job.decision_id;
   if decision.submission_id<>s.id or decision.generation<>s.generation
      or decision.submission_snapshot is distinct from wali.automatic_publication_snapshot(s.id)
      or r.system_publication_decision_id is distinct from decision.id then
     raise exception using errcode='P0001',message='WALI_PUBLICATION_INTENT_STALE';
   end if;
   return;
 end if;
 if s.status<>'ready_for_submission' or r.review_status<>'pending' then
   raise exception using errcode='P0001',message='WALI_AUTOMATIC_PUBLICATION_NOT_ELIGIBLE';
 end if;
 select p.id into attempt_id from wali.processing_attempts p where p.submission_id=s.id and p.generation=s.generation and p.status='completed';
 select encode(extensions.digest(string_agg(link.role::text||':'||link.artifact_digest,',' order by link.sort_order,link.role),'sha256'),'hex')
 into digest from wali.release_staged_artifacts link join wali.wallpaper_releases release on release.id=link.release_id where release.source_submission_id=s.id;
 insert into wali.automatic_publication_decisions(submission_id,generation,submission_revision,attempt_id,policy_version,submission_snapshot,rights_snapshot,artifact_set_digest)
 values(s.id,s.generation,s.revision,attempt_id,'automatic-publication-2026-09-12',wali.automatic_publication_snapshot(s.id),to_jsonb(r),digest)
 returning * into decision;
 update wali.rights_declarations set review_status='approved',reviewed_by=null,reviewed_at=statement_timestamp(),system_publication_decision_id=decision.id where id=r.id;
 update wali.submissions set status='approved',submitted_at=coalesce(submitted_at,statement_timestamp()),decided_at=statement_timestamp(),last_safe_error_code=null where id=s.id;
 update wali.wallpaper_releases set status='approved' where source_submission_id=s.id and status in ('processing','review');
 update wali.automatic_publication_jobs set decision_id=decision.id where id=job.id;
 insert into wali.audit_events(actor_id,action,target_type,target_id,request_id,metadata)
 values(null,'publication.automatically_approved','submission',s.id,job.id,
   jsonb_build_object('authority','automatic_publication','decision_id',decision.id,'policy_version',decision.policy_version,'generation',s.generation));
end $$;

create function wali.prepare_publication(
  actor_id uuid, actor_aal text, request_id uuid, idempotency_key text,
  submission_id uuid, expected_revision bigint, expected_generation bigint,
  expected_wallpaper_revision bigint, system_job_id uuid, system_lease_token uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare automatic_job wali.automatic_publication_jobs%rowtype; automatic_decision_id uuid; submission_row wali.submissions%rowtype; wallpaper_row wali.wallpapers%rowtype;
  release_row wali.wallpaper_releases%rowtype; key_row wali.catalog_signing_keys%rowtype;
  rights_row wali.rights_declarations%rowtype; intent wali.publication_intents%rowtype;
  artifact_digest text; metadata_set_digest text; promotion_id uuid;
begin
  if auth.role() is distinct from 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if system_job_id is null then
    if actor_aal is distinct from 'aal2' or actor_id is null or not (wali.edge_actor_has_role(actor_id,'moderator') or wali.edge_actor_has_role(actor_id,'admin')) then
      raise exception using errcode='P0001',message='WALI_MODERATOR_AAL2_REQUIRED';
    end if;
  else
    automatic_job:=wali.require_automatic_publication_lease(system_job_id,system_lease_token);
    if actor_id is not null or actor_aal is not null or automatic_job.submission_id<>submission_id
      or automatic_job.generation<>expected_generation or automatic_job.decision_id is null then
      raise exception using errcode='P0001',message='WALI_AUTOMATIC_PUBLICATION_NOT_ELIGIBLE';
    end if;
    automatic_decision_id:=automatic_job.decision_id;
    perform wali.prepare_automatic_publication_decision(system_job_id,system_lease_token);
  end if;
  if automatic_decision_id is not null then
    update wali.publication_intents p set submission_revision=expected_revision
     where p.actor_id is null and p.idempotency_key=prepare_publication.idempotency_key
       and p.system_publication_decision_id=automatic_decision_id and p.consumed_at is null;
  end if;
  select * into intent from wali.publication_intents publication_intent
   where publication_intent.actor_id is not distinct from prepare_publication.actor_id
     and publication_intent.idempotency_key = prepare_publication.idempotency_key
   for update;
  if found and intent.consumed_at is not null then
    if intent.submission_id <> prepare_publication.submission_id
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
  if wallpaper_row.status not in ('draft','published') or wallpaper_row.revision <> expected_wallpaper_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
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
   where p.actor_id is not distinct from prepare_publication.actor_id
     and p.idempotency_key = prepare_publication.idempotency_key for update;
  if found and (intent.submission_id <> submission_row.id or intent.submission_revision <> expected_revision
    or intent.generation <> expected_generation or intent.wallpaper_revision <> expected_wallpaper_revision
    or intent.artifact_set_digest <> artifact_digest or intent.metadata_set_digest <> metadata_set_digest) then
    raise exception using errcode = 'P0001', message = 'WALI_IDEMPOTENCY_CONFLICT';
  end if;
  if not found then
    insert into wali.publication_intents (actor_id, idempotency_key, request_id, submission_id,
      release_id, wallpaper_id, submission_revision, generation, wallpaper_revision,
      artifact_set_digest, metadata_set_digest, signing_key_id, issued_at, expires_at, system_publication_decision_id)
    values (prepare_publication.actor_id, prepare_publication.idempotency_key,
      prepare_publication.request_id, submission_row.id, release_row.id,
      wallpaper_row.id, expected_revision, expected_generation, expected_wallpaper_revision,
      artifact_digest, metadata_set_digest, key_row.key_id, date_trunc('second', statement_timestamp()),
      statement_timestamp() + interval '5 minutes', automatic_decision_id) returning * into intent;
  elsif intent.expires_at <= statement_timestamp() or intent.signing_key_id <> key_row.key_id then
    update wali.publication_intents set request_id = prepare_publication.request_id,
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

create function wali.finalize_publication(
  actor_id uuid, actor_aal text, request_id uuid, idempotency_key text,
  submission_id uuid, expected_revision bigint, expected_generation bigint,
  expected_wallpaper_revision bigint, manifest_body text, metadata_body text,
  manifest_digest text, metadata_digest text, manifest_signature text, signing_key_id text, system_job_id uuid, system_lease_token uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare automatic_job wali.automatic_publication_jobs%rowtype; automatic_decision_id uuid; intent wali.publication_intents%rowtype; release_row wali.wallpaper_releases%rowtype;
  submission_row wali.submissions%rowtype; wallpaper_row wali.wallpapers%rowtype;
  rights_row wali.rights_declarations%rowtype; creator_row wali.profiles%rowtype;
  manifest_bytes bytea; metadata_bytes bytea; signature_bytes bytea; manifest jsonb; metadata jsonb;
  current_artifact_digest text; current_metadata_set_digest text; result_document jsonb;
begin
  if auth.role() is distinct from 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if system_job_id is null then
    if actor_aal is distinct from 'aal2' or actor_id is null or not (wali.edge_actor_has_role(actor_id,'moderator') or wali.edge_actor_has_role(actor_id,'admin')) then
      raise exception using errcode='P0001',message='WALI_MODERATOR_AAL2_REQUIRED';
    end if;
  else
    automatic_job:=wali.require_automatic_publication_lease(system_job_id,system_lease_token);
    if actor_id is not null or actor_aal is not null or automatic_job.submission_id<>submission_id
      or automatic_job.generation<>expected_generation or automatic_job.decision_id is null then
      raise exception using errcode='P0001',message='WALI_AUTOMATIC_PUBLICATION_NOT_ELIGIBLE';
    end if;
    automatic_decision_id:=automatic_job.decision_id;
    perform wali.prepare_automatic_publication_decision(system_job_id,system_lease_token);
  end if;
  select * into intent from wali.publication_intents p
   where p.actor_id is not distinct from finalize_publication.actor_id
     and p.idempotency_key = finalize_publication.idempotency_key for update;
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
     or wallpaper_row.status not in ('draft','published') or release_row.status <> 'approved' or current_artifact_digest <> intent.artifact_set_digest
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
  insert into wali.wallpaper_tags (wallpaper_id, tag_id, source, status, decided_by, decided_at, system_publication_decision_id)
  select wallpaper_row.id, suggestion.tag_id, 'creator'::wali.taxonomy_source, 'approved'::wali.suggestion_status,
    actor_id, statement_timestamp(), automatic_decision_id from wali.submission_tag_suggestions suggestion
   where suggestion.submission_id = submission_row.id and suggestion.source = 'creator';
  update wali.wallpaper_releases set manifest_body = manifest_bytes,
    manifest_digest = finalize_publication.manifest_digest,
    manifest_signature = signature_bytes,
    signing_key_id = finalize_publication.signing_key_id,
    metadata_body = metadata_bytes,
    metadata_digest = finalize_publication.metadata_digest, status = 'published'
    where id = release_row.id;
  update wali.wallpapers set current_release_id = release_row.id, status = 'published',
    published_at = coalesce(published_at, statement_timestamp()) where id = wallpaper_row.id returning * into wallpaper_row;
  update wali.submissions set status = 'published' where id = submission_row.id;
  result_document := jsonb_build_object('wallpaper_id', wallpaper_row.id, 'release_id', release_row.id,
    'edition', release_row.edition, 'manifest_digest', finalize_publication.manifest_digest,
    'key_id', finalize_publication.signing_key_id,
    'wallpaper_revision', wallpaper_row.revision,
    'published_at', to_char(statement_timestamp() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  update wali.publication_intents set consumed_at = statement_timestamp(), response = result_document where id = intent.id;
  insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
  values (finalize_publication.actor_id, 'release.published', 'release', release_row.id,
    finalize_publication.request_id,
    jsonb_build_object('manifest_digest', finalize_publication.manifest_digest,
      'key_id', finalize_publication.signing_key_id,
      'authority',case when automatic_decision_id is null then 'human' else 'automatic_publication' end,
      'system_decision_id',automatic_decision_id));
  return result_document;
end $$;

create or replace function public.wali_edge_prepare_publication_v1(
 actor_id uuid,actor_aal text,request_id uuid,idempotency_key text,submission_id uuid,
 expected_revision bigint,expected_generation bigint,expected_wallpaper_revision bigint
) returns jsonb language sql security definer set search_path='' as $$
 select wali.prepare_publication(actor_id,actor_aal,request_id,idempotency_key,submission_id,expected_revision,expected_generation,expected_wallpaper_revision,null,null)
$$;
create or replace function public.wali_edge_finalize_publication_v1(
 actor_id uuid,actor_aal text,request_id uuid,idempotency_key text,submission_id uuid,
 expected_revision bigint,expected_generation bigint,expected_wallpaper_revision bigint,
 manifest_body text,metadata_body text,manifest_digest text,metadata_digest text,manifest_signature text,signing_key_id text
) returns jsonb language sql security definer set search_path='' as $$
 select wali.finalize_publication(actor_id,actor_aal,request_id,idempotency_key,submission_id,expected_revision,expected_generation,expected_wallpaper_revision,
 manifest_body,metadata_body,manifest_digest,metadata_digest,manifest_signature,signing_key_id,null,null)
$$;
create function public.wali_edge_prepare_automatic_publication_v1(job_id uuid,lease_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job wali.automatic_publication_jobs%rowtype; s wali.submissions%rowtype; w wali.wallpapers%rowtype; receipt jsonb;
begin
 job:=wali.require_automatic_publication_lease(job_id,lease_token);
 -- Lost replies and genuine human publication reconcile the same committed release.
 -- This returns evidence only; it never recreates a decision or republishes bytes.
 select p.response into receipt from wali.publication_intents p
 join wali.submissions source on source.id=p.submission_id and source.generation=p.generation
 join wali.wallpaper_releases release on release.id=p.release_id and release.source_submission_id=source.id
 where p.submission_id=job.submission_id and p.generation=job.generation and p.consumed_at is not null
   and source.status='published' and release.status='published'
   and p.response->>'manifest_digest'=release.manifest_digest
   and p.response->>'release_id'=release.id::text
 order by p.consumed_at desc,p.id limit 1;
 if receipt is not null then return jsonb_build_object('replayed',true,'response',receipt); end if;
 perform wali.prepare_automatic_publication_decision(job_id,lease_token);
 select * into s from wali.submissions where id=job.submission_id for update;
 select * into w from wali.wallpapers where id=s.wallpaper_id for update;
 return wali.prepare_publication(null,null,job.id,'auto_'||replace(job.id::text,'-',''),s.id,s.revision,s.generation,w.revision,job.id,lease_token);
end $$;
create function public.wali_edge_finalize_automatic_publication_v1(
 job_id uuid,lease_token uuid,manifest_body text,metadata_body text,manifest_digest text,metadata_digest text,manifest_signature text,signing_key_id text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare job wali.automatic_publication_jobs%rowtype; intent wali.publication_intents%rowtype;
begin
 job:=wali.require_automatic_publication_lease(job_id,lease_token);
 select * into intent from wali.publication_intents p where p.actor_id is null and p.idempotency_key='auto_'||replace(job.id::text,'-','') for update;
 if not found or intent.system_publication_decision_id is distinct from job.decision_id then
   raise exception using errcode='P0001',message='WALI_PUBLICATION_INTENT_INVALID';
 end if;
 return wali.finalize_publication(null,null,job.id,intent.idempotency_key,job.submission_id,intent.submission_revision,intent.generation,intent.wallpaper_revision,
 manifest_body,metadata_body,manifest_digest,metadata_digest,manifest_signature,signing_key_id,job.id,lease_token);
end $$;

create function public.wali_edge_finish_automatic_publication_v1(job_id uuid,lease_token uuid,outcome text,safe_error_code text default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare job wali.automatic_publication_jobs%rowtype; terminal boolean;
begin
 job:=wali.require_automatic_publication_lease(job_id,lease_token);
 if outcome not in ('completed','retry','failed') or
   (safe_error_code is not null and safe_error_code not in ('WALI_PUBLICATION_RETRYING','WALI_PUBLICATION_FAILED','WALI_PUBLICATION_NOT_ELIGIBLE')) then
   raise exception using errcode='P0001',message='WALI_REQUEST_INVALID';
 end if;
 if outcome='completed' and not exists(select 1 from wali.submissions s where s.id=job.submission_id and s.generation=job.generation and s.status='published') then
   raise exception using errcode='P0001',message='WALI_SUBMISSION_NOT_READY';
 end if;
 terminal:=outcome='failed' or (outcome='retry' and job.attempts>=12);
 update wali.automatic_publication_jobs j set status=case when outcome='completed' then 'completed' when terminal then 'failed' else 'queued' end,
  lease_token=null,lease_expires_at=null,
  next_attempt_at=statement_timestamp()+make_interval(secs=>least(300,5*greatest(job.attempts,1))),
  safe_error_code=case when outcome='completed' then null when terminal then coalesce(wali_edge_finish_automatic_publication_v1.safe_error_code,'WALI_PUBLICATION_FAILED') else wali_edge_finish_automatic_publication_v1.safe_error_code end,
  completed_at=case when outcome='completed' then statement_timestamp() else null end where j.id=job.id;
 update wali.submissions set last_safe_error_code=case when terminal then 'WALI_PUBLICATION_FAILED' else null end
 where id=job.submission_id and status<>'published'
   and last_safe_error_code is distinct from (case when terminal then 'WALI_PUBLICATION_FAILED' else null end);
 return true;
end $$;
create function public.wali_edge_retry_publication_v1(actor_id uuid,request_id uuid,idempotency_key text,submission_id uuid,expected_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s wali.submissions%rowtype; replay jsonb; result jsonb;
begin
 perform wali.require_creator_admission(actor_id);
 replay:=wali.reserve_command(actor_id,'retry_publication',idempotency_key,encode(extensions.digest(submission_id::text||':'||expected_revision::text,'sha256'),'hex'));
 if replay is not null then return replay; end if;
 select * into s from wali.submissions where id=submission_id and creator_id=actor_id for update;
 if not found then raise exception using errcode='P0001',message='WALI_SUBMISSION_NOT_FOUND'; end if;
 if s.revision<>expected_revision then raise exception using errcode='P0001',message='WALI_REVISION_MISMATCH'; end if;
 if not s.automatic_publication_requested or s.status not in ('ready_for_submission','approved') then
   raise exception using errcode='P0001',message='WALI_INVALID_TRANSITION';
 end if;
 update wali.automatic_publication_jobs set status='queued',attempts=0,next_attempt_at=statement_timestamp(),safe_error_code=null,lease_token=null,lease_expires_at=null
 where automatic_publication_jobs.submission_id=s.id and generation=s.generation and status='failed';
 if not found then raise exception using errcode='P0001',message='WALI_PUBLICATION_NOT_RETRYABLE'; end if;
 update wali.submissions set last_safe_error_code=null where id=s.id returning * into s;
 result:=jsonb_build_object('submission_id',s.id,'revision',s.revision,'generation',s.generation,'state',s.status);
 perform wali.complete_command(actor_id,'retry_publication',idempotency_key,result);
 return result;
end $$;

-- Vault contains only this endpoint's narrowly scoped dispatch credential.
-- Missing activation inputs cause no network call and leave durable jobs intact.
create function wali.dispatch_automatic_publication_tick() returns void
language plpgsql security definer set search_path='' as $$
declare token text; base_url text;
begin
 if not exists(select 1 from wali.automatic_publication_jobs where status in ('queued','leased') and next_attempt_at<=statement_timestamp()) then return; end if;
 select decrypted_secret into token from vault.decrypted_secrets where name='wali_automatic_publication_token';
 select regexp_replace(c.catalog_public_base_url,'/storage/v1/object/public/catalog-public$','') into base_url from wali.runtime_configuration c where c.singleton;
 if token is null or token !~ '^[a-f0-9]{64}$' or base_url !~ '^https://[a-z0-9]{20}\.supabase\.co$' then return; end if;
 perform net.http_post(url:=base_url||'/functions/v1/automatic-publication',
   headers:=jsonb_build_object('content-type','application/json','x-wali-publication-token',token),
   body:=jsonb_build_object('api_version','publication_worker.v1'),timeout_milliseconds:=60000);
end $$;
revoke all on function wali.dispatch_automatic_publication_tick() from public,anon,authenticated,service_role;
select cron.schedule('wali-automatic-publication','* * * * *','select wali.dispatch_automatic_publication_tick()');

-- Existing public Creator enrollment becomes available without inventing acceptance.
do $$ begin
 if exists(select 1 from wali.runtime_configuration where creator_terms_version is not null and creator_terms_version not in ('2026-09-01','2026-09-12')) then
   raise exception 'Unexpected Creator Terms version; explicit forward binding required';
 end if;
end $$;
update wali.runtime_configuration set creator_terms_version='2026-09-12',updated_at=statement_timestamp() where singleton;

revoke all on function public.wali_edge_complete_upload_v1(uuid,uuid,text,uuid,bigint,jsonb) from public,anon,authenticated;
grant execute on function public.wali_edge_complete_upload_v1(uuid,uuid,text,uuid,bigint,jsonb) to service_role;
revoke all on function public.wali_edge_claim_automatic_publication_v1() from public,anon,authenticated;
revoke all on function public.wali_edge_prepare_automatic_publication_v1(uuid,uuid) from public,anon,authenticated;
revoke all on function public.wali_edge_finalize_automatic_publication_v1(uuid,uuid,text,text,text,text,text,text) from public,anon,authenticated;
revoke all on function public.wali_edge_finish_automatic_publication_v1(uuid,uuid,text,text) from public,anon,authenticated;
revoke all on function public.wali_edge_retry_publication_v1(uuid,uuid,text,uuid,bigint) from public,anon,authenticated;
grant execute on function public.wali_edge_claim_automatic_publication_v1(),public.wali_edge_prepare_automatic_publication_v1(uuid,uuid),
 public.wali_edge_finalize_automatic_publication_v1(uuid,uuid,text,text,text,text,text,text),public.wali_edge_finish_automatic_publication_v1(uuid,uuid,text,text),
 public.wali_edge_retry_publication_v1(uuid,uuid,text,uuid,bigint) to service_role;
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
  request_hash := encode(extensions.digest(
    declared_byte_count::text || ':' || container_hint || ':' || original_filename || ':' || target_kind || ':' ||
    coalesce(target_wallpaper_id::text, '') || ':' || coalesce(expected_wallpaper_revision::text, ''), 'sha256'
  ), 'hex');
  replay := wali.reserve_command(actor_id, 'create_upload', idempotency_key, request_hash);
  if replay is not null then
    select * into session_row from wali.upload_sessions where id = (replay ->> 'upload_session_id')::uuid;
    return replay || jsonb_build_object('revision', session_row.revision, 'upload_endpoint', session_row.upload_endpoint);
  end if;
  if (select count(*) from wali.submissions s where s.creator_id = actor_id and s.status in ('processing', 'submitted', 'under_review')) >= 2 then
    raise exception using errcode = 'P0001', message = 'WALI_PROCESSING_CAPACITY_UNAVAILABLE';
  end if;
  if (select count(*) from wali.upload_sessions u where u.creator_id=actor_id and u.admission_kind='creator'
    and u.created_at>=date_trunc('day',statement_timestamp(),'UTC'))>=24 then
    raise exception using errcode='P0001',message='WALI_UPLOAD_DAILY_QUOTA_EXCEEDED';
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
  update wali.submissions set status = 'ready_for_submission', automatic_publication_requested=true, submitted_at = statement_timestamp() where id = current_row.id
  returning jsonb_build_object('submission_id', id, 'revision', revision, 'generation', generation, 'state', status) into response;
  perform wali.complete_command(actor_id, 'submit_wallpaper_edge', idempotency_key, response);
  return response;
end $$;
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
      'id', license.id, 'name', license.name, 'code', license.code, 'terms_url', license.terms_url,
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
      jsonb_build_object('basis', 'licensed', 'available', true,
        'requires_source_url', true, 'requires_proof', false),
      jsonb_build_object('basis', 'other', 'available', false,
        'requires_source_url', false, 'requires_proof', true)
    ),
    'current_creator_terms_version', (select config.creator_terms_version
      from wali.runtime_configuration config where config.singleton)
  ) into response;
  return response;
end $$;
-- New implementation helpers are callable only inside owned security-definer RPCs.
revoke all on function wali.enqueue_automatic_publication(),wali.guard_automatic_publication_request(),
 wali.validate_creator_upload_draft(uuid,jsonb),wali.automatic_publication_snapshot(uuid),
 wali.require_automatic_publication_lease(uuid,uuid),wali.prepare_automatic_publication_decision(uuid,uuid),
 wali.prepare_publication(uuid,text,uuid,text,uuid,bigint,bigint,bigint,uuid,uuid),
 wali.finalize_publication(uuid,text,uuid,text,uuid,bigint,bigint,bigint,text,text,text,text,text,text,uuid,uuid)
 from public,anon,authenticated;
commit;
