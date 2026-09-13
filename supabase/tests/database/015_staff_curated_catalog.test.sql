-- Transaction-local fixtures; never run this file against a hosted project.
begin;
select no_plan();
select has_function('public','wali_edge_curated_catalog_command_v1',
 array['uuid','text','uuid','text','text','jsonb'],'one bounded staff catalog RPC exists');
select ok(not has_function_privilege('authenticated',
 'public.wali_edge_curated_catalog_command_v1(uuid,text,uuid,text,text,jsonb)','execute'),
 'authenticated cannot forge Edge authority through the RPC');
select ok(not has_function_privilege('anon',
 'public.wali_edge_curated_catalog_command_v1(uuid,text,uuid,text,text,jsonb)','execute'),
 'anonymous cannot execute the RPC');
select ok(has_function_privilege('service_role',
 'public.wali_edge_curated_catalog_command_v1(uuid,text,uuid,text,text,jsonb)','execute'),
 'only the existing Edge service boundary can invoke admission');
select set_config('request.jwt.claim.role','service_role',true);
create temporary table curated_fixture (key text primary key, value jsonb not null);
grant select on curated_fixture to authenticated;
create function pg_temp.curated(action text, body jsonb, operation_key text,
 actor uuid default '00000000-0000-0000-0000-000000000001', aal text default 'aal2')
returns jsonb language sql as $$
 select public.wali_edge_curated_catalog_command_v1(actor,aal,gen_random_uuid(),operation_key,action,body)
$$;
create function pg_temp.fixture(name text) returns jsonb language sql stable as $$
 select value from curated_fixture where key = name
$$;
insert into curated_fixture values ('catalog_count',to_jsonb((select count(*) from public.catalog_wallpapers_v1)));
update wali.runtime_configuration set creator_terms_version = null, catalog_license_attestation_version = null;
select is((select count(*) from public.catalog_wallpapers_v1),(pg_temp.fixture('catalog_count') #>> '{}')::bigint,
 'published catalog remains readable without Creator Terms');
select throws_ok($$select public.wali_edge_accept_creator_terms_v1(
 '00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000003',
 gen_random_uuid(),'curated_closed_creator_01',null)$$,
 'P0001','WALI_CREATOR_TERMS_REQUIRED','null Creator Terms cannot self-enroll an account');
select is((select count(*) from wali.role_grants where user_id='00000000-0000-0000-0000-000000000003' and role='creator'),
 0::bigint,'failed closed enrollment creates no creator grant');
select throws_ok($$select pg_temp.curated('accept_attestation',
 '{"expected_subject_id":"00000000-0000-0000-0000-000000000001","attestation_version":"2026-09-12"}',
 'curated_accept_disabled_01')$$,'P0001','WALI_CATALOG_ADMISSION_UNAVAILABLE','curated admission defaults disabled');
update wali.runtime_configuration set catalog_license_attestation_version='2026-09-12';
select throws_ok($$select pg_temp.curated('accept_attestation',
 '{"expected_subject_id":"00000000-0000-0000-0000-000000000001","attestation_version":"2026-09-12"}',
 'curated_accept_aal1_0001','00000000-0000-0000-0000-000000000001','aal1')$$,
 'P0001','WALI_ADMIN_AAL2_REQUIRED','AAL1 admin cannot admit curated content');
select throws_ok($$select pg_temp.curated('accept_attestation',
 '{"expected_subject_id":"00000000-0000-0000-0000-000000000004","attestation_version":"2026-09-12"}',
 'curated_moderator_only_01','00000000-0000-0000-0000-000000000004')$$,
 'P0001','WALI_ADMIN_AAL2_REQUIRED','moderator-only authority cannot upload');
select throws_ok($$select pg_temp.curated('accept_attestation',
 '{"expected_subject_id":"00000000-0000-0000-0000-000000000002","attestation_version":"2026-09-12"}',
 'curated_wrong_subject_01')$$,'P0001','WALI_AUTH_SUBJECT_CHANGED','attestation binds the initiating subject');
select throws_ok($$select pg_temp.curated('accept_attestation',
 '{"expected_subject_id":"00000000-0000-0000-0000-000000000001","attestation_version":"2026-09-11"}',
 'curated_stale_document_01')$$,'P0001','WALI_CATALOG_ATTESTATION_REQUIRED','stale document cannot be accepted');
select throws_ok($$select pg_temp.curated('accept_attestation',
 '{"expected_subject_id":"00000000-0000-0000-0000-000000000001","attestation_version":"2026-09-12","actor_aal":"aal2"}',
 'curated_forged_payload_01')$$,'P0001','WALI_REQUEST_INVALID','payload cannot carry authority fields');
insert into curated_fixture values ('create_body','{"declared_byte_count":4096,"container_hint":"video/mp4","original_filename":"licensed-fixture.mp4","target":{"kind":"new"}}');
select throws_ok($$select pg_temp.curated('create_upload',pg_temp.fixture('create_body'),'curated_before_accept_01')$$,
 'P0001','WALI_CATALOG_ATTESTATION_REQUIRED','new upload requires the separate acceptance');
select is(pg_temp.curated('accept_attestation',
 '{"expected_subject_id":"00000000-0000-0000-0000-000000000001","attestation_version":"2026-09-12"}',
 'curated_accept_valid_01')->>'document_kind','catalog_license_attestation','acceptance is truthfully named');
select is((select count(*) from wali.role_grants where user_id='00000000-0000-0000-0000-000000000001' and role='creator'),
 0::bigint,'attestation grants no creator role');
select is((select count(*) from wali.terms_acceptances where user_id='00000000-0000-0000-0000-000000000001' and document_kind='creator_terms'),
 0::bigint,'attestation does not fabricate Creator Terms');
select is(pg_temp.curated('accept_attestation',
 '{"expected_subject_id":"00000000-0000-0000-0000-000000000001","attestation_version":"2026-09-12"}',
 'curated_accept_valid_01')->>'replayed','true','acceptance replay is idempotent');
insert into curated_fixture values ('upload1',pg_temp.curated('create_upload',pg_temp.fixture('create_body'),'curated_create_upload_01'));
select is((select admission_kind from wali.upload_sessions where id=(pg_temp.fixture('upload1')->>'upload_session_id')::uuid),
 'staff_curated','new upload has immutable curated admission');
select is(pg_temp.curated('create_upload',pg_temp.fixture('create_body'),'curated_create_upload_01')->>'upload_session_id',
 pg_temp.fixture('upload1')->>'upload_session_id','idempotent create returns the same session');
select throws_ok($$select pg_temp.curated('create_upload',pg_temp.fixture('create_body')||'{"declared_byte_count":8192}',
 'curated_create_upload_01')$$,'P0001','WALI_IDEMPOTENCY_CONFLICT','changed create body conflicts');
do $$begin
 for i in 2..24 loop
  insert into curated_fixture values ('upload'||i,pg_temp.curated('create_upload',pg_temp.fixture('create_body'),'curated_create_upload_'||lpad(i::text,2,'0')));
 end loop;
end $$;
select is((select count(*) from wali.upload_sessions where admission_kind='staff_curated'),24::bigint,
 '24 new reservations are permitted per rolling day');
select throws_ok($$select pg_temp.curated('create_upload',pg_temp.fixture('create_body'),'curated_create_upload_25')$$,
 'P0001','WALI_CATALOG_UPLOAD_QUOTA_EXCEEDED','25th new reservation is refused');
select is(pg_temp.curated('create_upload',pg_temp.fixture('create_body'),'curated_create_upload_01')->>'upload_session_id',
 pg_temp.fixture('upload1')->>'upload_session_id','replay succeeds after quota is full');
select throws_ok($$update wali.upload_sessions set admission_kind='creator'
 where id=(pg_temp.fixture('upload1')->>'upload_session_id')::uuid$$,
 'P0001','WALI_ADMISSION_IMMUTABLE','a curated session cannot become a creator session');
insert into curated_fixture values ('bound1',pg_temp.curated('bind_upload',jsonb_build_object(
 'upload_session_id',pg_temp.fixture('upload1')->>'upload_session_id','expected_session_revision',1,
 'upload_endpoint','http://127.0.0.1:54321/storage/v1/upload/resumable/curated-test-1'),'curated_bind_upload_01'));
select is((pg_temp.fixture('bound1')->>'revision')::bigint,2::bigint,'server-only binding advances the upload revision');
select is((pg_temp.curated('create_upload',pg_temp.fixture('create_body'),'curated_create_upload_01')->>'revision')::bigint,
 2::bigint,'create replay refreshes TUS binding revision');
-- Exact owner/path Storage RLS is evaluated with ordinary authenticated-role claims.
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000001","aal":"aal1"}',true);
set local role authenticated;
select is((select count(*) from wali.upload_sessions where admission_kind='staff_curated'),0::bigint,
 'AAL1 owner cannot read curated upload sessions');
select throws_ok($$insert into storage.objects (bucket_id,name,owner_id,version,metadata)
 values ('uploads-private',pg_temp.fixture('upload1')->>'storage_path','00000000-0000-0000-0000-000000000001',
 'curated-raw-1','{"mimetype":"video/mp4","size":4096}')$$,'42501',
 'new row violates row-level security policy for table "objects"','AAL1 owner cannot write curated raw bytes');
reset role;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000001","aal":"aal2"}',true);
set local role authenticated;
select is((select count(*) from wali.upload_sessions where admission_kind='staff_curated'),24::bigint,
 'current owner admin AAL2 can read curated sessions');
select lives_ok($$insert into storage.objects (bucket_id,name,owner_id,version,metadata)
 values ('uploads-private',pg_temp.fixture('upload1')->>'storage_path','00000000-0000-0000-0000-000000000001',
 'curated-raw-1','{"mimetype":"video/mp4","size":4096}')$$,'current admin AAL2 can upload only its issued path');
select throws_ok($$insert into storage.objects (bucket_id,name,owner_id,version,metadata)
 values ('uploads-private','00000000-0000-0000-0000-000000000001/not-issued/source',
 '00000000-0000-0000-0000-000000000001','curated-wrong-path','{"mimetype":"video/mp4","size":4096}')$$,
 '42501','new row violates row-level security policy for table "objects"','admin still cannot upload an unissued path');
reset role;
select set_config('request.jwt.claim.role','service_role',true);
-- A synthetic negotiated license has no Creative Commons/SPDX claim.
insert into wali.licenses (id,code,name,terms_url,attribution_required,commercial_use_allowed,
 derivatives_allowed,redistribution_allowed,terms_revision)
values ('f2000000-0000-4000-8000-000000000001','curated-licensed-test','Synthetic negotiated test license',
 'https://example.invalid/license-fixture',true,false,false,true,1);
insert into curated_fixture values ('draft',jsonb_build_object('title','Licensed synthetic fixture','description','Rollback-only licensed publication.',
 'primary_category_id',(select id from wali.categories where slug='nature'),'suggested_tag_ids','[]'::jsonb,
 'content_warning',null,'rights_basis','licensed','rights_holder','Original Test Artist',
 'license_id','f2000000-0000-4000-8000-000000000001','source_url','https://example.invalid/original-test-artist',
 'attribution_text','Original Test Artist; supplied by Test Publisher.','proof_object_ids','[]'::jsonb,
 'attests_rights',true,'attestation_version','2026-09-12'));
insert into curated_fixture values ('complete_body',jsonb_build_object('upload_session_id',pg_temp.fixture('upload1')->>'upload_session_id',
 'expected_session_revision',2,'draft',pg_temp.fixture('draft')));
select throws_ok($$select pg_temp.curated('complete_upload',jsonb_set(pg_temp.fixture('complete_body'),'{draft,attribution_text}','""'),
 'curated_missing_credit_01')$$,'P0001','WALI_RIGHTS_INCOMPLETE','licensed admission requires nonblank credit');
select throws_ok($$select pg_temp.curated('complete_upload',jsonb_set(pg_temp.fixture('complete_body'),'{draft,source_url}','null'),
 'curated_missing_source_01')$$,'P0001','WALI_RIGHTS_INCOMPLETE','licensed admission requires source URL');
select throws_ok($$select pg_temp.curated('complete_upload',jsonb_set(pg_temp.fixture('complete_body'),'{draft,proof_object_ids}',
 '["00000000-0000-4000-8000-000000000099"]'),'curated_proof_rejected_01')$$,
 'P0001','WALI_RIGHTS_INCOMPLETE','curated intake does not open a proof-object workflow');
select throws_ok($$select pg_temp.curated('complete_upload',jsonb_set(pg_temp.fixture('complete_body'),'{draft,rights_basis}','"other"'),
 'curated_other_rejected_01')$$,'P0001','WALI_RIGHTS_INCOMPLETE','other rights remain unavailable');
update wali.licenses set redistribution_allowed=false where id='f2000000-0000-4000-8000-000000000001';
select throws_ok($$select pg_temp.curated('complete_upload',pg_temp.fixture('complete_body'),'curated_no_redistribute_01')$$,
 'P0001','WALI_RIGHTS_INCOMPLETE','license must permit redistribution');
update wali.licenses set redistribution_allowed=true where id='f2000000-0000-4000-8000-000000000001';
select throws_ok($$select pg_temp.curated('complete_upload',pg_temp.fixture('complete_body')||'{"expected_session_revision":1}',
 'curated_stale_revision_01')$$,'P0001','WALI_REVISION_MISMATCH','completion requires current session revision');
insert into curated_fixture values ('complete1',pg_temp.curated('complete_upload',pg_temp.fixture('complete_body'),'curated_complete_upload_01'));
select is(pg_temp.fixture('complete1')->>'state','processing','completion enters the real processing pipeline');
select is((select count(*) from wali.processing_attempts where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),
 1::bigint,'completion creates exactly one processing attempt');
select is((select attestation_document_kind from wali.rights_declarations where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),
 'catalog_license_attestation','rights are paired with catalog attestation');
select is((select license_id from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),
 'f2000000-0000-4000-8000-000000000001'::uuid,'initial submission uses the actual negotiated license');
select is(pg_temp.curated('complete_upload',pg_temp.fixture('complete_body'),'curated_complete_upload_01')->>'submission_id',
 pg_temp.fixture('complete1')->>'submission_id','completion replay produces no duplicate attempt');
select throws_ok($$update wali.rights_declarations set attestation_document_kind='creator_terms'
 where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid$$,
 'P0001','WALI_ATTESTATION_BINDING_INVALID','mixed admission/document kind is rejected by the database');
select is(pg_temp.curated('status',jsonb_build_object('upload_session_id',pg_temp.fixture('upload1')->>'upload_session_id'),
 'curated_status_upload_01')#>>'{submission,state}','processing','status uses safe processing projection');
select throws_ok($$select pg_temp.curated('submit',jsonb_build_object('submission_id',pg_temp.fixture('complete1')->>'submission_id',
 'expected_revision',1,'expected_generation',1,'attestation_version','2026-09-12'),'curated_premature_submit_01')$$,
 'P0001','WALI_SUBMISSION_NOT_READY','admission cannot substitute for worker completion');
select throws_ok($$select pg_temp.curated('complete_upload',jsonb_set(pg_temp.fixture('complete_body'),'{draft,attribution_text}',to_jsonb(repeat('x',501))),
 'curated_credit_too_long_01')$$,'P0001','WALI_RIGHTS_INCOMPLETE','curated credits fit the 500-character public contract');
-- Independently bounded capacity is checked at completion, including sessions issued before work starts.
insert into storage.objects (bucket_id,name,owner_id,version,metadata)
select 'uploads-private',pg_temp.fixture('upload'||i)->>'storage_path','00000000-0000-0000-0000-000000000001',
 'curated-raw-'||i,'{"mimetype":"video/mp4","size":4096}'::jsonb from generate_series(2,3) i;
insert into curated_fixture values ('complete2',pg_temp.curated('complete_upload',jsonb_build_object(
 'upload_session_id',pg_temp.fixture('upload2')->>'upload_session_id','expected_session_revision',1,'draft',pg_temp.fixture('draft')),
 'curated_complete_upload_02'));
select throws_ok($$select pg_temp.curated('complete_upload',jsonb_build_object(
 'upload_session_id',pg_temp.fixture('upload3')->>'upload_session_id','expected_session_revision',1,'draft',pg_temp.fixture('draft')),
 'curated_complete_upload_03')$$,'P0001','WALI_PROCESSING_CAPACITY_UNAVAILABLE','third concurrent processing/review slot is refused');
select is(pg_temp.curated('complete_upload',pg_temp.fixture('complete_body'),'curated_complete_upload_01')->>'submission_id',
 pg_temp.fixture('complete1')->>'submission_id','completion replay succeeds while both slots are occupied');
update wali.runtime_configuration set catalog_license_attestation_version=null;
select throws_ok($$select pg_temp.curated('create_upload',pg_temp.fixture('create_body'),'curated_disabled_create_01')$$,
 'P0001','WALI_CATALOG_ADMISSION_UNAVAILABLE','disabling admission blocks new reservations');
select throws_ok($$select pg_temp.curated('complete_upload',pg_temp.fixture('complete_body'),'curated_complete_upload_01')$$,
 'P0001','WALI_CATALOG_ADMISSION_UNAVAILABLE','disabled admission refuses even completion replay');
select is(pg_temp.curated('status',jsonb_build_object('upload_session_id',pg_temp.fixture('upload1')->>'upload_session_id'),
 'curated_disabled_status_01')#>>'{submission,state}','processing','disabled admission retains owner admin status');
select is(pg_temp.curated('withdraw',jsonb_build_object('submission_id',pg_temp.fixture('complete2')->>'submission_id',
 'expected_revision',1),'curated_disabled_withdraw_01')->>'state','withdrawn','disabled admission retains owned withdrawal');
select is((select status::text from wali.processing_attempts where submission_id=(pg_temp.fixture('complete2')->>'submission_id')::uuid),
 'failed','withdrawal terminates the existing processing attempt through its normal state');
update wali.runtime_configuration set catalog_license_attestation_version='2026-09-12';
-- Expired reservations and mismatched observed raw bytes cannot enter the worker queue.
update wali.upload_sessions set created_at=statement_timestamp()-interval '2 days',
 expires_at=statement_timestamp()-interval '1 day' where id=(pg_temp.fixture('upload24')->>'upload_session_id')::uuid;
select throws_ok($$select pg_temp.curated('bind_upload',jsonb_build_object(
 'upload_session_id',pg_temp.fixture('upload24')->>'upload_session_id',
 'expected_session_revision',(select revision from wali.upload_sessions where id=(pg_temp.fixture('upload24')->>'upload_session_id')::uuid),
 'upload_endpoint','http://127.0.0.1:54321/storage/v1/upload/resumable/expired'),'curated_expired_binding_01')$$,
 'P0001','WALI_UPLOAD_EXPIRED','expired curated reservation cannot receive a TUS binding');
update storage.objects set metadata=jsonb_set(metadata,'{size}','8192')
 where bucket_id='uploads-private' and name=pg_temp.fixture('upload3')->>'storage_path';
select throws_ok($$select pg_temp.curated('complete_upload',jsonb_build_object(
 'upload_session_id',pg_temp.fixture('upload3')->>'upload_session_id','expected_session_revision',1,'draft',pg_temp.fixture('draft')),
 'curated_changed_source_01')$$,'P0001','WALI_UPLOAD_CHANGED','observed raw-byte size must match the reservation');
update storage.objects set metadata=jsonb_set(metadata,'{size}','4096')
 where bucket_id='uploads-private' and name=pg_temp.fixture('upload3')->>'storage_path';
-- A second fixture admin can neither observe nor mutate the owner's session.
insert into wali.role_grants (user_id,role,granted_by,reason)
values ('00000000-0000-0000-0000-000000000003','admin','00000000-0000-0000-0000-000000000001','Rollback-only foreign administrator fixture');
select throws_ok($$select pg_temp.curated('status',jsonb_build_object('upload_session_id',pg_temp.fixture('upload1')->>'upload_session_id'),
 'curated_foreign_status_01','00000000-0000-0000-0000-000000000003')$$,
 'P0001','WALI_UPLOAD_TARGET_INVALID','another administrator cannot read owned curated state');
update wali.role_grants set revoked_at=statement_timestamp(),revoked_by='00000000-0000-0000-0000-000000000001'
where user_id='00000000-0000-0000-0000-000000000003' and role='admin';
select throws_ok($$select pg_temp.curated('status',jsonb_build_object('upload_session_id',pg_temp.fixture('upload1')->>'upload_session_id'),
 'curated_revoked_status_01','00000000-0000-0000-0000-000000000003')$$,
 'P0001','WALI_ADMIN_AAL2_REQUIRED','revoked administrator is rejected on every invocation');
update wali.profiles set status='suspended' where id='00000000-0000-0000-0000-000000000001';
select throws_ok($$select pg_temp.curated('status',jsonb_build_object('upload_session_id',pg_temp.fixture('upload1')->>'upload_session_id'),
 'curated_suspended_status_01')$$,'P0001','WALI_ADMIN_AAL2_REQUIRED','suspended owner cannot read status');
update wali.profiles set status='active' where id='00000000-0000-0000-0000-000000000001';
-- Deliberately enable ordinary Creator only in this rollback-only test, to prove cross-mode guards.
update wali.runtime_configuration set creator_terms_version='2026-09-01';
select public.wali_edge_accept_creator_terms_v1('00000000-0000-0000-0000-000000000001',
 '00000000-0000-0000-0000-000000000001',gen_random_uuid(),'curated_dual_role_terms_01','2026-09-01');
select throws_ok($$select public.wali_edge_complete_upload_v1('00000000-0000-0000-0000-000000000001',gen_random_uuid(),
 'curated_via_creator_complete',(pg_temp.fixture('upload3')->>'upload_session_id')::uuid,1)$$,
 'P0001','WALI_ADMISSION_MISMATCH','ordinary completion cannot admit curated sessions');
select throws_ok($$select public.wali_edge_bind_upload_endpoint_v1('00000000-0000-0000-0000-000000000001',
 (pg_temp.fixture('upload3')->>'upload_session_id')::uuid,1,'http://127.0.0.1:54321/storage/v1/upload/resumable/wrong-branch')$$,
 'P0001','WALI_ADMISSION_MISMATCH','ordinary TUS binding rejects curated sessions');
select throws_ok($$select public.wali_edge_submit_wallpaper_v1('00000000-0000-0000-0000-000000000001',gen_random_uuid(),
 'curated_via_creator_submit',(pg_temp.fixture('complete1')->>'submission_id')::uuid,1,1,'2026-09-01')$$,
 'P0001','WALI_ADMISSION_MISMATCH','ordinary submit rejects curated submissions');
select throws_ok($$select public.wali_edge_withdraw_submission_v1('00000000-0000-0000-0000-000000000001',gen_random_uuid(),
 'curated_via_creator_withdraw',(pg_temp.fixture('complete1')->>'submission_id')::uuid,1)$$,
 'P0001','WALI_ADMISSION_MISMATCH','ordinary withdrawal cannot bypass curated AAL2');
insert into curated_fixture values ('ordinary_before_disable', public.wali_edge_create_upload_v1(
 '00000000-0000-0000-0000-000000000001',gen_random_uuid(),'curated_ordinary_before_disable',
 4096,'video/mp4','ordinary-before-disable.mp4','new',null,null));
update wali.runtime_configuration set creator_terms_version=null;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000001","aal":"aal1"}',true);
set local role authenticated;
select throws_ok($$insert into storage.objects (bucket_id,name,owner_id,metadata)
 values ('uploads-private',pg_temp.fixture('ordinary_before_disable')->>'storage_path',
 '00000000-0000-0000-0000-000000000001','{"size":4096,"mimetype":"video/mp4"}')$$,
 '42501',null,'disabling Creator closes raw writes for an already-issued ordinary upload');
select is((select count(*) from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),0::bigint,
 'AAL1 owner cannot directly read curated submissions');
select is(jsonb_array_length(public.my_creator_submissions_v1(null,24)->'items'),0,'old Creator list excludes curated submissions');
select is((select count(*) from public.my_creator_submissions_v1),0::bigint,'old Creator view excludes curated submissions');
select throws_ok($$select public.creator_processing_status_v1((pg_temp.fixture('complete1')->>'submission_id')::uuid,1)$$,
 'P0001','WALI_SUBMISSION_NOT_FOUND','old processing status does not expose curated state');
reset role;
select set_config('request.jwt.claim.role','service_role',true);
update wali.runtime_configuration set creator_terms_version=null;
select throws_ok($$select public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000001',gen_random_uuid(),
 'curated_old_terms_closed',4096,'video/mp4','ordinary.mp4','new',null,null)$$,
 'P0001','WALI_CREATOR_TERMS_REQUIRED','historic Creator acceptance does not reopen disabled intake');
-- The existing worker observes four artifacts; no processing/approval success rows are inserted.
insert into curated_fixture values ('attempt1',to_jsonb((select id from wali.processing_attempts
 where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid)));
select is(wali.worker_begin_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,
 (pg_temp.fixture('complete1')->>'submission_id')::uuid,1,'curated-fixture-worker',
 statement_timestamp()+interval '4 minutes'),'started','existing worker leases the actual curated attempt');
create temporary table curated_artifacts (claim jsonb not null);
insert into curated_artifacts values
 ('{"role":"thumbnail","digest":"1111111111111111111111111111111111111111111111111111111111111f01","byte_count":1024,"media_type":"image/jpeg","width":512,"height":512,"duration_ms":0,"frame_rate_numerator":0,"frame_rate_denominator":0,"codec":"jpeg","pixel_format":"yuvj420p","color_space":"sRGB","has_audio":false}'),
 ('{"role":"poster","digest":"2222222222222222222222222222222222222222222222222222222222222f02","byte_count":2048,"media_type":"image/jpeg","width":1920,"height":1080,"duration_ms":0,"frame_rate_numerator":0,"frame_rate_denominator":0,"codec":"jpeg","pixel_format":"yuvj420p","color_space":"sRGB","has_audio":false}'),
 ('{"role":"preview","digest":"3333333333333333333333333333333333333333333333333333333333333f03","byte_count":4096,"media_type":"video/mp4","width":960,"height":540,"duration_ms":5000,"frame_rate_numerator":30,"frame_rate_denominator":1,"codec":"hevc","pixel_format":"yuv420p10le","color_space":"bt709","has_audio":false}'),
 ('{"role":"video_default","digest":"4444444444444444444444444444444444444444444444444444444444444f04","byte_count":8192,"media_type":"video/mp4","width":3840,"height":2160,"duration_ms":30000,"frame_rate_numerator":60,"frame_rate_denominator":1,"codec":"hevc","pixel_format":"yuv420p10le","color_space":"bt709","has_audio":false}');
do $$declare a jsonb; path text;
begin
 for a in select claim from curated_artifacts loop
  if not wali.worker_authorize_staged_artifact((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'curated-fixture-worker',a)
   then raise exception 'curated fixture staged authorization failed'; end if;
  path:='sha256/'||substring(a->>'digest' from 1 for 2)||'/'||substring(a->>'digest' from 3 for 2)||'/'||
   (a->>'digest')||'/'||replace(a->>'role','_','-')||case a->>'media_type' when 'image/jpeg' then '.jpg' else '.mp4' end;
  insert into storage.objects (bucket_id,name,metadata) values ('processing-private',path,
   jsonb_build_object('mimetype',a->>'media_type','size',(a->>'byte_count')::bigint));
 end loop;
end $$;
insert into curated_fixture values ('worker_completion',jsonb_build_object('source_digest',repeat('d',64),
 'artifacts',(select jsonb_agg(claim order by claim->>'role') from curated_artifacts),
 'classification','{"available":false,"safe_code":"classifier_unavailable","model_id":"","model_revision":"","model_digest":"","taxonomy_revision":"","input_frame_set_digest":"","categories":[],"tags":[],"visual_embedding":[],"text_embedding":[],"combined_embedding":[]}'::jsonb));
select ok(wali.worker_complete_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'curated-fixture-worker',
 pg_temp.fixture('worker_completion')),'four observed staged artifacts complete the real database processing transaction');
select ok(wali.submission_has_verified_media((pg_temp.fixture('complete1')->>'submission_id')::uuid,1),
 'the ordinary verified-media gate accepts the curated generation');
create function pg_temp.submit_curated(operation_key text, generation bigint default 1) returns jsonb language sql as $$
 select pg_temp.curated('submit',jsonb_build_object('submission_id',pg_temp.fixture('complete1')->>'submission_id',
 'expected_revision',(select revision from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),
 'expected_generation',generation,'attestation_version','2026-09-12'),operation_key)
$$;
select throws_ok($$select pg_temp.submit_curated('curated_wrong_generation_01',2)$$,
 'P0001','WALI_STALE_PROCESSING_GENERATION','submit binds the completed generation');
select is(pg_temp.submit_curated('curated_valid_submit_01')->>'state','submitted','verified curated generation submits normally');
create function pg_temp.review_curated(decision wali.review_decision, operation_key text,
 reviewer uuid default '00000000-0000-0000-0000-000000000004') returns jsonb language sql as $$
 select public.wali_edge_moderate_submission_v1(reviewer,'aal2',gen_random_uuid(),operation_key,
 (pg_temp.fixture('complete1')->>'submission_id')::uuid,
 (select revision from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),1,
 decision,1,array[case decision when 'approved' then 'policy_pass' else 'metadata_inaccurate' end],
 'Rollback-only independent review.',null)
$$;
select throws_ok($$select pg_temp.review_curated('approved','curated_self_review_01','00000000-0000-0000-0000-000000000001')$$,
 'P0001','WALI_SELF_REVIEW_FORBIDDEN','uploading administrator cannot approve their submission');
select is(pg_temp.review_curated('changes_requested','curated_changes_requested_01')->>'state','changes_requested',
 'independent reviewer can request corrections through the existing workflow');
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000001","aal":"aal2"}',true);
set local role authenticated;
with changed as (update wali.submissions set proposed_title='Bypassed edit'
 where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid returning id)
select is((select count(*) from changed),0::bigint,
 'direct owner draft update cannot bypass the checked curated command');
reset role;
select set_config('request.jwt.claim.role','service_role',true);
select is(pg_temp.curated('save_draft',jsonb_build_object('submission_id',pg_temp.fixture('complete1')->>'submission_id',
 'expected_revision',(select revision from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),
 'draft',pg_temp.fixture('draft')||'{"title":"Corrected licensed synthetic fixture"}'),'curated_save_correction_01')->>'state',
 'ready_for_submission','curated correction reuses only the current verified media');
select is((select review_status::text from wali.rights_declarations where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),
 'pending','correction resets rights review');
select is(pg_temp.submit_curated('curated_valid_submit_02')->>'state','submitted','corrected draft requires a fresh submission');
select is(pg_temp.review_curated('approved','curated_independent_approve_01')->>'state','approved',
 'different real fixture moderator approves using existing moderation command');
select ok((public.moderation_queue_v1('00000000-0000-0000-0000-000000000004','aal2','approved')->'items')::text
 like '%Catalog License Attestation 2026-09-12%','staff rights summary distinguishes the actual attestation');
create function pg_temp.prepare_curated(operation_key text) returns jsonb language sql as $$
 select public.wali_edge_prepare_publication_v1('00000000-0000-0000-0000-000000000004','aal2',gen_random_uuid(),operation_key,
 (pg_temp.fixture('complete1')->>'submission_id')::uuid,
 (select revision from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),1,
 (select w.revision from wali.wallpapers w join wali.submissions s on s.wallpaper_id=w.id where s.id=(pg_temp.fixture('complete1')->>'submission_id')::uuid))
$$;
insert into curated_fixture values ('promotion',pg_temp.prepare_curated('curated_publish_pipeline_01'));
select is(pg_temp.fixture('promotion')->>'status','promotion_pending','publication requires normal worker promotion first');
select is(wali.worker_begin_promotion((pg_temp.fixture('promotion')->>'promotion_id')::uuid,'curated-fixture-worker',
 statement_timestamp()+interval '4 minutes')->>'disposition','started','existing worker obtains a bounded promotion lease');
insert into storage.objects (bucket_id,name,metadata)
select 'catalog-public',a.storage_path,jsonb_build_object('mimetype',a.media_type,'size',a.byte_count)
 from wali.staged_artifacts a where a.verified_by_attempt_id=(pg_temp.fixture('attempt1')#>>'{}')::uuid;
select ok(wali.worker_complete_promotion((pg_temp.fixture('promotion')->>'promotion_id')::uuid,'curated-fixture-worker',
 (select jsonb_agg(claim) from curated_artifacts)),'promotion checks all four observed public-object claims');
insert into curated_fixture values ('prepared',pg_temp.prepare_curated('curated_publish_pipeline_01'));
select ok(not (pg_temp.fixture('prepared')::text like '%catalog_license_attestation%'),
 'private consent discriminator does not enter public signing metadata');
-- Signature bytes below are a database-envelope fixture, not a cryptographic/provider acceptance claim.
create function pg_temp.finalize_curated(operation_key text) returns jsonb language plpgsql as $$
declare p jsonb := pg_temp.fixture('prepared'); metadata bytea; manifest bytea; md text;
begin
 metadata:=convert_to(jsonb_build_object('schema','wali.catalog.install-metadata.v1','wallpaper_id',p->>'wallpaper_id',
  'release_id',p->>'release_id','title',p->>'title','rights_holder',p->>'rights_holder',
  'attribution_text',p#>>'{attribution,text}','creator_name',p#>>'{creator,display_name}',
  'creator_handle',p#>>'{creator,handle}')::text,'UTF8');
 md:=encode(extensions.digest(metadata,'sha256'),'hex');
 manifest:=convert_to(jsonb_build_object('wallpaper_id',p->>'wallpaper_id','release_id',p->>'release_id',
  'key_id',p->>'key_id','metadata_digest',md,'artifacts',p->'artifacts')::text,'UTF8');
 return public.wali_edge_finalize_publication_v1('00000000-0000-0000-0000-000000000004','aal2',gen_random_uuid(),operation_key,
  (pg_temp.fixture('complete1')->>'submission_id')::uuid,
  (select revision from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),1,
  (select revision from wali.wallpapers where id=(p->>'wallpaper_id')::uuid),
  translate(encode(manifest,'base64'),E'+/=\n\r','-_'),translate(encode(metadata,'base64'),E'+/=\n\r','-_'),
  encode(extensions.digest(manifest,'sha256'),'hex'),md,
  translate(encode(decode(repeat('ab',64),'hex'),'base64'),E'+/=\n\r','-_'),p->>'key_id');
end $$;
update wali.rights_declarations set attested_at=attested_at+interval '1 second'
 where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid;
select throws_ok($$select pg_temp.finalize_curated('curated_publish_pipeline_01')$$,
 'P0001','WALI_PUBLICATION_INTENT_STALE','private attestation revision is bound to the signing snapshot');
update curated_fixture set value=pg_temp.prepare_curated('curated_publish_pipeline_02') where key='prepared';
select is(pg_temp.finalize_curated('curated_publish_pipeline_02')->>'wallpaper_id',pg_temp.fixture('prepared')->>'wallpaper_id',
 'fresh matching rights snapshot finalizes through the existing publication transaction');
select is((select license_id from wali.wallpapers where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid),
 'f2000000-0000-4000-8000-000000000001'::uuid,'published record retains the negotiated license');
-- A genuine human publication satisfies an already-queued automatic job.
insert into curated_fixture values ('automatic_job',public.wali_edge_claim_automatic_publication_v1()->'job');
select ok(pg_temp.fixture('automatic_job')->>'id' is not null,'curated verified processing queued automatic publication');
select lives_ok($$select public.wali_edge_prepare_automatic_publication_v1(
 (pg_temp.fixture('automatic_job')->>'id')::uuid,(pg_temp.fixture('automatic_job')->>'lease_token')::uuid)$$,
 'automatic retry reconciles the actual human publication');
select is((select count(*) from wali.automatic_publication_decisions),0::bigint,'reconciliation does not invent an extra system decision');
select ok(public.wali_edge_finish_automatic_publication_v1(
 (pg_temp.fixture('automatic_job')->>'id')::uuid,(pg_temp.fixture('automatic_job')->>'lease_token')::uuid,'completed',null),
 'human publication completes the existing automatic job');
update wali.runtime_configuration set catalog_license_attestation_version=null;
select is((select count(*) from public.catalog_wallpapers_v1 where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid),
 1::bigint,'published curated catalog survives admission rollback with Creator still disabled');
insert into curated_fixture values ('export',public.wali_edge_request_account_export_v1(
 '00000000-0000-0000-0000-000000000001',gen_random_uuid(),'curated_account_export_01'));
select wali.worker_begin_export((pg_temp.fixture('export')->>'export_id')::uuid,
 '00000000-0000-0000-0000-000000000001','curated-fixture-worker',statement_timestamp()+interval '4 minutes');
select ok(wali.worker_read_account_export((pg_temp.fixture('export')->>'export_id')::uuid,
 '00000000-0000-0000-0000-000000000001','curated-fixture-worker') @?
 '$.rights_declarations[*] ? (@.attestation_document_kind == "catalog_license_attestation" && @.attestation_version == "2026-09-12")',
 'owner export pairs the alternate document kind and version');
select * from finish();
rollback;
