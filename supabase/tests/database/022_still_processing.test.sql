-- Run with the local fixture administrator for the explicit restricted-role section.
-- Rollback-only local database fixtures. Synthetic object metadata and signature
-- bytes test database invariants; they are not real media/cryptographic evidence.
begin;
-- Synthetic role selection for this rollback-only test; session_user stays postgres.
grant wali_worker to postgres with set true;
-- Synthetic effective legal version for this rollback-only fixture.
update wali.runtime_configuration set creator_terms_version='2026-09-12' where singleton;
select no_plan();
select has_column('wali','submissions','media_kind','submission kind is durable');
select has_function('wali','worker_complete_still_attempt_v2',array['uuid','integer','text','jsonb'],'still completion has explicit V2');

select has_table('wali','automatic_publication_jobs','automatic publication is durable');
select has_table('wali','automatic_publication_decisions','system attribution is explicit');
select has_function('public','wali_edge_complete_upload_v1',array['uuid','uuid','text','uuid','bigint','jsonb'],'completion requires draft binding');
select ok(not has_function_privilege('authenticated','public.wali_edge_claim_automatic_publication_v1()','execute'),'user cannot claim publication jobs');
select ok(not has_function_privilege('wali_worker','public.wali_edge_prepare_automatic_publication_v1(uuid,uuid)','execute'),'media worker cannot authorize publication');
select ok(not has_function_privilege('service_role','wali.dispatch_automatic_publication_tick()','execute'),'Edge cannot read scheduler Vault secret through tick');
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
create temporary table auto_fixture(key text primary key,value jsonb not null);
create function pg_temp.fixture(name text) returns jsonb language sql stable as $$select value from auto_fixture where key=name$$;
update auth.users set email_confirmed_at=null where id='00000000-0000-0000-0000-000000000003';
select throws_ok($$select public.wali_edge_accept_creator_terms_v1('00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000003',gen_random_uuid(),'auto_unverified_01','2026-09-12')$$,
 'P0001','WALI_VERIFIED_EMAIL_REQUIRED','unverified email cannot enroll Creator');
update auth.users set email_confirmed_at=statement_timestamp() where id='00000000-0000-0000-0000-000000000003';
select is(public.wali_edge_accept_creator_terms_v1('00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000003',gen_random_uuid(),'auto_verified_01','2026-09-12')->>'creator_enrolled','true','verified ordinary user enrolls without AAL2');
select throws_ok($$select public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'still_gated_000001',4096,'image/png','source.png','new',null,null)$$,'P0001','WALI_STILL_INTAKE_DISABLED','still intake starts disabled');
update wali.runtime_configuration set still_policy_digest=repeat('b',64),still_uploads_enabled=true;
select throws_ok($$select public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'still_excess_000001',134217729,'image/png','source.png','new',null,null)$$,'P0001','WALI_REQUEST_INVALID','still encoded input cap is enforced');
insert into auto_fixture values('upload1',public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'auto_upload_new_01',4096,'image/png','source.png','new',null,null));
insert into storage.objects(bucket_id,name,owner_id,version,metadata)
values('uploads-private',pg_temp.fixture('upload1')->>'storage_path','00000000-0000-0000-0000-000000000003','auto-raw-v1','{"size":4096,"mimetype":"image/png"}');
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
select throws_ok($$select pg_temp.complete_auto(pg_temp.fixture('draft')||'{"attests_rights":false}','auto_false_rights_01')$$,'P0001','WALI_RIGHTS_INCOMPLETE','no fabricated attestation');
select throws_ok($$select pg_temp.complete_auto(pg_temp.fixture('draft')||'{"source_url":null}','auto_no_source_01')$$,'P0001','WALI_RIGHTS_INCOMPLETE','licensed claim retains source');
insert into auto_fixture values('complete1',pg_temp.complete_auto(pg_temp.fixture('draft'),'auto_complete_0001'));
select is(pg_temp.fixture('complete1')->>'revision','1','completion retains first submission revision');
select is((select proposed_title from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),'Actual licensed title','worker receives actual metadata');
select is((select basis::text from wali.rights_declarations where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),'licensed','licensed rights exist before processing');
select is((select cardinality(proof_object_ids) from wali.rights_declarations where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),0,'no private proof upload is invented');
select is((select count(*) from wali.automatic_publication_jobs),0::bigint,'unverified processing cannot enqueue publication');
select is(pg_temp.complete_auto(pg_temp.fixture('draft'),'auto_complete_0001')-'replayed',pg_temp.fixture('complete1'),'completion replay does not duplicate jobs');
select throws_ok($$select pg_temp.complete_auto(pg_temp.fixture('draft')||'{"title":"Changed replay"}','auto_complete_0001')$$,'P0001','WALI_IDEMPOTENCY_CONFLICT','replay binds metadata');
insert into auto_fixture values('attempt1',to_jsonb((select id from wali.processing_attempts where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid)));
select is((select count(*) from wali.worker_queue_read('wali_media_processing',60)),0::bigint,'legacy queue reader skips still before leasing');
insert into auto_fixture values('leased_image',(select message from wali.worker_queue_read_v2('wali_media_processing',60)));
select is(pg_temp.fixture('leased_image')->>'media_kind','still','V2 queue reader leases tagged image');
select ok((select execution_deadline_at between statement_timestamp()+interval '19 minutes 59 seconds' and statement_timestamp()+interval '20 minutes 1 second' from wali.processing_attempts where id=(pg_temp.fixture('attempt1')#>>'{}')::uuid),'still budget starts at first queue lease');
select throws_ok($$select wali.worker_begin_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,(pg_temp.fixture('complete1')->>'submission_id')::uuid,1,'auto-fixture-worker',statement_timestamp()+interval '4 minutes')$$,'P0001','WALI_MEDIA_KIND_MISMATCH','legacy worker cannot begin still attempt');
select is(wali.worker_begin_still_attempt_v2((pg_temp.fixture('attempt1')#>>'{}')::uuid,(pg_temp.fixture('complete1')->>'submission_id')::uuid,1,'auto-fixture-worker',statement_timestamp()+interval '4 minutes'),'started','real processing RPC leases fixture');

create temporary table auto_artifacts (claim jsonb not null);
insert into auto_artifacts values
 ('{"role":"thumbnail","digest":"1111111111111111111111111111111111111111111111111111111111111e01","byte_count":1024,"media_type":"image/jpeg","width":512,"height":512,"duration_ms":0,"frame_rate_numerator":0,"frame_rate_denominator":1,"codec":"mjpeg","pixel_format":"yuvj420p","color_space":"bt470bg","has_audio":false}'),
 ('{"role":"poster","digest":"1111111111111111111111111111111111111111111111111111111111111e01","byte_count":1024,"media_type":"image/jpeg","width":512,"height":512,"duration_ms":0,"frame_rate_numerator":0,"frame_rate_denominator":1,"codec":"mjpeg","pixel_format":"yuvj420p","color_space":"bt470bg","has_audio":false}'),
 ('{"role":"image_default","digest":"4444444444444444444444444444444444444444444444444444444444444e04","byte_count":8192,"media_type":"image/png","width":2160,"height":4320,"duration_ms":0,"frame_rate_numerator":0,"frame_rate_denominator":1,"codec":"png","pixel_format":"rgb24","color_space":"srgb","has_audio":false}');
select throws_ok($$select wali.worker_authorize_still_artifact_v2((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'auto-fixture-worker',(select claim||'{"byte_count":16777217}' from auto_artifacts where claim->>'role'='poster'))$$,'P0001','WALI_WORKER_OUTPUT_INVALID','still poster cannot exceed its 16 MiB contract');
select throws_ok($$select wali.worker_authorize_still_artifact_v2((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'auto-fixture-worker',(select claim||'{"byte_count":16777217}' from auto_artifacts where claim->>'role'='thumbnail'))$$,'P0001','WALI_WORKER_OUTPUT_INVALID','still thumbnail cannot exceed its 16 MiB contract');
select throws_ok($$select wali.worker_authorize_still_artifact_v2((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'auto-fixture-worker',(select claim||'{"duration_ms":1}' from auto_artifacts where claim->>'role'='image_default'))$$,'P0001','WALI_WORKER_OUTPUT_INVALID','still cannot carry video timing');
select throws_ok($$select wali.worker_authorize_staged_artifact((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'auto-fixture-worker',(select claim from auto_artifacts where claim->>'role'='thumbnail'))$$,'P0001','WALI_MEDIA_KIND_MISMATCH','legacy worker cannot authorize still outputs');
do $$declare a jsonb; path text;
begin
 for a in select claim from auto_artifacts loop
  if not wali.worker_authorize_still_artifact_v2((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'auto-fixture-worker',a)
   then raise exception 'automatic fixture staged authorization failed'; end if;
  path:='sha256/'||substring(a->>'digest' from 1 for 2)||'/'||substring(a->>'digest' from 3 for 2)||'/'||
   (a->>'digest')||'/'||replace(a->>'role','_','-')||case a->>'media_type' when 'image/jpeg' then '.jpg' else '.png' end;
  insert into storage.objects (bucket_id,name,metadata) values ('processing-private',path,
   jsonb_build_object('mimetype',a->>'media_type','size',(a->>'byte_count')::bigint));
 end loop;
end $$;
insert into auto_fixture values ('worker_completion',jsonb_build_object('schema_version',2,'media_kind','still','source_digest',repeat('d',64),
 'artifacts',(select jsonb_agg(claim order by claim->>'role') from auto_artifacts),
 'classification','{"available":false,"safe_code":"classifier_unavailable","model_id":"","model_revision":"","model_digest":"","taxonomy_revision":"","input_frame_set_digest":"","categories":[],"tags":[],"visual_embedding":[],"text_embedding":[],"combined_embedding":[]}'::jsonb));
select throws_ok($$select wali.worker_complete_still_attempt_v2((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'auto-fixture-worker',pg_temp.fixture('worker_completion')||'{"source_digest":null}')$$,'P0001','WALI_WORKER_OUTPUT_INVALID','still completion rejects missing actual input digest');
grant select on auto_fixture,auto_artifacts to wali_worker;
grant insert on auto_fixture to wali_worker;
select set_config('request.jwt.claim.role','',true);
select set_config('request.jwt.claims','{}',true);
set local role wali_worker;
insert into auto_fixture values('worker_actual_result',to_jsonb(wali.worker_complete_still_attempt_v2((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'auto-fixture-worker',
 pg_temp.fixture('worker_completion'))));
reset role;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select is(pg_temp.fixture('worker_actual_result'),'true'::jsonb,'restricted worker without user JWT completes verified still');
select ok(wali.submission_has_verified_media((pg_temp.fixture('complete1')->>'submission_id')::uuid,1),
 'the current generation passes the established byte-verification gate');


select is((select count(*) from wali.automatic_publication_jobs),1::bigint,'verified completion alone queues automatic publication');
insert into auto_fixture values('job',public.wali_edge_claim_automatic_publication_v1()->'job');
create function pg_temp.prepare_auto() returns jsonb language sql as $$
 select public.wali_edge_prepare_automatic_publication_v1((pg_temp.fixture('job')->>'id')::uuid,(pg_temp.fixture('job')->>'lease_token')::uuid)
$$;
select throws_ok($$select public.wali_edge_prepare_automatic_publication_v1((pg_temp.fixture('job')->>'id')::uuid,gen_random_uuid())$$,'P0001','WALI_PUBLICATION_LEASE_LOST','stale lease cannot approve');
update wali.profiles set status='suspended' where id='00000000-0000-0000-0000-000000000003';
select throws_ok($$select pg_temp.prepare_auto()$$,'P0001','WALI_AUTOMATIC_PUBLICATION_NOT_ELIGIBLE','account suspension is rechecked after processing');
update wali.profiles set status='active' where id='00000000-0000-0000-0000-000000000003';
insert into auto_fixture values('promotion',pg_temp.prepare_auto());
select is(pg_temp.fixture('promotion')->>'status','promotion_pending','system decision still requires immutable promotion');
select is((select count(*) from wali.moderation_reviews where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),0::bigint,'no fictional human reviewer is created');
select ok((select reviewed_by is null and system_publication_decision_id is not null from wali.rights_declarations where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),'rights decision is honestly system-attributed');
select is((select count(*) from wali.automatic_publication_decisions),1::bigint,'one immutable system decision');
select throws_ok($$update wali.automatic_publication_decisions set policy_version='automatic-publication-2026-09-12'$$,'P0001','WALI_APPEND_ONLY','system decision evidence is immutable');
select throws_ok($$select public.wali_edge_finish_automatic_publication_v1((pg_temp.fixture('job')->>'id')::uuid,(pg_temp.fixture('job')->>'lease_token')::uuid,'completed',null)$$,'P0001','WALI_SUBMISSION_NOT_READY','promotion wait cannot be acknowledged as published');
select is((select count(*) from wali.worker_queue_read('wali_promotions',60)),0::bigint,'legacy queue reader skips still promotion before lease');
select is((select message->>'media_kind' from wali.worker_queue_read_v2('wali_promotions',60)),'still','V2 reader admits tagged three-object promotion');
select is(wali.worker_begin_promotion((pg_temp.fixture('promotion')->>'promotion_id')::uuid,'auto-fixture-worker',statement_timestamp()+interval '4 minutes')->>'disposition','started','worker promotion uses existing lease');
insert into storage.objects(bucket_id,name,metadata)
select 'catalog-public',a.storage_path,jsonb_build_object('mimetype',a.media_type,'size',a.byte_count)
 from wali.staged_artifacts a where a.verified_by_attempt_id=(pg_temp.fixture('attempt1')#>>'{}')::uuid;
select ok(wali.worker_complete_promotion((pg_temp.fixture('promotion')->>'promotion_id')::uuid,'auto-fixture-worker',(select jsonb_agg(claim) from auto_artifacts)),'promotion verifies all immutable object claims');
insert into auto_fixture values('prepared',pg_temp.prepare_auto());
select is((select count(*) from wali.release_artifacts where release_id=(pg_temp.fixture('prepared')->>'release_id')::uuid),3::bigint,'still promotion retains exact three roles');
select is((select count(distinct artifact_digest) from wali.release_artifacts where release_id=(pg_temp.fixture('prepared')->>'release_id')::uuid),2::bigint,'identical poster/thumbnail bytes are truly deduplicated');
select is((select count(*) from wali.publication_intents where actor_id is null and system_publication_decision_id is not null),1::bigint,'signing intent has a system decision, no fake human');


select is(public.wali_edge_claim_automatic_publication_v1()->'job','null'::jsonb,'live lease cannot be claimed twice');
select ok(public.wali_edge_finish_automatic_publication_v1((pg_temp.fixture('job')->>'id')::uuid,(pg_temp.fixture('job')->>'lease_token')::uuid,'retry','WALI_PUBLICATION_RETRYING'),'transport failure remains durable');
update wali.automatic_publication_jobs set next_attempt_at=statement_timestamp()-interval '1 second';
update auto_fixture set value=public.wali_edge_claim_automatic_publication_v1()->'job' where key='job';
select lives_ok($$select pg_temp.prepare_auto()$$,'transport retry reuses intent without a revision conflict');
update wali.automatic_publication_jobs set attempts=12;
select ok(public.wali_edge_finish_automatic_publication_v1((pg_temp.fixture('job')->>'id')::uuid,(pg_temp.fixture('job')->>'lease_token')::uuid,'retry','WALI_PUBLICATION_RETRYING'),'exhausted retry reports a recoverable failure');
select is((select status from wali.automatic_publication_jobs),'failed','bounded retries terminate visibly');
select lives_ok($$select public.wali_edge_retry_publication_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'auto_user_retry_01',
 (pg_temp.fixture('complete1')->>'submission_id')::uuid,(select revision from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid))$$,'actual AAL1 creator can retry failed publication');
update auto_fixture set value=public.wali_edge_claim_automatic_publication_v1()->'job' where key='job';
select lives_ok($$select pg_temp.prepare_auto()$$,'user retry preserves system decision and refreshes only operational revision');
update wali.publication_intents set created_at=statement_timestamp()-interval '11 minutes',issued_at=statement_timestamp()-interval '10 minutes',expires_at=statement_timestamp()-interval '6 minutes' where actor_id is null;
select lives_ok($$select pg_temp.prepare_auto()$$,'expired signing intent renews within a bounded issue-time window');
update auto_fixture set value=pg_temp.prepare_auto() where key='prepared';
create function pg_temp.finalize_auto() returns jsonb language plpgsql as $$
declare p jsonb := pg_temp.fixture('prepared'); metadata bytea; manifest bytea; md text;
begin
 metadata:=convert_to(jsonb_build_object('schema','wali.catalog.install-metadata.v1','wallpaper_id',p->>'wallpaper_id',
  'release_id',p->>'release_id','title',p->>'title','rights_holder',p->>'rights_holder',
  'attribution_text',p#>>'{attribution,text}','creator_name',p#>>'{creator,display_name}',
  'creator_handle',p#>>'{creator,handle}')::text,'UTF8');
 md:=encode(extensions.digest(metadata,'sha256'),'hex');
 manifest:=convert_to(jsonb_build_object('schema',jsonb_build_object('epoch',2,'revision',0),'media_kind','still','wallpaper_id',p->>'wallpaper_id','release_id',p->>'release_id',
  'key_id',p->>'key_id','metadata_digest',md,'artifacts',p->'artifacts')::text,'UTF8');
 return public.wali_edge_finalize_automatic_publication_v1(
  (pg_temp.fixture('job')->>'id')::uuid,(pg_temp.fixture('job')->>'lease_token')::uuid,
  translate(encode(manifest,'base64'),E'+/=\n\r','-_'),translate(encode(metadata,'base64'),E'+/=\n\r','-_'),
  encode(extensions.digest(manifest,'sha256'),'hex'),md,
  translate(encode(decode(repeat('00',64),'hex'),'base64'),E'+/=\n\r','-_'),p->>'key_id');
end $$;

create function pg_temp.delisted_finalization() returns jsonb language plpgsql as $$
begin update wali.wallpapers set status='hidden' where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid;
 return pg_temp.finalize_auto(); end $$;
select throws_ok($$select pg_temp.delisted_finalization()$$,'P0001','WALI_AUTOMATIC_PUBLICATION_NOT_ELIGIBLE','automatic publication never resurrects a delisted wallpaper');
insert into auto_fixture values('published',pg_temp.finalize_auto());
select is((select status::text from wali.submissions where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),'published','verified pipeline publishes without human review');
select is((select count(*) from public.catalog_wallpapers_v1 where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid),0::bigint,'V1 cannot expose a still release');
select is(pg_temp.prepare_auto()->'response',pg_temp.fixture('published'),'lost final response replays immutable publication');
select ok(public.wali_edge_finish_automatic_publication_v1((pg_temp.fixture('job')->>'id')::uuid,(pg_temp.fixture('job')->>'lease_token')::uuid,'completed',null),'only committed publication completes the job');
select is((select status from wali.automatic_publication_jobs),'completed','durable job ends once');
select is((select count(*) from wali.moderation_reviews where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),0::bigint,'publication never fabricates a human review');


select is(pg_temp.fixture('prepared')->>'media_kind','still','signer preparation binds still kind');
select is((select manifest_epoch from wali.wallpaper_releases where id=(pg_temp.fixture('prepared')->>'release_id')::uuid),2,'still release uses manifest epoch 2');
select throws_ok($$update wali.submissions set media_kind='video' where id=(pg_temp.fixture('complete1')->>'submission_id')::uuid$$,'P0001','WALI_MEDIA_KIND_IMMUTABLE','submission kind cannot change after admission');
select throws_ok($$update wali.wallpaper_releases set media_kind='video' where id=(pg_temp.fixture('prepared')->>'release_id')::uuid$$,'P0001','WALI_MEDIA_KIND_IMMUTABLE','published release kind cannot change');

select is(wali.creator_processing_projection((pg_temp.fixture('complete1')->>'submission_id')::uuid,1)#>>'{media_facts,media_kind}','still','Creator facts bind still kind');
select ok(not ((wali.creator_processing_projection((pg_temp.fixture('complete1')->>'submission_id')::uuid,1)->'media_facts') ?| array['frame_rate','duration_ms']),'Creator still facts omit timing');
select has_function('public','catalog_browse_v2',array['text','text[]','text','text','integer'],'V2 Browse is explicit');
select is(public.catalog_wallpaper_detail_v2((pg_temp.fixture('prepared')->>'wallpaper_id')::uuid)#>>'{media,kind}','still','detail is typed still');
select ok(not ((public.catalog_wallpaper_detail_v2((pg_temp.fixture('prepared')->>'wallpaper_id')::uuid)->'media') ?| array['duration_ms','frame_rate_numerator','frame_rate_denominator']),'still detail omits video timing');
select is(public.catalog_wallpaper_detail_v2((pg_temp.fixture('prepared')->>'wallpaper_id')::uuid)#>>'{media,artifact,role}','image_default','detail carries real image artifact');
select is((select preview from public.catalog_wallpapers_v2 where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid),null::jsonb,'still summary preview is null');
select throws_ok($$select public.catalog_wallpaper_detail_v1((pg_temp.fixture('prepared')->>'wallpaper_id')::uuid)$$,'P0001','WALI_WALLPAPER_NOT_FOUND','V1 detail refuses images');
select throws_ok($$select public.wali_edge_request_install_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'still_v1_install_01',(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid,(pg_temp.fixture('prepared')->>'release_id')::uuid,(select revision from wali.wallpapers where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid))$$,'P0001','WALI_WALLPAPER_NOT_FOUND','V1 install cannot grant an image manifest');
insert into auto_fixture values('install',public.wali_edge_request_install_v2('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'still_v2_install_01',(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid,(pg_temp.fixture('prepared')->>'release_id')::uuid,(select revision from wali.wallpapers where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid)));
select is(pg_temp.fixture('install')->>'media_kind','still','V2 install grant binds kind');
select is((select count(*) from wali.install_receipts where id=(pg_temp.fixture('install')->>'install_receipt')::uuid),1::bigint,'V2 install uses existing receipt authority');
select is(public.wali_edge_request_install_v2('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'still_v2_install_01',(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid,(pg_temp.fixture('prepared')->>'release_id')::uuid,(select revision from wali.wallpapers where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid))-'replayed',pg_temp.fixture('install'),'V2 idempotent grant does not duplicate receipt');
select lives_ok($$select public.record_install_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'still_record_install_01',(pg_temp.fixture('install')->>'install_receipt')::uuid,(pg_temp.fixture('prepared')->>'release_id')::uuid,(select manifest_digest from wali.wallpaper_releases where id=(pg_temp.fixture('prepared')->>'release_id')::uuid),'verified_installed')$$,'media-neutral V1 record-install accepts real V2 receipt');
select is((select verified_install_count from public.catalog_wallpapers_v2 where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid),1::bigint,'still completed install increments durable public total');
insert into wali.saved_wallpapers(user_id,wallpaper_id,active) values('00000000-0000-0000-0000-000000000003',(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid,true);
insert into wali.favorites(user_id,wallpaper_id,active) values('00000000-0000-0000-0000-000000000003',(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid,true);
grant select on auto_fixture to anon,authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
set local role authenticated;
select is((select count(*) from public.my_saved_wallpapers_v2 where wallpaper->>'id'=pg_temp.fixture('prepared')->>'wallpaper_id'),1::bigint,'owner Saved V2 includes still');
select is((select count(*) from public.my_saved_wallpapers_v1 where wallpaper->>'id'=pg_temp.fixture('prepared')->>'wallpaper_id'),0::bigint,'owner Saved V1 excludes still');
select is((select count(*) from public.my_favorites_v2 where wallpaper->>'id'=pg_temp.fixture('prepared')->>'wallpaper_id'),1::bigint,'Favorites V2 includes still');
reset role;
set local role anon;
select is(public.catalog_browse_v2(null,null,'newest',null,1)#>>'{items,0,media_kind}','still','V2 pages newest image first');
select is(public.catalog_browse_v1(null,null,'newest',null,1)#>>'{items,0,media_kind}',null::text,'V1 keeps original summary shape');
select isnt(public.catalog_browse_v1(null,null,'newest',null,1)#>>'{items,0,id}',pg_temp.fixture('prepared')->>'wallpaper_id','V1 excludes image before limit');
select is(public.catalog_search_v2('Actual','{}',null,24)#>>'{items,0,media_kind}','still','V2 search finds still');
select is(jsonb_array_length(public.catalog_search_v1('Actual','{}',null,24)->'items'),0,'V1 search excludes image');
select is(jsonb_array_length(public.catalog_search_v2('Actual','{"minimum_duration_ms":1}',null,24)->'items'),0,'duration filters do not invent image timing');
select ok(exists(select 1 from jsonb_array_elements(public.catalog_home_v2('en','mature')->'sections') section, jsonb_array_elements(section->'items') item where item->>'id'=pg_temp.fixture('prepared')->>'wallpaper_id'),'anonymous V2 Home includes still with stale subject safely');
select ok(not exists(select 1 from jsonb_array_elements(public.catalog_home_v1('en','mature')->'sections') section, jsonb_array_elements(section->'items') item where item->>'id'=pg_temp.fixture('prepared')->>'wallpaper_id'),'all V1 Home sections omit still');
select throws_ok($$select public.catalog_browse_v1(null,null,'newest',public.catalog_browse_v2(null,null,'newest',null,1)->>'next_cursor',1)$$,'P0001','WALI_CURSOR_INVALID','V2 cursor cannot enter V1 pagination');
reset role;
insert into wali.user_preferences(user_id,rating_ceiling) values('00000000-0000-0000-0000-000000000003','everyone') on conflict(user_id) do update set rating_ceiling='everyone';
update wali.wallpapers set content_rating='teen' where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid;
set local role authenticated;
select is((select count(*) from public.catalog_wallpapers_v2 where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid),0::bigint,'V2 respects actual viewer rating preference');
reset role;
select throws_ok($$select public.wali_edge_request_install_v2('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'still_rating_install_01',(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid,(pg_temp.fixture('prepared')->>'release_id')::uuid,(select revision from wali.wallpapers where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid))$$,'P0001','WALI_WALLPAPER_NOT_FOUND','service install checks actual actor rating without impersonated JWT');
update wali.wallpapers set content_rating='everyone' where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid;
insert into auto_fixture values('retry_upload',public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'still_retry_upload_01',4096,'image/jpeg','retry.jpg','new',null,null));
insert into storage.objects(bucket_id,name,owner_id,version,metadata) values('uploads-private',pg_temp.fixture('retry_upload')->>'storage_path','00000000-0000-0000-0000-000000000003','still-retry-source','{"size":4096,"mimetype":"image/jpeg"}');
insert into auto_fixture values('retry_submission',public.wali_edge_complete_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'still_retry_complete_01',(pg_temp.fixture('retry_upload')->>'upload_session_id')::uuid,1,pg_temp.fixture('draft')));
insert into auto_fixture values('retry_attempt',to_jsonb((select id from wali.processing_attempts where submission_id=(pg_temp.fixture('retry_submission')->>'submission_id')::uuid)));
select is(wali.worker_begin_still_attempt_v2((pg_temp.fixture('retry_attempt')#>>'{}')::uuid,(pg_temp.fixture('retry_submission')->>'submission_id')::uuid,1,'still-retry-worker',statement_timestamp()+interval '4 minutes'),'started','still failed-generation fixture begins through versioned seam');
select ok(wali.worker_fail_attempt((pg_temp.fixture('retry_attempt')#>>'{}')::uuid,1,'still-retry-worker','WALI_PROCESSING_TIMEOUT'),'existing bounded failure writer terminates still generation');
insert into auto_fixture values('retried',public.wali_edge_retry_processing_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'still_owner_retry_01',(pg_temp.fixture('retry_submission')->>'submission_id')::uuid,(select revision from wali.submissions where id=(pg_temp.fixture('retry_submission')->>'submission_id')::uuid)));
select is(pg_temp.fixture('retried')->>'generation','2','owner retry starts a new still generation');
select is((select message->>'media_kind' from pgmq.q_wali_media_processing where message->>'submission_id'=pg_temp.fixture('retried')->>'submission_id' and message->>'generation'='2'),'still','retried queue payload preserves actual media kind');
select is((select message->>'schema_version' from pgmq.q_wali_media_processing where message->>'submission_id'=pg_temp.fixture('retried')->>'submission_id' and message->>'generation'='2'),'2','retried still remains schema2');
select is((select status::text from wali.processing_attempts where id=(pg_temp.fixture('retry_attempt')#>>'{}')::uuid),'failed','old attempt remains terminal');
select is(wali.worker_begin_still_attempt_v2((select id from wali.processing_attempts where submission_id=(pg_temp.fixture('retried')->>'submission_id')::uuid and generation=2),(pg_temp.fixture('retried')->>'submission_id')::uuid,2,'still-dedup-worker',statement_timestamp()+interval '4 minutes'),'started','later still generation begins with existing canonical bytes');
do $$declare a jsonb; attempt_id uuid:=(select id from wali.processing_attempts where submission_id=(pg_temp.fixture('retried')->>'submission_id')::uuid and generation=2); begin
 for a in select claim from auto_artifacts loop
  if not wali.worker_authorize_still_artifact_v2(attempt_id,2,'still-dedup-worker',a) then raise exception 'fixture authorization failed'; end if;
 end loop;
end $$;
select ok(wali.worker_complete_still_attempt_v2((select id from wali.processing_attempts where submission_id=(pg_temp.fixture('retried')->>'submission_id')::uuid and generation=2),2,'still-dedup-worker',pg_temp.fixture('worker_completion')),'later still generation independently verifies globally deduplicated bytes');
select is(wali.creator_processing_projection((pg_temp.fixture('retried')->>'submission_id')::uuid,2)#>>'{media_facts,media_kind}','still','reuploaded identical bytes retain current Creator media facts');
select is(jsonb_array_length(wali.creator_processing_projection((pg_temp.fixture('retried')->>'submission_id')::uuid,2)->'generated_variants'),3,'reuploaded identical bytes retain current three variants');
select * from finish();
rollback;
