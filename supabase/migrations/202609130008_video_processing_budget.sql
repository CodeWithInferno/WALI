-- Bound newly admitted video generations to ninety minutes from first lease.
-- Existing V1 signatures/grants and issued deadlines are unchanged (ADR0028).
begin;

create or replace function wali.worker_queue_read(queue_name text, visibility_seconds integer)
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
    if queue_name = 'wali_media_processing' and queued.message->>'schema_version' = '1'
       and queued.message->'extensions'->>'deadline_policy' in ('first_queue_lease_v1','first_queue_lease_video_90m_v1') then
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
    'extensions', jsonb_build_object('deadline_policy', 'first_queue_lease_video_90m_v1'),
    'deadline_at', to_char(statement_timestamp() + interval '90 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ));
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
 select media_policy_digest into policy_digest from wali.runtime_configuration where singleton;
 if policy_digest is null or policy_digest!~'^[a-f0-9]{64}$' then
  raise exception using errcode='P0001',message='WALI_PROCESSING_CAPACITY_UNAVAILABLE';
 end if;
 update wali.submissions set status='processing',generation=s.generation+1,last_safe_error_code=null
  where id=s.id returning * into s;
 insert into wali.processing_attempts(id,submission_id,generation,status) values(attempt_id,s.id,s.generation,'queued');
 perform pgmq.send('wali_media_processing',jsonb_build_object(
  'schema_version',1,'attempt_id',attempt_id,'submission_id',s.id,'generation',s.generation,
  'input',jsonb_build_object('bucket','uploads-private','path',upload.storage_path,
   'byte_count',upload.received_byte_count,'storage_version',upload.storage_version),
  'policy_digest',policy_digest,'expected_artifact_roles',jsonb_build_array('thumbnail','poster','preview','video_default'),
  'extensions',jsonb_build_object('deadline_policy','first_queue_lease_video_90m_v1'),
  'deadline_at',to_char(statement_timestamp()+interval '90 minutes','YYYY-MM-DD"T"HH24:MI:SS"Z"')
 ));
 result:=jsonb_build_object('submission_id',s.id,'revision',s.revision,'generation',s.generation,'state','processing');
 perform wali.complete_command(actor_id,'retry_processing',idempotency_key,result);
 return result;
end $$;

commit;
