-- Synthetic queue timing only. All rows and queue operations roll back.
begin;
select plan(24);
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

create temporary table deadline_fixture as select msg_id,message from pgmq.q_wali_media_processing where message->>'attempt_id'=pg_temp.fixture('attempt1')#>>'{}';
select is((select message->'extensions'->>'deadline_policy' from deadline_fixture),'first_queue_lease_video_90m_v1','newly admitted upload requests the fixed first-lease deadline policy');
-- Emulate twenty-five minutes of waiting without sleeping or changing live jobs.
update pgmq.q_wali_media_processing set enqueued_at=statement_timestamp()-interval '25 minutes',
 message=jsonb_set(message,'{deadline_at}',to_jsonb(to_char(statement_timestamp()-interval '5 minutes','YYYY-MM-DD"T"HH24:MI:SS"Z"')))
 where msg_id=(select msg_id from deadline_fixture);
create temporary table first_read as select * from wali.worker_queue_read('wali_media_processing',300);
select ok((select (message->>'deadline_at')::timestamptz between statement_timestamp()+interval '5395 seconds' and statement_timestamp()+interval '5400 seconds' from first_read),'queue delay does not consume the first execution budget');
select ok((select vt between statement_timestamp()+interval '295 seconds' and statement_timestamp()+interval '300 seconds' from first_read),'queue visibility remains independently bounded to five minutes');
select is(wali.worker_begin_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,(pg_temp.fixture('complete1')->>'submission_id')::uuid,1,'queue-deadline-worker',(select vt from first_read)),'started','original lease and generation checks still admit current work');
select pgmq.set_vt('wali_media_processing',(select msg_id from deadline_fixture),0);
create temporary table second_read as select * from wali.worker_queue_read('wali_media_processing',300);
select is((select message->>'deadline_at' from second_read),(select message->>'deadline_at' from first_read),'redelivery reuses the first fixed deadline');
select ok(wali.worker_heartbeat_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'queue-deadline-worker',statement_timestamp()+interval '2 minutes'),'normal heartbeat remains valid');
select pgmq.set_vt('wali_media_processing',(select msg_id from deadline_fixture),0);
select is((select message->>'deadline_at' from wali.worker_queue_read('wali_media_processing',300)),(select message->>'deadline_at' from first_read),'heartbeat cannot reset the execution budget');
-- Synthetic already-expired deadline: shorten the fixture only, never extend it.
do $$begin if exists(select 1 from information_schema.columns where table_schema='wali' and table_name='processing_attempts' and column_name='execution_deadline_at') then
 execute 'update wali.processing_attempts set execution_deadline_at=statement_timestamp()-interval ''1 minute'' where id=$1' using (pg_temp.fixture('attempt1')#>>'{}')::uuid;
end if;end $$;
select pgmq.set_vt('wali_media_processing',(select msg_id from deadline_fixture),0);
select ok((select (message->>'deadline_at')::timestamptz < statement_timestamp() from wali.worker_queue_read('wali_media_processing',300)),'expired fixed deadlines are never extended by retry');
select pgmq.delete('wali_media_processing',(select msg_id from deadline_fixture));
-- Legacy messages remain identical even if their deadline is already expired.
insert into auto_fixture values('legacy',jsonb_set((select message from deadline_fixture)-'extensions','{deadline_at}',to_jsonb('2000-01-01T00:00:00Z'::text)));
select pgmq.send('wali_media_processing',pg_temp.fixture('legacy'));
create temporary table legacy_read as select * from wali.worker_queue_read('wali_media_processing',300);
select is((select message from legacy_read),pg_temp.fixture('legacy'),'unmarked issued jobs retain their exact original deadline and body');
select pgmq.delete('wali_media_processing',(select msg_id from legacy_read));
-- Invalid IDs cannot cause a cast exception or grant another attempt a budget.
insert into auto_fixture values('malformed',jsonb_set((select message from deadline_fixture),'{attempt_id}','"not-a-uuid"'));
select pgmq.send('wali_media_processing',pg_temp.fixture('malformed'));
create temporary table malformed_read as select * from wali.worker_queue_read('wali_media_processing',300);
select is((select message from malformed_read),pg_temp.fixture('malformed'),'malformed envelopes remain for the existing decoder/rejection path');
select pgmq.delete('wali_media_processing',(select msg_id from malformed_read));
insert into auto_fixture values('stale',jsonb_set((select message from deadline_fixture),'{generation}','999'));
select pgmq.send('wali_media_processing',pg_temp.fixture('stale'));
create temporary table stale_read as select * from wali.worker_queue_read('wali_media_processing',300);
select is((select message from stale_read),pg_temp.fixture('stale'),'stale generations cannot rebase the current attempt');
select pgmq.delete('wali_media_processing',(select msg_id from stale_read));
-- Synthetic old first-lease marker remains twenty minutes, even on the new reader.
update wali.processing_attempts set execution_deadline_at=null,started_at=null
 where id=(pg_temp.fixture('attempt1')#>>'{}')::uuid;
select pgmq.send('wali_media_processing',jsonb_set((select message from deadline_fixture),'{extensions,deadline_policy}','"first_queue_lease_v1"'));
create temporary table old_policy_read as select * from wali.worker_queue_read('wali_media_processing',300);
select ok((select (message->>'deadline_at')::timestamptz between statement_timestamp()+interval '1195 seconds' and statement_timestamp()+interval '1200 seconds' from old_policy_read),'previously issued twenty-minute policy is not expanded');
select pgmq.set_vt('wali_media_processing',(select msg_id from old_policy_read),0);
select is((select message->>'deadline_at' from wali.worker_queue_read('wali_media_processing',300)),(select message->>'deadline_at' from old_policy_read),'old policy redelivery keeps its frozen deadline');
select pgmq.delete('wali_media_processing',(select msg_id from old_policy_read));
-- Simulate an opted-in message begun while an older reader was deployed:
-- its original durable start time is retained, not replaced by this read.
update wali.processing_attempts set execution_deadline_at=null, started_at=statement_timestamp()-interval '10 minutes'
 where id=(pg_temp.fixture('attempt1')#>>'{}')::uuid;
select pgmq.send('wali_media_processing',(select message from deadline_fixture));
create temporary table prior_begin_read as select * from wali.worker_queue_read('wali_media_processing',300);
select ok((select (message->>'deadline_at')::timestamptz between statement_timestamp()+interval '4795 seconds' and statement_timestamp()+interval '4800 seconds' from prior_begin_read),'prior Begin retains its original elapsed execution budget');
select is((select execution_deadline_at-started_at from wali.processing_attempts where id=(pg_temp.fixture('attempt1')#>>'{}')::uuid),interval '90 minutes','new opted-in video has exactly5400 seconds');
select pgmq.delete('wali_media_processing',(select msg_id from prior_begin_read));
select pgmq.send('wali_cleanup',pg_temp.fixture('malformed'));
select is((select message from wali.worker_queue_read('wali_cleanup',300)),pg_temp.fixture('malformed'),'other queue contracts are unchanged');
select throws_ok($$select wali.worker_queue_read('wali_media_processing',1801)$$,'P0001','WALI_QUEUE_NOT_ALLOWED','queue visibility cannot exceed existing maximum');
select ok(not has_function_privilege('anon','wali.worker_queue_read(text,integer)','execute') and not has_function_privilege('authenticated','wali.worker_queue_read(text,integer)','execute'),'user roles still cannot lease worker queues');
-- Terminal timeout writes require the existing exact owner/generation and a
-- still-valid lease. No fencing token exists in this established contract.
select is(wali.worker_fail_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,2,'queue-deadline-worker','WALI_PROCESSING_TIMEOUT'),false,'wrong generation cannot record timeout');
select is(wali.worker_fail_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'different-worker','WALI_PROCESSING_TIMEOUT'),false,'wrong worker cannot record timeout');
update wali.processing_attempts set lease_expires_at=statement_timestamp()-interval '1 second' where id=(pg_temp.fixture('attempt1')#>>'{}')::uuid;
select is(wali.worker_fail_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'queue-deadline-worker','WALI_PROCESSING_TIMEOUT'),false,'expired lease cannot record timeout');
select is((select status::text from wali.processing_attempts where id=(pg_temp.fixture('attempt1')#>>'{}')::uuid),'leased','lost lease failure leaves durable state unchanged');
update wali.processing_attempts set lease_expires_at=statement_timestamp()+interval '2 minutes' where id=(pg_temp.fixture('attempt1')#>>'{}')::uuid;
select ok(wali.worker_fail_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'queue-deadline-worker','WALI_PROCESSING_TIMEOUT'),'current owner records one terminal timeout');
select is((select status::text from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),'processing_failed','terminal timeout becomes visible without waiting for stale sweep');
select * from finish();
rollback;
