-- Synthetic failed-upload retry; all source, identity and queue state rolls back.
begin;
-- Synthetic effective legal version for this rollback-only fixture.
update wali.runtime_configuration set creator_terms_version='2026-09-12' where singleton;
select plan(30);
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
create temporary table auto_fixture(key text primary key,value jsonb not null);
create function pg_temp.fixture(name text) returns jsonb language sql stable as $$select value from auto_fixture where key=name$$;
update auth.users set email_confirmed_at=statement_timestamp() where id='00000000-0000-0000-0000-000000000003';
select public.wali_edge_accept_creator_terms_v1('00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000003',gen_random_uuid(),'queue_verified_01','2026-09-12');
insert into auto_fixture values('upload1',public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'auto_upload_new_01',4096,'video/mp4','source.mp4','new',null,null));
insert into storage.objects(bucket_id,name,owner_id,version,metadata)
values('uploads-private',pg_temp.fixture('upload1')->>'storage_path','00000000-0000-0000-0000-000000000003','auto-raw-v1','{"size":4096,"mimetype":"video/mp4"}');
insert into auto_fixture values('draft',jsonb_build_object('title','Actual licensed title','description','Actual description before enqueue.',
 'primary_category_id',(select id from wali.categories where slug='nature'),'suggested_tag_ids','[]'::jsonb,
 'content_warning',null,'rights_basis','licensed','rights_holder','Original Test Artist',
 'license_id','20000000-0000-0000-0000-000000000001','source_url','https://example.invalid/original-test-artist',
 'attribution_text','Original Test Artist; licensed with attribution.','proof_object_ids','[]'::jsonb,
 'attests_rights',true,'creator_terms_version','2026-09-12'));
create function pg_temp.complete_auto(draft jsonb,operation_key text) returns jsonb language sql as $$
 select public.wali_edge_complete_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),operation_key,
 (pg_temp.fixture('upload1')->>'upload_session_id')::uuid,1,draft)
$$;
insert into auto_fixture values('complete1',pg_temp.complete_auto(pg_temp.fixture('draft'),'auto_complete_0001'));
insert into auto_fixture values('attempt1',to_jsonb((select id from wali.processing_attempts where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid)));


select has_function('public','wali_edge_retry_processing_v1',array['uuid','uuid','text','uuid','bigint'],'owner processing retry uses constrained service command');
create function pg_temp.retry_processing(operation_key text,expected bigint default null) returns jsonb language sql as $$
 select public.wali_edge_retry_processing_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),operation_key||'_fixture',
 (pg_temp.fixture('complete1')->>'submission_id')::uuid,coalesce(expected,(select revision from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid)))
$$;
select ok(not has_function_privilege('anon','public.wali_edge_retry_processing_v1(uuid,uuid,text,uuid,bigint)','execute') and not has_function_privilege('authenticated','public.wali_edge_retry_processing_v1(uuid,uuid,text,uuid,bigint)','execute'),'users cannot bypass Edge authentication');
select throws_ok($$select pg_temp.retry_processing('retry_active_01')$$,'P0001','WALI_INVALID_TRANSITION','running work cannot be restarted');
select wali.worker_begin_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,(pg_temp.fixture('complete1')->>'submission_id')::uuid,1,'retry-fixture',statement_timestamp()+interval '2 minutes');
select wali.worker_fail_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'retry-fixture','WALI_PROCESSING_TIMEOUT');
insert into auto_fixture values('old_attempt',(select to_jsonb(p) from wali.processing_attempts p where p.id=(pg_temp.fixture('attempt1')#>>'{}')::uuid)),
 ('old_upload',(select to_jsonb(u) from wali.upload_sessions u where u.id=(pg_temp.fixture('upload1')->>'upload_session_id')::uuid)),
 ('old_rights',(select to_jsonb(d) from wali.rights_declarations d where d.submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid)),
 ('old_revision',to_jsonb((select revision from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid))),
 ('old_upload_count',to_jsonb((select count(*) from wali.upload_sessions where creator_id='00000000-0000-0000-0000-000000000003')));
select throws_ok($$select pg_temp.retry_processing('retry_stale_01',1)$$,'P0001','WALI_REVISION_MISMATCH','stale UI cannot initiate a new generation');
update auth.users set email_confirmed_at=null where id='00000000-0000-0000-0000-000000000003';
select throws_ok($$select pg_temp.retry_processing('retry_email_01')$$,'P0001','WALI_VERIFIED_EMAIL_REQUIRED','unverified identity cannot retry');
update auth.users set email_confirmed_at=statement_timestamp() where id='00000000-0000-0000-0000-000000000003';
update wali.runtime_configuration set creator_terms_version='2026-09-13' where singleton;
select throws_ok($$select pg_temp.retry_processing('retry_terms_01')$$,'P0001','WALI_CREATOR_TERMS_REQUIRED','retry requires actual acceptance of current terms');
update wali.runtime_configuration set creator_terms_version='2026-09-12' where singleton;
update auth.users set email_confirmed_at=statement_timestamp() where id='00000000-0000-0000-0000-000000000002';
select public.wali_edge_accept_creator_terms_v1('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002',gen_random_uuid(),'retry_other_terms','2026-09-12');
select throws_ok($$select public.wali_edge_retry_processing_v1('00000000-0000-0000-0000-000000000002',gen_random_uuid(),'retry_other_owner',(pg_temp.fixture('complete1')->>'submission_id')::uuid,(pg_temp.fixture('old_revision')#>>'{}')::bigint)$$,'P0001','WALI_SUBMISSION_NOT_FOUND','another verified creator cannot retry this source');
update storage.objects set version='changed-version' where bucket_id='uploads-private' and name=pg_temp.fixture('upload1')->>'storage_path';
select throws_ok($$select pg_temp.retry_processing('retry_changed_01')$$,'P0001','WALI_UPLOAD_CHANGED','changed source version is rejected');
update storage.objects set version='auto-raw-v1' where bucket_id='uploads-private' and name=pg_temp.fixture('upload1')->>'storage_path';
update storage.objects set is_delete_marker=true where bucket_id='uploads-private' and name=pg_temp.fixture('upload1')->>'storage_path';
select throws_ok($$select pg_temp.retry_processing('retry_missing_01')$$,'P0001','WALI_UPLOAD_CHANGED','deleted source is rejected');
update storage.objects set is_delete_marker=false where bucket_id='uploads-private' and name=pg_temp.fixture('upload1')->>'storage_path';
update storage.objects set metadata='{"size":"invalid","mimetype":"video/mp4"}' where bucket_id='uploads-private' and name=pg_temp.fixture('upload1')->>'storage_path';
select throws_ok($$select pg_temp.retry_processing('retry_bad_metadata')$$,'P0001','WALI_UPLOAD_CHANGED','corrupt source metadata fails with a safe error');
update storage.objects set metadata='{"size":4096,"mimetype":"video/mp4"}' where bucket_id='uploads-private' and name=pg_temp.fixture('upload1')->>'storage_path';
insert into wali.cleanup_object_intents(bucket_id,storage_path,reason) values('uploads-private',pg_temp.fixture('upload1')->>'storage_path','expired_upload');
select throws_ok($$select pg_temp.retry_processing('retry_pending_cleanup')$$,'P0001','WALI_UPLOAD_CHANGED','source queued for deletion cannot be retried');
update wali.cleanup_object_intents set status='failed' where bucket_id='uploads-private' and storage_path=pg_temp.fixture('upload1')->>'storage_path';
insert into auto_fixture values('retried',pg_temp.retry_processing('retry_success_01'));
select is(wali.worker_begin_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,(pg_temp.fixture('complete1')->>'submission_id')::uuid,1,'late-old-worker',statement_timestamp()+interval '2 minutes'),'stale','old worker delivery cannot resume the retired generation');
select is(pg_temp.fixture('retried')->>'state','processing','failed source starts processing again');
select is((pg_temp.fixture('retried')->>'generation')::integer,2,'retry creates a new generation');
select is((pg_temp.fixture('retried')->>'revision')::bigint,(pg_temp.fixture('old_revision')#>>'{}')::bigint+1,'retry advances the owner revision exactly once');
select is(pg_temp.retry_processing('retry_success_01',(pg_temp.fixture('old_revision')#>>'{}')::bigint)-'replayed',pg_temp.fixture('retried'),'lost HTTP response replays without another generation');
select is(pg_temp.retry_processing('retry_success_01',(pg_temp.fixture('old_revision')#>>'{}')::bigint)->>'replayed','true','replay carries the existing command replay marker');
select throws_ok($$select pg_temp.retry_processing('retry_success_01')$$,'P0001','WALI_IDEMPOTENCY_CONFLICT','same key cannot change the requested revision');
select is((select to_jsonb(p) from wali.processing_attempts p where p.id=(pg_temp.fixture('attempt1')#>>'{}')::uuid),pg_temp.fixture('old_attempt'),'original terminal attempt and deadline remain untouched');
select is((select to_jsonb(u) from wali.upload_sessions u where u.id=(pg_temp.fixture('upload1')->>'upload_session_id')::uuid),pg_temp.fixture('old_upload'),'upload binding and retention clock remain unchanged');
select is((select to_jsonb(d) from wali.rights_declarations d where d.submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),pg_temp.fixture('old_rights'),'rights, license, attribution and attestation are unchanged');
select is((select count(*) from wali.upload_sessions where creator_id='00000000-0000-0000-0000-000000000003'),(pg_temp.fixture('old_upload_count')#>>'{}')::bigint,'retry consumes no new daily upload reservation');
select is((select count(*) from wali.processing_attempts where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),2::bigint,'exactly one new attempt is durable');
select is((select message->'input' from pgmq.q_wali_media_processing where message->>'submission_id'=pg_temp.fixture('complete1')->>'submission_id' and message->>'generation'='2'),(select message->'input' from pgmq.q_wali_media_processing where message->>'attempt_id'=pg_temp.fixture('attempt1')#>>'{}'),'new generation reads the identical immutable source binding');
select is((select message->'extensions'->>'deadline_policy' from pgmq.q_wali_media_processing where message->>'submission_id'=pg_temp.fixture('complete1')->>'submission_id' and message->>'generation'='2'),'first_queue_lease_video_90m_v1','retry receives only the new bounded first-lease policy');
-- Release the synthetic retry, then exercise the existing two-job backpressure.
select wali.worker_begin_attempt((select id from wali.processing_attempts where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid and generation=2),(pg_temp.fixture('complete1')->>'submission_id')::uuid,2,'retry-fixture',statement_timestamp()+interval '2 minutes');
select wali.worker_fail_attempt((select id from wali.processing_attempts where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid and generation=2),2,'retry-fixture','WALI_PROCESSING_TIMEOUT');
create function pg_temp.processing_slot(operation_key text) returns void language plpgsql as $$declare u jsonb;begin
 u:=public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),operation_key,4096,'video/mp4','source.mp4','new',null,null);
 insert into storage.objects(bucket_id,name,owner_id,version,metadata) values('uploads-private',u->>'storage_path','00000000-0000-0000-0000-000000000003','slot-v1','{"size":4096,"mimetype":"video/mp4"}');
 perform public.wali_edge_complete_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),operation_key||'_complete',(u->>'upload_session_id')::uuid,1,pg_temp.fixture('draft'));
end;$$;
select pg_temp.processing_slot('retry_capacity_slot1'); select pg_temp.processing_slot('retry_capacity_slot2');
select throws_ok($$select pg_temp.retry_processing('retry_capacity_01')$$,'P0001','WALI_PROCESSING_CAPACITY_UNAVAILABLE','two concurrent processing jobs remain the limit');
select is((select count(*) from wali.processing_attempts where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),2::bigint,'refused capacity does not consume an attempt');
-- The retry cap is independent of whether capacity is currently available.
insert into wali.processing_attempts(submission_id,generation,status,finished_at) select (pg_temp.fixture('complete1')->>'submission_id')::uuid,g,'failed',statement_timestamp() from generate_series(3,5) g;
update wali.submissions set generation=5 where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid;
select throws_ok($$select pg_temp.retry_processing('retry_limit_01')$$,'P0001','WALI_PROCESSING_RETRY_LIMIT_REACHED','five total generations cannot be exceeded');
select is((select max_attempts from wali.queue_policies where queue_name='wali_media_processing'),5,'existing processing retry policy is unchanged');
select ok((select (message->>'deadline_at')::timestamptz between statement_timestamp()+interval '5395 seconds' and statement_timestamp()+interval '5400 seconds' from pgmq.q_wali_media_processing where message->>'submission_id'=pg_temp.fixture('complete1')->>'submission_id' and message->>'generation'='2'),'new retry carries a ninety-minute fallback without modifying the old attempt');
select * from finish(); rollback;
