-- Preserve the existing 1200-second execution budget while excluding queue
-- waiting for newly admitted jobs only. Existing issued payloads are unchanged.
begin;

alter table wali.processing_attempts add column execution_deadline_at timestamptz;

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
       and queued.message->'extensions'->>'deadline_policy' = 'first_queue_lease_v1' then
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
            coalesce(p.started_at,statement_timestamp())+interval '20 minutes'
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

-- New admissions alone opt in. The existing enqueue-based deadline remains a
-- conservative fallback if this reader is rolled back; it is never rewritten
-- in stored queue messages or retroactively added to previously issued jobs.
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
    'extensions', jsonb_build_object('deadline_policy', 'first_queue_lease_v1'),
    'deadline_at', to_char(statement_timestamp() + interval '20 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ));
  replay := jsonb_build_object(
    'submission_id', submission_id, 'revision', (select s.revision from wali.submissions s where s.id=submission_id), 'generation', 1, 'state', 'processing',
    'processing_status_key', submission_id::text || ':1'
  );
  perform wali.complete_command(actor_id, operation, idempotency_key, replay);
  return replay;
end $$;

-- Failure writes use the same current, unexpired lease authority as completion.
-- This lets a bounded control-plane context record timeout after media context
-- expiry without permitting a stale worker to change terminal state.
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
     and lease_expires_at > statement_timestamp()
     and status in ('leased', 'downloading', 'transcoding', 'verifying', 'classifying')
  returning submission_id into affected_submission;
  if affected_submission is null then return false; end if;
  update wali.submissions set status = 'processing_failed', last_safe_error_code = safe_error_code
   where id = affected_submission and generation = expected_generation;
  return true;
end $$;

commit;
