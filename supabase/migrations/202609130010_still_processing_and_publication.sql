-- ADR 0027: strict still processing alongside immutable legacy video contracts.
-- Intake stays disabled until the reviewed worker, signing and catalog V2 ship.
begin;
alter table wali.runtime_configuration add column still_uploads_enabled boolean not null default false,
 add column still_policy_digest text,
 add constraint still_policy_digest_valid check(still_policy_digest is null or still_policy_digest~'^[a-f0-9]{64}$'),
 add constraint still_intake_requires_policy check(not still_uploads_enabled or still_policy_digest is not null);
alter table wali.upload_sessions add column media_kind text not null default 'video' check(media_kind in ('video','still'));
alter table wali.submissions add column media_kind text not null default 'video' check(media_kind in ('video','still'));
alter table wali.wallpaper_releases add column media_kind text not null default 'video' check(media_kind in ('video','still'));
alter table wali.upload_sessions drop constraint upload_declared_media_type, drop constraint upload_sessions_media_type;
alter table wali.upload_sessions add constraint upload_declared_media_type check(
 (media_kind='video' and declared_media_type in ('video/mp4','video/quicktime')) or
 (media_kind='still' and declared_media_type in ('image/jpeg','image/png') and declared_byte_count<=134217728)),
 add constraint upload_sessions_media_type check(detected_media_type is null or
 (media_kind='video' and detected_media_type in ('video/mp4','video/quicktime')) or
 (media_kind='still' and detected_media_type in ('image/jpeg','image/png')));
alter table wali.wallpaper_releases drop constraint wallpaper_releases_manifest_epoch_check;
alter table wali.wallpaper_releases add constraint release_kind_epoch check(
 (media_kind='video' and manifest_epoch=1) or (media_kind='still' and manifest_epoch=2 and manifest_revision=0));
alter table wali.artifacts drop constraint artifacts_height_check;
alter table wali.artifacts add constraint artifacts_height_check check(height between 1 and 7680 and (media_type<>'video/mp4' or height<=4320));
alter table wali.staged_artifacts drop constraint staged_artifacts_height_check;
alter table wali.staged_artifacts add constraint staged_artifacts_height_check check(height between 1 and 7680 and (media_type<>'video/mp4' or height<=4320));
update storage.buckets set allowed_mime_types=array['video/mp4','video/quicktime','image/jpeg','image/png'] where id='uploads-private';

create function wali.guard_media_kind() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' and new.media_kind is distinct from old.media_kind then
  raise exception using errcode='P0001',message='WALI_MEDIA_KIND_IMMUTABLE';
 end if;
 if tg_op='INSERT' then
  if tg_table_name='upload_sessions' and new.media_kind='still' and
    (auth.role() is distinct from 'service_role' or not exists(select 1 from wali.runtime_configuration where singleton and still_uploads_enabled)) then
   raise exception using errcode='P0001',message='WALI_STILL_INTAKE_DISABLED';
  elsif tg_table_name='submissions' then
   if not exists(select 1 from wali.upload_sessions u where u.id=new.upload_session_id and u.media_kind=new.media_kind) then
    raise exception using errcode='P0001',message='WALI_MEDIA_KIND_MISMATCH';
   end if;
  elsif tg_table_name='wallpaper_releases' then
   if not exists(select 1 from wali.submissions s where s.id=new.source_submission_id and s.media_kind=new.media_kind) then
    raise exception using errcode='P0001',message='WALI_MEDIA_KIND_MISMATCH';
   end if;
  end if;
 end if;
 return new;
end $$;
create trigger upload_media_kind before insert or update of media_kind on wali.upload_sessions for each row execute function wali.guard_media_kind();
create trigger submission_media_kind before insert or update of media_kind on wali.submissions for each row execute function wali.guard_media_kind();
create trigger release_media_kind before insert or update of media_kind on wali.wallpaper_releases for each row execute function wali.guard_media_kind();
revoke all on function wali.guard_media_kind() from public,anon,authenticated,service_role,wali_worker;


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
  if declared_byte_count not between 1 and 1073741824 or container_hint not in ('video/mp4', 'video/quicktime','image/jpeg','image/png')
     or (container_hint in ('image/jpeg','image/png') and declared_byte_count>134217728)
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
  if container_hint in ('image/jpeg','image/png') and not exists(select 1 from wali.runtime_configuration where singleton and still_uploads_enabled) then
    raise exception using errcode='P0001',message='WALI_STILL_INTAKE_DISABLED';
  end if;
  session_row.id := gen_random_uuid();
  insert into wali.upload_sessions (
    id, creator_id, storage_path, original_filename, declared_byte_count, declared_media_type,
    target_wallpaper_id, status, expires_at, idempotency_key, media_kind
  ) values (
    session_row.id, actor_id, actor_id::text || '/' || session_row.id::text || '/source', original_filename,
    declared_byte_count, container_hint, target_wallpaper_id, 'issued', statement_timestamp() + interval '24 hours', idempotency_key, case when container_hint in ('image/jpeg','image/png') then 'still' else 'video' end
  ) returning * into session_row;
  replay := jsonb_build_object(
    'upload_session_id', session_row.id, 'storage_path', session_row.storage_path,
    'expires_at', to_char(session_row.expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'revision', session_row.revision, 'upload_endpoint', session_row.upload_endpoint
  );
  perform wali.complete_command(actor_id, 'create_upload', idempotency_key, replay);
  return replay;
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
  if observed_size <> session_row.declared_byte_count or observed_type is distinct from session_row.declared_media_type
     or (session_row.media_kind='still' and (observed_size>134217728 or not exists(select 1 from wali.runtime_configuration where singleton and still_uploads_enabled))) then
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
    rights_holder, upload_session_id, status, generation, source_url, attribution_text, content_warning, automatic_publication_requested, media_kind
  ) select submission_id, actor_id, wallpaper_id,
      draft ->> 'title',
      draft ->> 'description',
      category_id,
      license_id,
      actor_name,
      session_row.id, 'processing', 1, draft ->> 'source_url', draft ->> 'attribution_text', draft ->> 'content_warning', true, session_row.media_kind
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
    'schema_version', case session_row.media_kind when 'still' then 2 else 1 end, 'attempt_id', attempt_id, 'submission_id', submission_id, 'generation', 1,
    'input', jsonb_build_object('bucket', 'uploads-private', 'path', session_row.storage_path,
      'byte_count', observed_size, 'storage_version', object_row.version),
    'policy_digest', (select case session_row.media_kind when 'still' then still_policy_digest else media_policy_digest end from wali.runtime_configuration where singleton),
    'expected_artifact_roles', case session_row.media_kind when 'still' then jsonb_build_array('thumbnail','poster','image_default') else jsonb_build_array('thumbnail', 'poster', 'preview', 'video_default') end,
    'extensions', jsonb_build_object('deadline_policy', case session_row.media_kind when 'still' then 'first_queue_lease_v1' else 'first_queue_lease_video_90m_v1' end),
    'deadline_at', to_char(statement_timestamp() + case session_row.media_kind when 'still' then interval '20 minutes' else interval '90 minutes' end, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ) || case session_row.media_kind when 'still' then jsonb_build_object('media_kind','still') else '{}'::jsonb end);
  replay := jsonb_build_object(
    'submission_id', submission_id, 'revision', (select s.revision from wali.submissions s where s.id=submission_id), 'generation', 1, 'state', 'processing',
    'processing_status_key', submission_id::text || ':1'
  );
  perform wali.complete_command(actor_id, operation, idempotency_key, replay);
  return replay;
end $$;

create or replace function public.wali_edge_retry_processing_v1(
 actor_id uuid,request_id uuid,idempotency_key text,submission_id uuid,expected_revision bigint
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 s wali.submissions%rowtype; upload wali.upload_sessions%rowtype;
 rights wali.rights_declarations%rowtype; source storage.objects%rowtype;
 previous wali.processing_attempts%rowtype; replay jsonb; result jsonb;
 attempt_id uuid:=gen_random_uuid(); maximum_attempts integer; policy_digest text;
begin
 -- This also serializes this account's existing upload/processing admissions.
 perform wali.require_creator_admission(actor_id);
 if request_id is null or submission_id is null or expected_revision is null or expected_revision<1 then
  raise exception using errcode='P0001',message='WALI_REQUEST_INVALID';
 end if;
 replay:=wali.reserve_command(actor_id,'retry_processing',idempotency_key,
  encode(extensions.digest(submission_id::text||':'||expected_revision::text,'sha256'),'hex'));
 if replay is not null then return replay; end if;
 select * into s from wali.submissions row where row.id=submission_id and row.creator_id=actor_id for update;
 if not found then raise exception using errcode='P0001',message='WALI_SUBMISSION_NOT_FOUND'; end if;
 if s.revision<>expected_revision then raise exception using errcode='P0001',message='WALI_REVISION_MISMATCH'; end if;
 if s.status<>'processing_failed' or not s.automatic_publication_requested then
  raise exception using errcode='P0001',message='WALI_INVALID_TRANSITION';
 end if;
 select * into upload from wali.upload_sessions row where row.id=s.upload_session_id and row.creator_id=actor_id for share;
 if not found or upload.admission_kind<>'creator' then
  raise exception using errcode='P0001',message='WALI_ADMISSION_MISMATCH';
 end if;
 -- The locked submission prevents an old Begin from restarting this generation.
 -- Do not take the old attempt lock after the submission: Begin locks in the reverse order.
 select * into previous from wali.processing_attempts row where row.submission_id=s.id and row.generation=s.generation;
 if not found or previous.status not in ('failed','timed_out') or previous.finished_at is null then
  raise exception using errcode='P0001',message='WALI_INVALID_TRANSITION';
 end if;
 select least(max_attempts,5) into maximum_attempts from wali.queue_policies where queue_name='wali_media_processing';
 if maximum_attempts is null or s.generation>=maximum_attempts or
  (select count(*) from wali.processing_attempts row where row.submission_id=s.id)>=maximum_attempts then
  raise exception using errcode='P0001',message='WALI_PROCESSING_RETRY_LIMIT_REACHED';
 end if;
 if (select count(*) from wali.submissions row where row.creator_id=actor_id and row.status in ('processing','submitted','under_review'))>=2 then
  raise exception using errcode='P0001',message='WALI_PROCESSING_CAPACITY_UNAVAILABLE';
 end if;
 select * into rights from wali.rights_declarations row where row.submission_id=s.id for share;
 if not found or rights.review_status<>'pending' or rights.attestation_document_kind<>'creator_terms'
  or rights.creator_terms_version is distinct from (select creator_terms_version from wali.runtime_configuration where singleton)
  or rights.license_id is distinct from s.license_id or rights.rights_holder is distinct from s.rights_holder
  or rights.source_url is distinct from s.source_url or rights.attribution_text is distinct from s.attribution_text
  or not exists(select 1 from wali.categories c where c.id=s.primary_category_id and c.active)
  or not exists(select 1 from wali.licenses l where l.id=rights.license_id and l.active and l.redistribution_allowed
   and (not l.attribution_required or rights.attribution_text is not null))
  or not exists(select 1 from wali.wallpapers w where w.id=s.wallpaper_id and w.creator_id=actor_id and w.status in ('draft','published')) then
  raise exception using errcode='P0001',message='WALI_RIGHTS_INCOMPLETE';
 end if;
 -- A completed TUS session keeps its existing object version and size. Its old
 -- upload-URL expiry is irrelevant; the existing 30-day raw retention is not reset.
 if upload.status<>'completed' or upload.storage_version is null or upload.received_byte_count is null
  or upload.updated_at<=statement_timestamp()-interval '30 days'
  or exists(select 1 from wali.cleanup_object_intents c where c.bucket_id='uploads-private'
   and c.storage_path=upload.storage_path and c.status in ('queued','processing')) then
  raise exception using errcode='P0001',message='WALI_UPLOAD_CHANGED';
 end if;
 select * into source from storage.objects o where o.bucket_id='uploads-private' and o.name=upload.storage_path
  and o.owner_id=actor_id::text and not coalesce(o.is_delete_marker,false) for share;
 if not found or source.version is distinct from upload.storage_version
  or coalesce(source.metadata->>'size','')!~'^[0-9]{1,10}$'
  or (source.metadata->>'size')::bigint<>upload.received_byte_count
  or upload.received_byte_count<>upload.declared_byte_count
  or coalesce(source.metadata->>'mimetype',source.metadata->>'contentType') is distinct from upload.detected_media_type then
  raise exception using errcode='P0001',message='WALI_UPLOAD_CHANGED';
 end if;
 select case s.media_kind when 'still' then still_policy_digest else media_policy_digest end into policy_digest from wali.runtime_configuration where singleton;
 if policy_digest is null or policy_digest!~'^[a-f0-9]{64}$' or (s.media_kind='still' and not exists(select 1 from wali.runtime_configuration where singleton and still_uploads_enabled)) then
  raise exception using errcode='P0001',message='WALI_PROCESSING_CAPACITY_UNAVAILABLE';
 end if;
 update wali.submissions set status='processing',generation=s.generation+1,last_safe_error_code=null
  where id=s.id returning * into s;
 insert into wali.processing_attempts(id,submission_id,generation,status) values(attempt_id,s.id,s.generation,'queued');
 perform pgmq.send('wali_media_processing',jsonb_build_object(
  'schema_version',case s.media_kind when 'still' then 2 else 1 end,'attempt_id',attempt_id,'submission_id',s.id,'generation',s.generation,
  'input',jsonb_build_object('bucket','uploads-private','path',upload.storage_path,
   'byte_count',upload.received_byte_count,'storage_version',upload.storage_version),
  'policy_digest',policy_digest,'expected_artifact_roles',case s.media_kind when 'still' then jsonb_build_array('thumbnail','poster','image_default') else jsonb_build_array('thumbnail','poster','preview','video_default') end,
  'extensions',jsonb_build_object('deadline_policy',case s.media_kind when 'still' then 'first_queue_lease_v1' else 'first_queue_lease_video_90m_v1' end),
  'deadline_at',to_char(statement_timestamp()+case s.media_kind when 'still' then interval '20 minutes' else interval '90 minutes' end,'YYYY-MM-DD"T"HH24:MI:SS"Z"')
 )||case s.media_kind when 'still' then jsonb_build_object('media_kind','still') else '{}'::jsonb end);
 result:=jsonb_build_object('submission_id',s.id,'revision',s.revision,'generation',s.generation,'state','processing');
 perform wali.complete_command(actor_id,'retry_processing',idempotency_key,result);
 return result;
end $$;

create or replace function wali.worker_queue_read(queue_name text, visibility_seconds integer)
returns table (msg_id bigint, message jsonb, vt timestamptz)
language plpgsql security definer set search_path = '' as $$
declare queued record; attempt wali.processing_attempts%rowtype;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.worker_queue_allowed(queue_name) or visibility_seconds not between 30 and 1800 then
    raise exception using errcode = 'P0001', message = 'WALI_QUEUE_NOT_ALLOWED';
  end if;
  for queued in select q.msg_id,q.message,q.vt from pgmq.read(queue_name,visibility_seconds,1,case when queue_name in ('wali_media_processing','wali_promotions') then '{"schema_version":1}'::jsonb else '{}'::jsonb end) q loop
    msg_id := queued.msg_id; message := queued.message; vt := queued.vt;
    if queue_name = 'wali_media_processing' and queued.message->>'schema_version' = '1'
       and (queued.message->'extensions'->>'deadline_policy' = 'first_queue_lease_v1'
         or (queued.message->>'schema_version'='1' and queued.message->'extensions'->>'deadline_policy'='first_queue_lease_video_90m_v1')) then
      -- Text comparison deliberately leaves malformed UUID/generation values
      -- untouched for the existing bounded Go decoder/rejection path.
      select p.* into attempt from wali.processing_attempts p
        join wali.submissions s on s.id=p.submission_id and s.generation=p.generation
       where p.id::text=queued.message->>'attempt_id'
         and p.submission_id::text=queued.message->>'submission_id'
         and p.generation::text=queued.message->>'generation'
         and s.status='processing'
         and p.status in ('queued','leased','downloading','transcoding','verifying','classifying')
       for update of p;
      if found then
        if attempt.execution_deadline_at is null then
          -- A prior Begin during mixed-version rollback must not gain time.
          update wali.processing_attempts p set execution_deadline_at=
            coalesce(p.started_at,statement_timestamp()) + case
              when queued.message->'extensions'->>'deadline_policy'='first_queue_lease_video_90m_v1' then interval '90 minutes'
              else interval '20 minutes' end
           where p.id=attempt.id and p.execution_deadline_at is null
           returning p.* into attempt;
        end if;
        message := jsonb_set(queued.message,'{deadline_at}',to_jsonb(to_char(
          attempt.execution_deadline_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
      end if;
    end if;
    return next;
  end loop;
end $$;

create or replace function wali.worker_queue_read_v2(queue_name text, visibility_seconds integer)
returns table (msg_id bigint, message jsonb, vt timestamptz)
language plpgsql security definer set search_path = '' as $$
declare queued record; attempt wali.processing_attempts%rowtype;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not wali.worker_queue_allowed(queue_name) or visibility_seconds not between 30 and 1800 then
    raise exception using errcode = 'P0001', message = 'WALI_QUEUE_NOT_ALLOWED';
  end if;
  for queued in select q.msg_id,q.message,q.vt from pgmq.read(queue_name,visibility_seconds,1) q loop
    msg_id := queued.msg_id; message := queued.message; vt := queued.vt;
    if queue_name = 'wali_media_processing' and (queued.message->>'schema_version' = '1' or (queued.message->>'schema_version' = '2' and queued.message->>'media_kind'='still'))
       and (queued.message->'extensions'->>'deadline_policy' = 'first_queue_lease_v1'
         or (queued.message->>'schema_version'='1' and queued.message->'extensions'->>'deadline_policy'='first_queue_lease_video_90m_v1')) then
      -- Text comparison deliberately leaves malformed UUID/generation values
      -- untouched for the existing bounded Go decoder/rejection path.
      select p.* into attempt from wali.processing_attempts p
        join wali.submissions s on s.id=p.submission_id and s.generation=p.generation
       where p.id::text=queued.message->>'attempt_id'
         and p.submission_id::text=queued.message->>'submission_id'
         and p.generation::text=queued.message->>'generation'
         and s.media_kind=case queued.message->>'schema_version' when '2' then 'still' else 'video' end
         and s.status='processing'
         and p.status in ('queued','leased','downloading','transcoding','verifying','classifying')
       for update of p;
      if found then
        if attempt.execution_deadline_at is null then
          -- A prior Begin during mixed-version rollback must not gain time.
          update wali.processing_attempts p set execution_deadline_at=
            coalesce(p.started_at,statement_timestamp()) + case
              when queued.message->'extensions'->>'deadline_policy'='first_queue_lease_video_90m_v1' then interval '90 minutes'
              else interval '20 minutes' end
           where p.id=attempt.id and p.execution_deadline_at is null
           returning p.* into attempt;
        end if;
        message := jsonb_set(queued.message,'{deadline_at}',to_jsonb(to_char(
          attempt.execution_deadline_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
      end if;
    end if;
    return next;
  end loop;
end $$;

create function wali.still_artifact_claim_is_valid(a jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
begin
 if jsonb_typeof(a) is distinct from 'object' or
 (select array_agg(k order by k) from jsonb_object_keys(a) k) is distinct from
 array['byte_count','codec','color_space','digest','duration_ms','frame_rate_denominator','frame_rate_numerator','has_audio','height','media_type','pixel_format','role','width']::text[] then return false; end if;
 return coalesce(jsonb_typeof(a->'digest')='string' and a->>'digest'~'^[a-f0-9]{64}$' and a->'has_audio'='false'::jsonb
  and a->'duration_ms'='0'::jsonb and a->'frame_rate_numerator'='0'::jsonb and a->'frame_rate_denominator'='1'::jsonb
  and jsonb_typeof(a->'byte_count')='number' and (a->>'byte_count')~'^[0-9]+$' and (a->>'byte_count')::bigint between 1 and 134217728
  and jsonb_typeof(a->'width')='number' and (a->>'width')~'^[0-9]+$' and (a->>'width')::integer between 1 and 7680
  and jsonb_typeof(a->'height')='number' and (a->>'height')~'^[0-9]+$' and (a->>'height')::integer between 1 and 7680
  and (a->>'width')::bigint*(a->>'height')::bigint<=33177600 and
  case a->>'role'
   when 'image_default' then a->>'media_type'='image/png' and a->>'codec'='png' and a->>'pixel_format'='rgb24' and a->>'color_space'='srgb'
   when 'poster' then (a->>'byte_count')::bigint<=16777216 and a->>'media_type'='image/jpeg' and a->>'codec'='mjpeg' and a->>'pixel_format'='yuvj420p' and a->>'color_space'='bt470bg' and (a->>'width')::integer<=1920 and (a->>'height')::integer<=1920
   when 'thumbnail' then (a->>'byte_count')::bigint<=16777216 and a->>'media_type'='image/jpeg' and a->>'codec'='mjpeg' and a->>'pixel_format'='yuvj420p' and a->>'color_space'='bt470bg' and (a->>'width')::integer=512 and (a->>'height')::integer=512
   else false end,false);
exception when others then return false;
end $$;
revoke all on function wali.still_artifact_claim_is_valid(jsonb) from public,anon,authenticated,service_role,wali_worker;

create or replace function wali.worker_begin_attempt(
  target_attempt_id uuid, target_submission_id uuid, expected_generation integer,
  worker_identity text, lease_until timestamptz
) returns text language plpgsql security definer set search_path = '' as $$
declare attempt_row wali.processing_attempts%rowtype; submission_row wali.submissions%rowtype;
  upload_row wali.upload_sessions%rowtype; object_row storage.objects%rowtype; object_size bigint;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if exists(select 1 from wali.processing_attempts p join wali.submissions s on s.id=p.submission_id where p.id=target_attempt_id and s.media_kind<>'video') then raise exception using errcode='P0001',message='WALI_MEDIA_KIND_MISMATCH'; end if;
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

create or replace function wali.worker_begin_still_attempt_v2(
  target_attempt_id uuid, target_submission_id uuid, expected_generation integer,
  worker_identity text, lease_until timestamptz
) returns text language plpgsql security definer set search_path = '' as $$
declare attempt_row wali.processing_attempts%rowtype; submission_row wali.submissions%rowtype;
  upload_row wali.upload_sessions%rowtype; object_row storage.objects%rowtype; object_size bigint;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if exists(select 1 from wali.processing_attempts p join wali.submissions s on s.id=p.submission_id where p.id=target_attempt_id and s.media_kind<>'still') then raise exception using errcode='P0001',message='WALI_MEDIA_KIND_MISMATCH'; end if;
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
  if upload_row.media_kind<>'still' or upload_row.detected_media_type not in ('image/jpeg','image/png') or object_size>134217728
     or upload_row.status <> 'completed' or object_row.id is null
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

create or replace function wali.worker_authorize_staged_artifact(
  target_attempt_id uuid, expected_generation integer, worker_identity text, artifact jsonb
) returns boolean language plpgsql security definer set search_path = '' as $$
declare attempt_row wali.processing_attempts%rowtype; extension text; expected_path text;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if exists(select 1 from wali.processing_attempts p join wali.submissions s on s.id=p.submission_id where p.id=target_attempt_id and s.media_kind<>'video') then raise exception using errcode='P0001',message='WALI_MEDIA_KIND_MISMATCH'; end if;
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

create or replace function wali.worker_authorize_still_artifact_v2(
  target_attempt_id uuid, expected_generation integer, worker_identity text, artifact jsonb
) returns boolean language plpgsql security definer set search_path = '' as $$
declare attempt_row wali.processing_attempts%rowtype; extension text; expected_path text;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if exists(select 1 from wali.processing_attempts p join wali.submissions s on s.id=p.submission_id where p.id=target_attempt_id and s.media_kind<>'still') then raise exception using errcode='P0001',message='WALI_MEDIA_KIND_MISMATCH'; end if;
  if not wali.still_artifact_claim_is_valid(artifact) then raise exception using errcode='P0001',message='WALI_WORKER_OUTPUT_INVALID'; end if;
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

create or replace function wali.worker_complete_attempt(
  target_attempt_id uuid, expected_generation integer, worker_identity text, completion jsonb
) returns boolean language plpgsql security definer set search_path = '' as $$
declare attempt_row wali.processing_attempts%rowtype; submission_row wali.submissions%rowtype;
  upload_row wali.upload_sessions%rowtype; raw_object storage.objects%rowtype; artifact jsonb;
  target_release_id uuid; computed_source_digest text; roles text[]; expected_path text; extension text;
  classification jsonb; run_id uuid; safe_summary jsonb;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if exists(select 1 from wali.processing_attempts p join wali.submissions s on s.id=p.submission_id where p.id=target_attempt_id and s.media_kind<>'video') then raise exception using errcode='P0001',message='WALI_MEDIA_KIND_MISMATCH'; end if;
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

create or replace function wali.worker_complete_still_attempt_v2(
  target_attempt_id uuid, expected_generation integer, worker_identity text, completion jsonb
) returns boolean language plpgsql security definer set search_path = '' as $$
declare attempt_row wali.processing_attempts%rowtype; submission_row wali.submissions%rowtype;
  upload_row wali.upload_sessions%rowtype; raw_object storage.objects%rowtype; artifact jsonb;
  target_release_id uuid; computed_source_digest text; roles text[]; expected_path text; extension text;
  classification jsonb; run_id uuid; safe_summary jsonb;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if exists(select 1 from wali.processing_attempts p join wali.submissions s on s.id=p.submission_id where p.id=target_attempt_id and s.media_kind<>'still') then raise exception using errcode='P0001',message='WALI_MEDIA_KIND_MISMATCH'; end if;
  if jsonb_typeof(completion) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(completion) k)
       <> array['artifacts','classification','media_kind','schema_version','source_digest']::text[]
     or completion->'schema_version' is distinct from '2'::jsonb or completion->>'media_kind' is distinct from 'still'
     or jsonb_typeof(completion->'source_digest') is distinct from 'string'
     or not coalesce(completion ->> 'source_digest' ~ '^[0-9a-f]{64}$',false)
     or jsonb_typeof(completion -> 'artifacts') <> 'array'
     or jsonb_array_length(completion -> 'artifacts') <> 3
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
  if submission_row.generation<>expected_generation or submission_row.status<>'processing' then return false; end if;
  select * into upload_row from wali.upload_sessions u where u.id = submission_row.upload_session_id for share;
  select * into raw_object from storage.objects o where o.bucket_id = 'uploads-private'
    and o.name = upload_row.storage_path and o.version = upload_row.storage_version
    and not coalesce(o.is_delete_marker, false) for share;
  if raw_object.id is null or coalesce((raw_object.metadata ->> 'size')::bigint, 0) <> upload_row.received_byte_count then
    raise exception using errcode = 'P0001', message = 'WALI_UPLOAD_CHANGED';
  end if;
  select array_agg(value ->> 'role' order by value ->> 'role') into roles
    from jsonb_array_elements(completion -> 'artifacts');
  if roles <> array['image_default','poster','thumbnail']::text[] then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID';
  end if;
  for artifact in select value from jsonb_array_elements(completion -> 'artifacts') loop
    if not wali.still_artifact_claim_is_valid(artifact) then raise exception using errcode='P0001',message='WALI_WORKER_OUTPUT_INVALID'; end if;
    extension := case artifact ->> 'media_type' when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'video/mp4' then 'mp4' else null end;
    if extension is null then raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID'; end if;
    expected_path := 'sha256/' || substring((artifact ->> 'digest') from 1 for 2) || '/' ||
      substring((artifact ->> 'digest') from 3 for 2) || '/' || (artifact ->> 'digest') || '/' ||
      replace((artifact ->> 'role'), '_', '-') || '.' || extension;
    if not exists (select 1 from wali.staged_upload_intents intent
      where intent.attempt_id = attempt_row.id and intent.generation = expected_generation
        and intent.worker_identity = worker_complete_still_attempt_v2.worker_identity
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
    insert into wali.wallpaper_releases (wallpaper_id, edition, source_submission_id, status, media_kind, manifest_epoch)
    select submission_row.wallpaper_id, coalesce(max(r.edition), 0) + 1, submission_row.id, 'processing', 'still', 2
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
     and intent.worker_identity = worker_complete_still_attempt_v2.worker_identity;
  update wali.upload_sessions set source_digest = computed_source_digest where id = upload_row.id;
  update wali.processing_attempts set status = 'completed', output_summary = safe_summary,
    finished_at = statement_timestamp(), lease_owner = null, lease_expires_at = null where id = attempt_row.id;
  update wali.submissions set status = 'ready_for_submission', last_safe_error_code = null where id = submission_row.id;
  return true;
end $$;

create or replace function wali.submission_has_verified_media(target_submission_id uuid, expected_generation integer)
returns boolean language plpgsql stable set search_path = '' as $$
declare attempt wali.processing_attempts%rowtype; claims jsonb; media_kind text;
begin
  select p.* into attempt from wali.processing_attempts p
    join wali.submissions s on s.id = p.submission_id and s.generation = p.generation
   where p.submission_id = target_submission_id and p.generation = expected_generation
     and p.status = 'completed';
  if not found then return false; end if;
  select s.media_kind into media_kind from wali.submissions s where s.id=target_submission_id;
  if media_kind='still' and (attempt.output_summary->'schema_version' is distinct from '2'::jsonb or attempt.output_summary->>'media_kind' is distinct from 'still') then return false; end if;
  claims := attempt.output_summary -> 'artifacts';
  if jsonb_typeof(claims) is distinct from 'array' then return false; end if;
  if jsonb_array_length(claims) <> (case media_kind when 'still' then 3 else 4 end) then return false; end if;
  if (select array_agg(value ->> 'role' order by value ->> 'role') from jsonb_array_elements(claims))
       is distinct from (case media_kind when 'still' then array['image_default','poster','thumbnail']::text[] else array['poster','preview','thumbnail','video_default']::text[] end) then
    return false;
  end if;
  return not exists (
    select 1 from jsonb_array_elements(claims) claim
     where not exists (
       select 1 from wali.wallpaper_releases release
       join wali.release_staged_artifacts link on link.release_id = release.id
       join wali.staged_artifacts artifact on artifact.digest = link.artifact_digest
       join storage.objects object on object.bucket_id = artifact.storage_bucket and object.name = artifact.storage_path
        where release.source_submission_id = target_submission_id
          and release.media_kind=(select s.media_kind from wali.submissions s where s.id=target_submission_id)
          and link.role::text = claim ->> 'role' and artifact.digest = claim ->> 'digest'
          and artifact.byte_count = (claim ->> 'byte_count')::bigint
          and artifact.media_type = claim ->> 'media_type'
          and not coalesce(object.is_delete_marker, false)
          and coalesce((object.metadata ->> 'size')::bigint, 0) = artifact.byte_count
     )
  );
end $$;

create or replace function wali.automatic_publication_snapshot(target_submission_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('title',s.proposed_title,'description',s.proposed_description,
 'category',s.primary_category_id,'content_rating',s.content_rating_warning,
 'rights',to_jsonb(r)-array['review_status','reviewed_by','reviewed_at','revision','updated_at','system_publication_decision_id'],
 'tags',coalesce((select jsonb_agg(t.tag_id order by t.tag_id) from wali.submission_tag_suggestions t where t.submission_id=s.id and t.source='creator'),'[]'::jsonb))
 || case s.media_kind when 'still' then jsonb_build_object('media_kind','still') else '{}'::jsonb end
 from wali.submissions s join wali.rights_declarations r on r.submission_id=s.id where s.id=target_submission_id
$$;

create or replace function wali.prepare_publication(
  actor_id uuid, actor_aal text, request_id uuid, idempotency_key text,
  submission_id uuid, expected_revision bigint, expected_generation bigint,
  expected_wallpaper_revision bigint, system_job_id uuid, system_lease_token uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare automatic_job wali.automatic_publication_jobs%rowtype; automatic_decision_id uuid; submission_row wali.submissions%rowtype; wallpaper_row wali.wallpapers%rowtype;
  release_row wali.wallpaper_releases%rowtype; key_row wali.catalog_signing_keys%rowtype;
  rights_row wali.rights_declarations%rowtype; intent wali.publication_intents%rowtype;
  artifact_digest text; metadata_set_digest text; promotion_id uuid; required_roles wali.artifact_role[];
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
  metadata_set_digest := encode(extensions.digest((jsonb_build_object(
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
  ) || case submission_row.media_kind when 'still' then jsonb_build_object('media_kind','still') else '{}'::jsonb end)::text, 'sha256'), 'hex');
  select * into release_row from wali.wallpaper_releases r where r.source_submission_id = submission_row.id for update;
  if not found or release_row.status <> 'approved' then raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_AVAILABLE'; end if;
  if release_row.media_kind is distinct from submission_row.media_kind then raise exception using errcode='P0001',message='WALI_MEDIA_KIND_MISMATCH'; end if;
  required_roles:=case release_row.media_kind when 'still' then array['thumbnail','poster','image_default']::wali.artifact_role[] else array['thumbnail','poster','preview','video_default']::wali.artifact_role[] end;
  if (select count(*) from wali.release_artifacts ra where ra.release_id = release_row.id
      and ra.role=any(required_roles)) <> cardinality(required_roles) then
    if (select count(*) from wali.release_staged_artifacts rsa where rsa.release_id = release_row.id
        and rsa.role=any(required_roles)) <> cardinality(required_roles) then
      raise exception using errcode = 'P0001', message = 'WALI_ARTIFACT_SET_INVALID';
    end if;
    insert into wali.artifact_promotions (release_id) values (release_row.id)
    on conflict (release_id) do update set status = case
      when wali.artifact_promotions.status = 'failed' then 'queued' else wali.artifact_promotions.status end,
      safe_error_code = case when wali.artifact_promotions.status = 'failed' then null else wali.artifact_promotions.safe_error_code end
    returning id into promotion_id;
    if not exists (select 1 from pgmq.q_wali_promotions q where (q.message ->> 'promotion_id')::uuid = promotion_id) then
      perform pgmq.send('wali_promotions', jsonb_build_object(
        'schema_version', case release_row.media_kind when 'still' then 2 else 1 end, 'promotion_id', promotion_id, 'release_id', release_row.id,
        'artifacts', (select jsonb_agg(jsonb_build_object(
          'role', link.role, 'digest', staged.digest, 'byte_count', staged.byte_count,
          'media_type', staged.media_type, 'source_bucket', 'processing-private',
          'source_path', staged.storage_path, 'destination_bucket', 'catalog-public',
          'destination_path', staged.storage_path
        ) order by link.sort_order, link.role)
          from wali.release_staged_artifacts link
          join wali.staged_artifacts staged on staged.digest = link.artifact_digest
          where link.release_id = release_row.id)
      ) || case release_row.media_kind when 'still' then jsonb_build_object('media_kind','still') else '{}'::jsonb end);
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
  ) || case release_row.media_kind when 'still' then jsonb_build_object('media_kind','still') else '{}'::jsonb end;
end $$;

create or replace function wali.finalize_publication(
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
  if release_row.media_kind is distinct from submission_row.media_kind then raise exception using errcode='P0001',message='WALI_MEDIA_KIND_MISMATCH'; end if;
  if release_row.media_kind='still' and (manifest->'schema' is distinct from '{"epoch":2,"revision":0}'::jsonb
    or manifest->>'media_kind' is distinct from 'still'
    or jsonb_typeof(manifest->'artifacts') is distinct from 'array'
    or jsonb_array_length(manifest->'artifacts')<>3
    or (select array_agg(a->>'role' order by a->>'role') from jsonb_array_elements(manifest->'artifacts') a) is distinct from array['image_default','poster','thumbnail']::text[]
    or exists(select 1 from jsonb_array_elements(manifest->'artifacts') a where not exists(
      select 1 from wali.release_artifacts ra join wali.artifacts b on b.digest=ra.artifact_digest
      cross join wali.runtime_configuration cfg where ra.release_id=release_row.id and ra.role::text=a->>'role'
      and b.digest=a->>'sha256' and to_jsonb(b.byte_count)=a->'byte_count' and b.media_type=a->>'media_type'
      and to_jsonb(b.width)=a->'width' and to_jsonb(b.height)=a->'height' and a->'duration_ms'='0'::jsonb
      and a->>'url'=cfg.catalog_public_base_url||'/'||b.storage_path))) then
    raise exception using errcode='P0001',message='WALI_MANIFEST_INVALID';
  end if;
  select * into rights_row from wali.rights_declarations rights where rights.submission_id = submission_row.id for share;
  select * into creator_row from wali.profiles profile where profile.id = submission_row.creator_id for share;
  current_metadata_set_digest := encode(extensions.digest((jsonb_build_object(
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
  ) || case submission_row.media_kind when 'still' then jsonb_build_object('media_kind','still') else '{}'::jsonb end)::text, 'sha256'), 'hex');
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

create or replace function wali.worker_complete_promotion(
  promotion_id uuid, worker_identity text, observed_artifacts jsonb
) returns boolean language plpgsql security definer set search_path = '' as $$
declare job wali.artifact_promotions%rowtype; staged record; observed jsonb; expected_count integer := 0; required_count integer;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if jsonb_typeof(observed_artifacts) <> 'array' or jsonb_array_length(observed_artifacts) not in (3,4) then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_OUTPUT_INVALID';
  end if;
  select * into job from wali.artifact_promotions p where p.id = promotion_id for update;
  if not found then return false; end if;
  select case r.media_kind when 'still' then 3 else 4 end into required_count from wali.wallpaper_releases r where r.id=job.release_id;
  if jsonb_array_length(observed_artifacts)<>required_count or (select count(distinct a->>'role') from jsonb_array_elements(observed_artifacts) a)<>required_count then raise exception using errcode='P0001',message='WALI_WORKER_OUTPUT_INVALID'; end if;
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
  if expected_count <> required_count then raise exception using errcode = 'P0001', message = 'WALI_ARTIFACT_SET_INVALID'; end if;
  update wali.artifact_promotions set status = 'completed', completed_at = statement_timestamp(),
    lease_owner = null, lease_expires_at = null where id = job.id;
  return true;
end $$;

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
       and ra.role=any(case new.media_kind when 'still' then array['thumbnail','poster','image_default']::wali.artifact_role[] else array['thumbnail','poster','preview','video_default']::wali.artifact_role[] end);
    if required_count <> (case new.media_kind when 'still' then 3 else 4 end)
       or (new.media_kind='still' and (select count(*) from wali.release_artifacts where release_id=new.id)<>3) then
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

revoke all on function wali.worker_queue_read_v2(text,integer),wali.worker_begin_still_attempt_v2(uuid,uuid,integer,text,timestamptz),
 wali.worker_authorize_still_artifact_v2(uuid,integer,text,jsonb),wali.worker_complete_still_attempt_v2(uuid,integer,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function wali.worker_queue_read_v2(text,integer),wali.worker_begin_still_attempt_v2(uuid,uuid,integer,text,timestamptz),
 wali.worker_authorize_still_artifact_v2(uuid,integer,text,jsonb),wali.worker_complete_still_attempt_v2(uuid,integer,text,jsonb) to wali_worker;
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
    'media_facts', case when media.digest is null then null when submission.media_kind='still' then jsonb_build_object(
      'media_kind','still','container',media.media_type,'codec',media.codec,'width',media.width,'height',media.height) else jsonb_build_object(
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
    join wali.processing_attempts verified on
      (submission.media_kind='video' and verified.id=staged.verified_by_attempt_id) or
      (submission.media_kind='still' and verified.submission_id=submission.id and verified.generation=target_generation
       and verified.status='completed' and verified.output_summary->>'media_kind'='still'
       and exists(select 1 from jsonb_array_elements(verified.output_summary->'artifacts') claim
        where claim->>'role'=link.role::text and claim->>'digest'=staged.digest))
    where link.release_id = release.id and link.role = case submission.media_kind when 'still' then 'image_default'::wali.artifact_role else 'video_default'::wali.artifact_role end
      and verified.submission_id = submission.id and verified.generation = target_generation limit 1
  ) media on true
  left join lateral (
    select jsonb_agg(jsonb_build_object('role', link.role, 'width', staged.width,
      'height', staged.height) order by link.sort_order, link.role) as items
    from wali.release_staged_artifacts link
    join wali.staged_artifacts staged on staged.digest = link.artifact_digest
    join wali.processing_attempts verified on
      (submission.media_kind='video' and verified.id=staged.verified_by_attempt_id) or
      (submission.media_kind='still' and verified.submission_id=submission.id and verified.generation=target_generation
       and verified.status='completed' and verified.output_summary->>'media_kind'='still'
       and exists(select 1 from jsonb_array_elements(verified.output_summary->'artifacts') claim
        where claim->>'role'=link.role::text and claim->>'digest'=staged.digest))
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
      join wali.processing_attempts verified on
        (page.media_kind='video' and verified.id=staged.verified_by_attempt_id) or
        (page.media_kind='still' and verified.submission_id=page.id and verified.generation=page.generation
         and verified.status='completed' and verified.output_summary->>'media_kind'='still'
         and exists(select 1 from jsonb_array_elements(verified.output_summary->'artifacts') claim
          where claim->>'role'=link.role::text and claim->>'digest'=staged.digest))
      where release.source_submission_id = page.id
        and link.role=any(case page.media_kind when 'still' then array['poster','image_default']::wali.artifact_role[] else array['poster','preview','video_default']::wali.artifact_role[] end)
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
commit;
