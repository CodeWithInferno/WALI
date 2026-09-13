begin;
-- Match the restricted-role fixture used by tests020/022; rolled back below.
grant wali_worker to postgres with set true;
set local search_path=public,extensions;
select no_plan();
select has_table('wali','account_deletion_finalization_jobs','automatic authority has its own private job');
select has_function('public','wali_edge_request_account_deletion_v2',array['uuid','text','uuid','text','bigint','text','text'],'versioned consent admission');
select ok(not(select automatic_account_deletion_enabled from wali.runtime_configuration),'migration does not activate deletion');
update wali.runtime_configuration set automatic_account_deletion_enabled=true;
create temporary table deletion_test_values(name text primary key,value jsonb);
grant all on deletion_test_values to service_role,wali_worker;
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select throws_ok($$select * from wali.account_deletion_finalization_jobs$$,'42501',null,'client cannot read job authority');
select throws_ok($$select public.wali_edge_begin_account_deletion_dispatch_v1()$$,'42501',null,'user cannot invoke scheduler RPC');
reset role;
select set_config('request.jwt.claim.role','service_role',true);
insert into deletion_test_values values('request',public.wali_edge_request_account_deletion_v2(
 '00000000-0000-0000-0000-000000000003','aal2','97000000-0000-4000-8000-000000000001','automatic_deletion_test_01',
 (select revision from wali.profiles where id='00000000-0000-0000-0000-000000000003'),repeat('1',64),'2026-09-13'));
select is((select status::text from wali.profiles where id='00000000-0000-0000-0000-000000000003'),'deletion_pending','acceptance freezes account');
select ok((select status_expires_at is null from wali.account_deletion_status_receipts),'pending status has no premature expiry');
select throws_ok($$select public.wali_edge_request_account_deletion_v2('00000000-0000-0000-0000-000000000003','aal2','97000000-0000-4000-8000-000000000001','automatic_deletion_test_01',1,repeat('2',64),'2026-09-13')$$,
 'P0001','WALI_IDEMPOTENCY_CONFLICT','same command cannot replace capability');
insert into deletion_test_values values('run',public.wali_edge_begin_account_deletion_dispatch_v1());
select is(public.wali_edge_begin_account_deletion_dispatch_v1()->'run_token','null'::jsonb,'parallel dispatch is denied');
select is(public.wali_edge_claim_account_deletion_v1((select (value->>'run_token')::uuid from deletion_test_values where name='run'))->'job','null'::jsonb,'cleanup is not identity deletion');
select ok((select sessions_revoked_at is not null from wali.account_deletion_requests where user_id='00000000-0000-0000-0000-000000000003'),'lost acceptance response reconciles session revocation');
select is(public.wali_edge_account_deletion_receipt_v1(repeat('1',64))->>'stage','cleanup','signed-out receipt shows truthful cleanup');
select is(public.wali_edge_account_deletion_receipt_v1(repeat('0',64)),null::jsonb,'unknown receipt reveals nothing');
-- Existing worker performs local-data cleanup, without an Auth admin privilege.
select set_config('request.jwt.claim.role','wali_worker',true);
set local role wali_worker;
insert into deletion_test_values values('worker_begin',wali.worker_begin_account_deletion((select (value->>'deletion_id')::uuid from deletion_test_values where name='request'),
 '00000000-0000-0000-0000-000000000003','worker-deletion-fixture',statement_timestamp()+interval '1 minute'));
insert into deletion_test_values values('worker_complete',to_jsonb(wali.worker_complete_account_deletion((select (value->>'deletion_id')::uuid from deletion_test_values where name='request'),
 '00000000-0000-0000-0000-000000000003','worker-deletion-fixture')));
reset role;
select is((select value->>'disposition' from deletion_test_values where name='worker_begin'),'ready','real worker may perform cleanup');
select is((select value from deletion_test_values where name='worker_complete'),'true'::jsonb,'cleanup completes separately');
select ok(not has_function_privilege('wali_worker','public.wali_edge_begin_account_deletion_dispatch_v1()','EXECUTE'),'media worker has no finalization authority');
select set_config('request.jwt.claim.role','service_role',true);
insert into deletion_test_values values('claim',public.wali_edge_claim_account_deletion_v1((select (value->>'run_token')::uuid from deletion_test_values where name='run')));
select ok((select value->'job' is distinct from 'null'::jsonb from deletion_test_values where name='claim'),'eligible consent can be claimed');
select is(public.wali_edge_claim_account_deletion_v1((select (value->>'run_token')::uuid from deletion_test_values where name='run'))->'job','null'::jsonb,'same live receipt cannot be claimed twice');
select throws_ok($$select public.wali_edge_prepare_automatic_account_deletion_v1(
 (select (value->>'run_token')::uuid from deletion_test_values where name='run'),(select (value->'job'->>'job_id')::uuid from deletion_test_values where name='claim'),
 '97000000-0000-4000-8000-000000000099',(select (value->'job'->>'revision')::bigint from deletion_test_values where name='claim'))$$,'P0001','WALI_DELETION_LEASE_INVALID','wrong lease cannot expose identity');
-- A request's statement clock predates any wait in a called function. Expire
-- the real persisted lease inside this statement, then exercise the boundary.
create function pg_temp.deletion_after_lease_expiry(target text) returns void language plpgsql as $$
begin
 if target in('run','claim') then
  update wali.account_deletion_dispatch_state set lease_expires_at=clock_timestamp()+interval '25 milliseconds';
 else
  update wali.account_deletion_finalization_jobs set lease_expires_at=clock_timestamp()+interval '25 milliseconds'
   where id=(select (value->'job'->>'job_id')::uuid from deletion_test_values where name='claim');
 end if;
 perform pg_sleep(0.05);
 if target='claim' then
  perform public.wali_edge_claim_account_deletion_v1((select (value->>'run_token')::uuid from deletion_test_values where name='run'));
 else
  perform public.wali_edge_prepare_automatic_account_deletion_v1(
   (select (value->>'run_token')::uuid from deletion_test_values where name='run'),
   (select (value->'job'->>'job_id')::uuid from deletion_test_values where name='claim'),
   (select (value->'job'->>'lease_token')::uuid from deletion_test_values where name='claim'),
   (select (value->'job'->>'revision')::bigint from deletion_test_values where name='claim'));
 end if;
end $$;
savepoint before_expired_lease_tests;
select throws_ok($$select pg_temp.deletion_after_lease_expiry('run')$$,'P0001','WALI_DELETION_LEASE_INVALID','elapsed run lease cannot expose identity despite an earlier statement clock');
rollback to savepoint before_expired_lease_tests;
select throws_ok($$select pg_temp.deletion_after_lease_expiry('job')$$,'P0001','WALI_DELETION_LEASE_INVALID','elapsed job lease cannot expose identity despite an earlier statement clock');
rollback to savepoint before_expired_lease_tests;
select throws_ok($$select pg_temp.deletion_after_lease_expiry('claim')$$,'P0001','WALI_DELETION_LEASE_INVALID','expired dispatch cannot claim more work inside its original statement');
rollback to savepoint before_expired_lease_tests;
insert into deletion_test_values values('prepare',public.wali_edge_prepare_automatic_account_deletion_v1(
 (select (value->>'run_token')::uuid from deletion_test_values where name='run'),(select (value->'job'->>'job_id')::uuid from deletion_test_values where name='claim'),
 (select (value->'job'->>'lease_token')::uuid from deletion_test_values where name='claim'),(select (value->'job'->>'revision')::bigint from deletion_test_values where name='claim')));
select is((select value->>'user_id' from deletion_test_values where name='prepare'),'00000000-0000-0000-0000-000000000003','identity is derived from consented request');
select is((select value->'apple_authorizations' from deletion_test_values where name='prepare'),'[]'::jsonb,'email-only account needs no Apple configuration');
select throws_ok($$select public.wali_edge_prepare_account_identity_deletion_v1('00000000-0000-0000-0000-000000000001','aal2',
 (select (value->>'deletion_id')::uuid from deletion_test_values where name='request'),(select revision from wali.account_deletion_requests where user_id='00000000-0000-0000-0000-000000000003'))$$,
 'P0001','WALI_DELETION_AUTOMATIC_RECOVERY_REQUIRED','manual adapter cannot bypass automatic checkpoints');
insert into deletion_test_values values('identity',public.wali_edge_authorize_account_identity_deletion_v1(
 (select (value->>'run_token')::uuid from deletion_test_values where name='run'),(select (value->'job'->>'job_id')::uuid from deletion_test_values where name='claim'),
 (select (value->'job'->>'lease_token')::uuid from deletion_test_values where name='claim'),(select (value->>'revision')::bigint from deletion_test_values where name='prepare')));
select is(public.wali_edge_account_deletion_receipt_v1(repeat('1',64))->>'stage','identity_deletion','provider authorization is not completion');
insert into deletion_test_values values('finish',public.wali_edge_finalize_automatic_account_deletion_v1(
 (select (value->>'run_token')::uuid from deletion_test_values where name='run'),(select (value->'job'->>'job_id')::uuid from deletion_test_values where name='claim'),
 (select (value->'job'->>'lease_token')::uuid from deletion_test_values where name='claim'),(select (value->>'revision')::bigint from deletion_test_values where name='identity')));
select is(public.wali_edge_account_deletion_receipt_v1(repeat('1',64))->>'status','completed','only final checkpoint yields completed');
select is((select r.status_expires_at-j.completed_at from wali.account_deletion_status_receipts r join wali.account_deletion_finalization_jobs j on j.id=r.job_id),interval '30 days','completion starts exact30-day window atomically');
insert into deletion_test_values values('expiry',to_jsonb((select status_expires_at from wali.account_deletion_status_receipts)));
select lives_ok($$select public.wali_edge_finalize_automatic_account_deletion_v1(
 (select (value->>'run_token')::uuid from deletion_test_values where name='run'),(select (value->'job'->>'job_id')::uuid from deletion_test_values where name='claim'),
 (select (value->'job'->>'lease_token')::uuid from deletion_test_values where name='claim'),(select (value->>'revision')::bigint from deletion_test_values where name='finish'))$$,'completed reconciliation is idempotent');
select is(to_jsonb((select status_expires_at from wali.account_deletion_status_receipts)),(select value from deletion_test_values where name='expiry'),'replay does not extend receipt');
update wali.account_deletion_status_receipts set status_expires_at=statement_timestamp()-interval '1 second';
select is(public.wali_edge_account_deletion_receipt_v1(repeat('1',64)),null::jsonb,'expired receipt loses access');
select is(wali.purge_expired_deletion_receipts(statement_timestamp()),1,'bounded purge removes only expired capabilities');
select is((select count(*) from wali.account_deletion_finalization_jobs),1::bigint,'receipt purge is separate from minimum audit');
-- Apple replacement and deletion share the actor lock. A live exchange must
-- finish/expire before finalizer preparation can expose stored token material.
insert into auth.identities(id,user_id,provider,provider_id,identity_data)
 values(gen_random_uuid(),'00000000-0000-0000-0000-000000000004','apple','deletion-apple-fixture','{"sub":"deletion-apple-fixture"}');
insert into wali.apple_authorizations(actor_id,client_id,apple_subject,encrypted_refresh_token,encryption_key_version,code_sha256,
 pending_code_sha256,binding_lease_token,binding_lease_expires_at)
 values('00000000-0000-0000-0000-000000000004','com.wali.store.WALI','deletion-apple-fixture','v1.'||repeat('a',16)||'.'||repeat('b',48),'local-v1',repeat('3',64),
 repeat('4',64),gen_random_uuid(),statement_timestamp()+interval '90 seconds');
insert into wali.apple_authorizations(actor_id,client_id,apple_subject)
 values('00000000-0000-0000-0000-000000000004','com.wali.store.development.WALI','deletion-apple-fixture');
insert into deletion_test_values values('apple_request',public.wali_edge_request_account_deletion_v2('00000000-0000-0000-0000-000000000004','aal2',
 '97000000-0000-4000-8000-000000000004','apple_deletion_test_01',(select revision from wali.profiles where id='00000000-0000-0000-0000-000000000004'),repeat('4',64),'2026-09-13'));
select public.wali_edge_mark_account_deletion_sessions_revoked_v1('00000000-0000-0000-0000-000000000004',
 (select (value->>'deletion_id')::uuid from deletion_test_values where name='apple_request'),'97000000-0000-4000-8000-000000000004');
select wali.worker_begin_account_deletion((select (value->>'deletion_id')::uuid from deletion_test_values where name='apple_request'),
 '00000000-0000-0000-0000-000000000004','worker-apple-fixture',statement_timestamp()+interval '1 minute');
select wali.worker_complete_account_deletion((select (value->>'deletion_id')::uuid from deletion_test_values where name='apple_request'),
 '00000000-0000-0000-0000-000000000004','worker-apple-fixture');
insert into deletion_test_values values('apple_claim',public.wali_edge_claim_account_deletion_v1((select (value->>'run_token')::uuid from deletion_test_values where name='run')));
create function pg_temp.apple_prepare() returns jsonb language sql as $$select public.wali_edge_prepare_automatic_account_deletion_v1(
 (select (value->>'run_token')::uuid from deletion_test_values where name='run'),
 (select (value->'job'->>'job_id')::uuid from deletion_test_values where name='apple_claim'),
 (select (value->'job'->>'lease_token')::uuid from deletion_test_values where name='apple_claim'),
 (select revision from wali.account_deletion_finalization_jobs where deletion_id=(select (value->>'deletion_id')::uuid from deletion_test_values where name='apple_request')))$$;
select throws_ok($$select pg_temp.apple_prepare()$$,'P0001','WALI_DELETION_NOT_READY','live Apple exchange blocks finalization');
update wali.apple_authorizations set binding_lease_expires_at=statement_timestamp()-interval '1 second' where actor_id='00000000-0000-0000-0000-000000000004' and binding_lease_expires_at is not null;
insert into deletion_test_values values('apple_prepare',pg_temp.apple_prepare());
select is(jsonb_array_length((select value->'apple_authorizations' from deletion_test_values where name='apple_prepare')),1,'only retained encrypted binding is sent for revocation');
select ok((select apple_action_required from wali.account_deletion_finalization_jobs where deletion_id=(select (value->>'deletion_id')::uuid from deletion_test_values where name='apple_request')),'missing per-client token uses explicit legacy fallback');
select throws_ok($$select public.wali_edge_authorize_account_identity_deletion_v1(
 (select (value->>'run_token')::uuid from deletion_test_values where name='run'),(select (value->'job'->>'job_id')::uuid from deletion_test_values where name='apple_claim'),
 (select (value->'job'->>'lease_token')::uuid from deletion_test_values where name='apple_claim'),(select (value->>'revision')::bigint from deletion_test_values where name='apple_prepare'))$$,
 'P0001','WALI_DELETION_NOT_READY','identity cannot precede required Apple revocation');
select public.wali_edge_checkpoint_account_apple_revocation_v1(
 (select (value->>'run_token')::uuid from deletion_test_values where name='run'),(select (value->'job'->>'job_id')::uuid from deletion_test_values where name='apple_claim'),
 (select (value->'job'->>'lease_token')::uuid from deletion_test_values where name='apple_claim'),(select (value->>'revision')::bigint from deletion_test_values where name='apple_prepare'),'com.wali.store.WALI',1);
select is((select count(*) from wali.apple_authorizations where actor_id='00000000-0000-0000-0000-000000000004' and encrypted_refresh_token is not null),0::bigint,'confirmed revocation purges only the bound credential');
select is(jsonb_array_length(pg_temp.apple_prepare()->'apple_authorizations'),0,'lost checkpoint reply reconciles without a replacement identity');
update wali.account_deletion_requests set requested_at=statement_timestamp()-interval '90 days' where user_id='00000000-0000-0000-0000-000000000004';
select ok(public.wali_edge_account_deletion_receipt_v1(repeat('4',64)) is not null,'ninety-day unfinished request retains status access');
select ok(public.wali_edge_account_deletion_receipt_v1(repeat('4',64))->'status_expires_at'='null'::jsonb,'unfinished operations do not start completion expiry');

-- Real Storage RLS, exact-object grant and immutable publication races.
insert into wali.upload_sessions select x.* from wali.upload_sessions u cross join lateral jsonb_populate_record(null::wali.upload_sessions,
 to_jsonb(u)||jsonb_build_object('id','97000000-0000-4000-8000-000000000010','storage_path','00000000-0000-0000-0000-000000000006/97000000-0000-4000-8000-000000000010/source',
 'idempotency_key','97000000-0000-4000-8000-000000000010')) x where u.id='70000000-0000-0000-0000-000000000002';
insert into wali.submissions select x.* from wali.submissions s cross join lateral jsonb_populate_record(null::wali.submissions,
 to_jsonb(s)||jsonb_build_object('id','97000000-0000-4000-8000-000000000011','upload_session_id','97000000-0000-4000-8000-000000000010','status','draft')) x where s.id='71000000-0000-0000-0000-000000000002';
insert into wali.wallpaper_releases(id,wallpaper_id,edition,source_submission_id,status) values('97000000-0000-4000-8000-000000000012',
 '30000000-0000-0000-0000-000000000002',2,'97000000-0000-4000-8000-000000000011','processing');
insert into wali.release_artifacts(release_id,role,artifact_digest,sort_order) values('97000000-0000-4000-8000-000000000012','thumbnail',repeat('1',64),10);
insert into storage.objects(bucket_id,name,metadata) select storage_bucket,storage_path,'{"size":1024}'::jsonb from wali.artifacts where digest=repeat('2',64) on conflict(bucket_id,name) do nothing;
insert into deletion_test_values values('creator_request',public.wali_edge_request_account_deletion_v2('00000000-0000-0000-0000-000000000002','aal2',
 '97000000-0000-4000-8000-000000000002','creator_deletion_test_01',(select revision from wali.profiles where id='00000000-0000-0000-0000-000000000002'),repeat('2',64),'2026-09-13'));
select public.wali_edge_mark_account_deletion_sessions_revoked_v1('00000000-0000-0000-0000-000000000002',
 (select (value->>'deletion_id')::uuid from deletion_test_values where name='creator_request'),'97000000-0000-4000-8000-000000000002');
select ok(not wali.prepare_account_object_cleanup((select (value->>'deletion_id')::uuid from deletion_test_values where name='creator_request'),
 '00000000-0000-0000-0000-000000000002'),'present public bytes require a cleanup intent');
select is((select count(*) from wali.account_deletion_object_intents where deletion_id=(select (value->>'deletion_id')::uuid from deletion_test_values where name='creator_request')),4::bigint,'all published artifact roles receive durable fences');
select is((select disposition from wali.account_deletion_object_intents where digest=repeat('1',64)),'shared_reference','reference admitted first prevents removal of another publisher bytes');
select ok((select cleanup_id is null from wali.account_deletion_object_intents where digest=repeat('1',64)),'shared reference grants no delete authority');
select throws_ok($$insert into wali.release_artifacts(release_id,role,artifact_digest,sort_order) values('97000000-0000-4000-8000-000000000012','poster',repeat('2',64),20)$$,
 'P0001','WALI_ARTIFACT_DELETION_FENCED','deletion admitted first rejects a new reference');
insert into deletion_test_values values('public_cleanup',to_jsonb((select cleanup_id from wali.account_deletion_object_intents where digest=repeat('2',64))));
select is(wali.worker_begin_cleanup((select (value#>>'{}')::uuid from deletion_test_values where name='public_cleanup'),'public-cleanup-fixture',statement_timestamp()+interval '1 minute')->>'disposition','started','worker obtains the exact public-object lease');
-- Simulate the Storage API transaction; keep its delete guard and worker RLS enabled.
set local storage.allow_delete_query = 'true';
select set_config('request.jwt.claims','{"role":"wali_storage_worker","worker_id":"wrong-worker"}',true);
set local role wali_storage_worker;
delete from storage.objects where bucket_id='catalog-public' and name='sha256/22/22/'||repeat('2',64)||'/poster.jpg';
reset role;
select is((select count(*) from storage.objects where bucket_id='catalog-public' and name='sha256/22/22/'||repeat('2',64)||'/poster.jpg'),1::bigint,'wrong worker cannot delete public bytes');
select set_config('request.jwt.claims','{"role":"wali_storage_worker","worker_id":"public-cleanup-fixture"}',true);
set local role wali_storage_worker;
delete from storage.objects where bucket_id='catalog-public' and name='sha256/22/22/'||repeat('2',64)||'/poster.jpg';
reset role;
set local storage.allow_delete_query = 'false';
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select is((select count(*) from storage.objects where bucket_id='catalog-public' and name='sha256/22/22/'||repeat('2',64)||'/poster.jpg'),0::bigint,'only matching leased public object is removed');
select ok(wali.worker_complete_cleanup((select (value#>>'{}')::uuid from deletion_test_values where name='public_cleanup'),'public-cleanup-fixture'),'absence is verified before completion');
select throws_ok($$insert into storage.objects(bucket_id,name) values('catalog-public','sha256/22/22/'||repeat('2',64)||'/poster.jpg')$$,
 'P0001','WALI_ARTIFACT_DELETION_FENCED','late promotion cannot recreate removed public bytes');
select ok(not wali.prepare_account_object_cleanup((select (value->>'deletion_id')::uuid from deletion_test_values where name='creator_request'),
 '00000000-0000-0000-0000-000000000002'),'one deleted poster cannot claim all other media was erased');
savepoint before_shared_publisher_hold;
insert into deletion_test_values values('shared_creator_request',public.wali_edge_request_account_deletion_v2('00000000-0000-0000-0000-000000000006','aal2',
 '97000000-0000-4000-8000-000000000006','shared_creator_deletion_test',(select revision from wali.profiles where id='00000000-0000-0000-0000-000000000006'),repeat('6',64),'2026-09-13'));
select public.wali_edge_mark_account_deletion_sessions_revoked_v1('00000000-0000-0000-0000-000000000006',
 (select (value->>'deletion_id')::uuid from deletion_test_values where name='shared_creator_request'),'97000000-0000-4000-8000-000000000006');
select ok(not wali.deletion_object_has_other_reference(repeat('1',64),'00000000-0000-0000-0000-000000000002'),'independently consented publishers do not mutually block shared cleanup');
select wali.prepare_account_object_cleanup((select (value->>'deletion_id')::uuid from deletion_test_values where name='creator_request'),'00000000-0000-0000-0000-000000000002');
select ok(wali.deletion_cleanup_is_authorized((select cleanup_id from wali.account_deletion_object_intents where digest=repeat('1',64))),'shared bytes become eligible only after both publishers consent');
insert into wali.copyright_cases(id,target_wallpaper_id,claimant_name,claimant_email,notice_storage_path,status,received_at)
 values('97000000-0000-4000-8000-000000000016','30000000-0000-0000-0000-000000000002','Synthetic shared claimant','shared-claimant@example.invalid',
 'copyright/97000000-0000-4000-8000-000000000016/notice.pdf','open',statement_timestamp());
select ok(not wali.deletion_cleanup_is_authorized((select cleanup_id from wali.account_deletion_object_intents where digest=repeat('1',64))),'another consented publisher hold still fences the shared digest');
rollback to savepoint before_shared_publisher_hold;
insert into wali.copyright_cases(id,target_wallpaper_id,claimant_name,claimant_email,notice_storage_path,status,received_at)
 values('97000000-0000-4000-8000-000000000013','30000000-0000-0000-0000-000000000001','Synthetic claimant','claimant@example.invalid',
 'copyright/97000000-0000-4000-8000-000000000013/notice.pdf','open',statement_timestamp());
select ok(not wali.deletion_cleanup_is_authorized((select cleanup_id from wali.account_deletion_object_intents where digest=repeat('3',64))),'existing hold blocks queued bytes before irreversible removal');
select is((select count(*) from storage.objects where bucket_id='catalog-public' and name='sha256/11/11/'||repeat('1',64)||'/thumbnail.jpg'),1::bigint,'another publisher shared bytes remain');
select is(public.wali_edge_claim_account_deletion_v1((select (value->>'run_token')::uuid from deletion_test_values where name='run'))->'job','null'::jsonb,'held or unfinished deletion never reaches provider authority');
select is(public.wali_edge_account_deletion_receipt_v1(repeat('2',64))->>'stage','held','hold is visible through the signed-out receipt');
select * from finish();
rollback;
