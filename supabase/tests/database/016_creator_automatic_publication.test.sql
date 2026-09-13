-- Rollback-only local database fixtures. Synthetic object metadata and signature
-- bytes test database invariants; they are not real media/cryptographic evidence.
begin;
select no_plan();
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
select is(wali.worker_begin_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,(pg_temp.fixture('complete1')->>'submission_id')::uuid,1,'auto-fixture-worker',statement_timestamp()+interval '4 minutes'),'started','real processing RPC leases fixture');

create temporary table auto_artifacts (claim jsonb not null);
insert into auto_artifacts values
 ('{"role":"thumbnail","digest":"1111111111111111111111111111111111111111111111111111111111111f01","byte_count":1024,"media_type":"image/jpeg","width":512,"height":512,"duration_ms":0,"frame_rate_numerator":0,"frame_rate_denominator":0,"codec":"jpeg","pixel_format":"yuvj420p","color_space":"sRGB","has_audio":false}'),
 ('{"role":"poster","digest":"2222222222222222222222222222222222222222222222222222222222222f02","byte_count":2048,"media_type":"image/jpeg","width":1920,"height":1080,"duration_ms":0,"frame_rate_numerator":0,"frame_rate_denominator":0,"codec":"jpeg","pixel_format":"yuvj420p","color_space":"sRGB","has_audio":false}'),
 ('{"role":"preview","digest":"3333333333333333333333333333333333333333333333333333333333333f03","byte_count":4096,"media_type":"video/mp4","width":960,"height":540,"duration_ms":5000,"frame_rate_numerator":30,"frame_rate_denominator":1,"codec":"hevc","pixel_format":"yuv420p10le","color_space":"bt709","has_audio":false}'),
 ('{"role":"video_default","digest":"4444444444444444444444444444444444444444444444444444444444444f04","byte_count":8192,"media_type":"video/mp4","width":3840,"height":2160,"duration_ms":30000,"frame_rate_numerator":60,"frame_rate_denominator":1,"codec":"hevc","pixel_format":"yuv420p10le","color_space":"bt709","has_audio":false}');
do $$declare a jsonb; path text;
begin
 for a in select claim from auto_artifacts loop
  if not wali.worker_authorize_staged_artifact((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'auto-fixture-worker',a)
   then raise exception 'automatic fixture staged authorization failed'; end if;
  path:='sha256/'||substring(a->>'digest' from 1 for 2)||'/'||substring(a->>'digest' from 3 for 2)||'/'||
   (a->>'digest')||'/'||replace(a->>'role','_','-')||case a->>'media_type' when 'image/jpeg' then '.jpg' else '.mp4' end;
  insert into storage.objects (bucket_id,name,metadata) values ('processing-private',path,
   jsonb_build_object('mimetype',a->>'media_type','size',(a->>'byte_count')::bigint));
 end loop;
end $$;
insert into auto_fixture values ('worker_completion',jsonb_build_object('source_digest',repeat('d',64),
 'artifacts',(select jsonb_agg(claim order by claim->>'role') from auto_artifacts),
 'classification','{"available":false,"safe_code":"classifier_unavailable","model_id":"","model_revision":"","model_digest":"","taxonomy_revision":"","input_frame_set_digest":"","categories":[],"tags":[],"visual_embedding":[],"text_embedding":[],"combined_embedding":[]}'::jsonb));
select ok(wali.worker_complete_attempt((pg_temp.fixture('attempt1')#>>'{}')::uuid,1,'auto-fixture-worker',
 pg_temp.fixture('worker_completion')),'four observed staged artifacts complete the real database processing transaction');
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
select is(wali.worker_begin_promotion((pg_temp.fixture('promotion')->>'promotion_id')::uuid,'auto-fixture-worker',statement_timestamp()+interval '4 minutes')->>'disposition','started','worker promotion uses existing lease');
insert into storage.objects(bucket_id,name,metadata)
select 'catalog-public',a.storage_path,jsonb_build_object('mimetype',a.media_type,'size',a.byte_count)
 from wali.staged_artifacts a where a.verified_by_attempt_id=(pg_temp.fixture('attempt1')#>>'{}')::uuid;
select ok(wali.worker_complete_promotion((pg_temp.fixture('promotion')->>'promotion_id')::uuid,'auto-fixture-worker',(select jsonb_agg(claim) from auto_artifacts)),'promotion verifies all immutable object claims');
insert into auto_fixture values('prepared',pg_temp.prepare_auto());
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
 manifest:=convert_to(jsonb_build_object('wallpaper_id',p->>'wallpaper_id','release_id',p->>'release_id',
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
select is((select count(*) from public.catalog_wallpapers_v1 where id=(pg_temp.fixture('prepared')->>'wallpaper_id')::uuid),1::bigint,'new release is publicly visible');
select is(pg_temp.prepare_auto()->'response',pg_temp.fixture('published'),'lost final response replays immutable publication');
select ok(public.wali_edge_finish_automatic_publication_v1((pg_temp.fixture('job')->>'id')::uuid,(pg_temp.fixture('job')->>'lease_token')::uuid,'completed',null),'only committed publication completes the job');
select is((select status from wali.automatic_publication_jobs),'completed','durable job ends once');
select is((select count(*) from wali.moderation_reviews where submission_id=(pg_temp.fixture('complete1')->>'submission_id')::uuid),0::bigint,'publication never fabricates a human review');

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
select is((select entry->>'requires_proof' from jsonb_array_elements(public.creator_metadata_v1()->'rights_bases') entry where entry->>'basis'='licensed'),'false','licensed metadata does not require fictional private proof');
select is((select entry->>'available' from jsonb_array_elements(public.creator_metadata_v1()->'rights_bases') entry where entry->>'basis'='licensed'),'true','licensed upload is an available actual attestation');
select is((select entry->>'terms_url' from jsonb_array_elements(public.creator_metadata_v1()->'licenses') entry where entry->>'id'='20000000-0000-0000-0000-000000000001'),(select terms_url from wali.licenses where id='20000000-0000-0000-0000-000000000001'),'license terms are available before attestation');
do $$begin
 for n in 2..24 loop
  perform public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'auto_daily_quota_'||lpad(n::text,4,'0'),4096,'video/mp4','quota-'||n||'.mp4','new',null,null);
 end loop;
end $$;
select is((select count(*) from wali.upload_sessions where creator_id='00000000-0000-0000-0000-000000000003' and admission_kind='creator'),24::bigint,'24 durable new reservations are admitted');
select throws_ok($$select public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'auto_daily_quota_0025',4096,'video/mp4','quota-25.mp4','new',null,null)$$,'P0001','WALI_UPLOAD_DAILY_QUOTA_EXCEEDED','25th new reservation is refused');
select is(public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'auto_upload_new_01',4096,'video/mp4','source.mp4','new',null,null)->>'upload_session_id',pg_temp.fixture('upload1')->>'upload_session_id','idempotent replay does not consume daily quota');
do $$declare u wali.upload_sessions%rowtype; begin
 for u in select * from wali.upload_sessions where creator_id='00000000-0000-0000-0000-000000000003' and original_filename in ('quota-2.mp4','quota-3.mp4') loop
  insert into storage.objects(bucket_id,name,owner_id,version,metadata) values('uploads-private',u.storage_path,u.creator_id::text,'auto-capacity-raw','{"size":4096,"mimetype":"video/mp4"}');
  perform public.wali_edge_complete_upload_v1(u.creator_id,gen_random_uuid(),'auto_capacity_'||replace(u.id::text,'-',''),u.id,u.revision,pg_temp.fixture('draft'));
 end loop;
end $$;
select is((select count(*) from wali.submissions where creator_id='00000000-0000-0000-0000-000000000003' and status='processing'),2::bigint,'concurrent processing limit remains two');
select is(public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'auto_upload_new_01',4096,'video/mp4','source.mp4','new',null,null)->>'upload_session_id',pg_temp.fixture('upload1')->>'upload_session_id','replay remains possible under full processing capacity');
select throws_ok($$select public.wali_edge_create_upload_v1('00000000-0000-0000-0000-000000000003',gen_random_uuid(),'auto_capacity_extra_01',4096,'video/mp4','extra.mp4','new',null,null)$$,'P0001','WALI_PROCESSING_CAPACITY_UNAVAILABLE','backpressure is preserved for new work');
select * from finish();
rollback;
