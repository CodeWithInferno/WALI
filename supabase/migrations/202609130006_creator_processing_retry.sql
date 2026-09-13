-- ADR 0025 recovery: an owner retries retained verified-admission source bytes.
-- No upload reservation, new rights attestation, or old attempt extension occurs.
begin;
create function public.wali_edge_retry_processing_v1(
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
  'extensions',jsonb_build_object('deadline_policy','first_queue_lease_v1'),
  'deadline_at',to_char(statement_timestamp()+interval '20 minutes','YYYY-MM-DD"T"HH24:MI:SS"Z"')
 ));
 result:=jsonb_build_object('submission_id',s.id,'revision',s.revision,'generation',s.generation,'state','processing');
 perform wali.complete_command(actor_id,'retry_processing',idempotency_key,result);
 return result;
end $$;
revoke all on function public.wali_edge_retry_processing_v1(uuid,uuid,text,uuid,bigint) from public,anon,authenticated;
grant execute on function public.wali_edge_retry_processing_v1(uuid,uuid,text,uuid,bigint) to service_role;
commit;
