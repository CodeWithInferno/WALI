begin;
select plan(44);

select has_function('public','catalog_preferences_v1',array[]::text[],'owner preference read exists');
select has_function('public','set_catalog_preferences_v1',array['uuid[]','text','boolean','bigint','text'],'revision-bound preference writer exists');
select ok(not has_function_privilege('anon','public.catalog_preferences_v1()','execute'),'anonymous cannot read preferences');
select ok(not has_function_privilege('anon','public.set_catalog_preferences_v1(uuid[],text,boolean,bigint,text)','execute'),'anonymous cannot write preferences');
select is((select count(*) from wali.catalog_public_counts('ffffffff-ffff-ffff-ffff-ffffffffffff')),0::bigint,'unknown/private item reveals no aggregates');

-- Independent count fixtures: requests, active toggles and actual one-use record
-- commands. The author's successful installation must count without ranking.
insert into wali.install_receipts(id,user_id,release_id,request_id) values
('92000000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000001','92000000-0000-4000-8000-000000000002');
select is((select verified_install_count from public.catalog_wallpapers_v1 where id='30000000-0000-0000-0000-000000000001'),0::bigint,'an issued grant does not count as a download');
select set_config('request.jwt.claim.role','service_role',true);
select lives_ok($$select public.record_install_v1('00000000-0000-0000-0000-000000000002','92000000-0000-4000-8000-000000000003','catalog_count_complete_00001','92000000-0000-4000-8000-000000000001','40000000-0000-0000-0000-000000000001',(select manifest_digest from wali.wallpaper_releases where id='40000000-0000-0000-0000-000000000001'),'verified_installed')$$,'publisher can acknowledge their actual completed installation');
select is((select verified_install_count from public.catalog_wallpapers_v1 where id='30000000-0000-0000-0000-000000000001'),1::bigint,'completion appears immediately without hourly ranking refresh');
select lives_ok($$select public.record_install_v1('00000000-0000-0000-0000-000000000002','92000000-0000-4000-8000-000000000004','catalog_count_complete_00001','92000000-0000-4000-8000-000000000001','40000000-0000-0000-0000-000000000001',(select manifest_digest from wali.wallpaper_releases where id='40000000-0000-0000-0000-000000000001'),'verified_installed')$$,'lost response retries original acknowledgement');
select is((select verified_install_count from public.catalog_wallpapers_v1 where id='30000000-0000-0000-0000-000000000001'),1::bigint,'acknowledgement replay never duplicates count');
select ok((select not contributes_to_ranking from wali.engagement_events where install_receipt_id='92000000-0000-4000-8000-000000000001'),'publisher install still does not inflate ranking');

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select is(public.catalog_preferences_v1()->>'user_id','00000000-0000-0000-0000-000000000003','read is bound to actual subject');
select is(public.catalog_preferences_v1()->'category_ids','[]'::jsonb,'interests start empty');
create temporary table preference_result as select public.set_catalog_preferences_v1(array[(select id from wali.categories where slug='space')],'teen',false,1,'catalog_preferences_test_001') body;
select is((select body->>'revision' from preference_result),'2','first write increments exactly once');
select is(public.set_catalog_preferences_v1(array[(select id from wali.categories where slug='space')],'teen',false,1,'catalog_preferences_test_001') - 'replayed',(select body from preference_result),'lost preference response replays exact revision');
select throws_ok($$select public.set_catalog_preferences_v1('{}','everyone',false,1,'catalog_preferences_test_002')$$,'P0001','WALI_REVISION_MISMATCH','stale writer cannot overwrite newer interests');
select throws_ok($$select public.set_catalog_preferences_v1('{}','everyone',false,1,'catalog_preferences_test_001')$$,'P0001','WALI_IDEMPOTENCY_CONFLICT','same preference key cannot change payload');
select throws_ok($$select public.set_catalog_preferences_v1(array[(select id from wali.categories where slug='space'),(select id from wali.categories where slug='space')],'teen',false,2,'catalog_preferences_test_003')$$,'P0001','WALI_FILTER_INVALID','duplicate interests are rejected');
select throws_ok($$select public.set_catalog_preferences_v1(array['ffffffff-ffff-ffff-ffff-ffffffffffff']::uuid[],'teen',false,2,'catalog_preferences_test_004')$$,'P0001','WALI_FILTER_INVALID','unknown interests are rejected');
select is((select jsonb_array_length(section->'items') from jsonb_array_elements(public.catalog_home_v1('en-US','mature')->'sections') section where section->>'kind'='for_you'),1,'explicit interest produces matching suggestions');
select ok(not exists(select 1 from jsonb_array_elements(public.catalog_home_v1('en-US','mature')->'sections') section cross join lateral jsonb_array_elements(section->'items') item where section->>'kind'='for_you' and item->'primary_category'->>'id'<>(select id::text from wali.categories where slug='space')),'explicit categories strictly constrain For You');
select lives_ok($$select public.set_saved_v1('30000000-0000-0000-0000-000000000001',true,0,'catalog_save_test_00001')$$,'owner can save wallpaper');
select is((select save_count from public.catalog_wallpapers_v1 where id='30000000-0000-0000-0000-000000000001'),1::bigint,'active save is immediately public');
select is(jsonb_array_length(public.my_saved_wallpapers_v1(null,24)->'items'),1,'saved Library reader persists owner bookmark');
select lives_ok($$select public.set_catalog_preferences_v1('{}','teen',false,2,'catalog_preferences_test_006')$$,'clearing explicit choices permits existing-save affinity');
select is((select section->'items'->0->>'id' from jsonb_array_elements(public.catalog_home_v1('en-US','teen')->'sections') section where section->>'kind'='for_you'),'30000000-0000-0000-0000-000000000001','active saved category supplies fallback affinity');
select lives_ok($$select public.set_saved_v1('30000000-0000-0000-0000-000000000001',false,1,'catalog_save_test_00002')$$,'owner can remove saved bookmark');
select is((select save_count from public.catalog_wallpapers_v1 where id='30000000-0000-0000-0000-000000000001'),0::bigint,'removal reduces active count without waiting');
select ok(not exists(select 1 from jsonb_array_elements(public.catalog_home_v1('en-US','teen')->'sections') section where section->>'kind'='for_you'),'removed bookmarks no longer supply affinity');
select lives_ok($$select public.set_catalog_preferences_v1('{}','teen',true,3,'catalog_preferences_test_005')$$,'owner can opt out');
select ok(not exists(select 1 from jsonb_array_elements(public.catalog_home_v1('en-US','teen')->'sections') section where section->>'kind'='for_you'),'opt out removes personal section');
reset role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000006',true);
select set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000006","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select is(public.catalog_preferences_v1()->'category_ids','[]'::jsonb,'another subject never receives previous preferences');
select is(jsonb_array_length(public.my_saved_wallpapers_v1(null,24)->'items'),0,'another subject never receives previous saved Library');
reset role;
-- Make New deliberately disagree with Trending; no duplicate newest query.
update wali.wallpapers set published_at=statement_timestamp()-interval '2 days' where id='30000000-0000-0000-0000-000000000001';
update wali.wallpapers set published_at=statement_timestamp()-interval '1 day' where id='30000000-0000-0000-0000-000000000002';
insert into wali.ranking_snapshots(surface,formula_version,wallpaper_id,score,ordinal,feature_inputs,generated_at,expires_at) values
('trending','trending-v1','30000000-0000-0000-0000-000000000001',100,1,'{}',statement_timestamp(),statement_timestamp()+interval '1 hour'),
('trending','trending-v1','30000000-0000-0000-0000-000000000002',1,2,'{}',statement_timestamp(),statement_timestamp()+interval '1 hour');
select is((select section->'items'->0->>'id' from jsonb_array_elements(public.catalog_home_v1('en-US','teen')->'sections') section where section->>'kind'='trending'),'30000000-0000-0000-0000-000000000001','Trending follows ranking score');
select is((select section->'items'->0->>'id' from jsonb_array_elements(public.catalog_home_v1('en-US','teen')->'sections') section where section->>'kind'='new'),'30000000-0000-0000-0000-000000000002','New follows publication order');
update wali.wallpapers set search_document=to_tsvector('simple','shared') where id in ('30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002');
select is(public.catalog_search_v1('shared','{"sort":"trending"}',null,24)->'items'->0->>'id','30000000-0000-0000-0000-000000000001','search preserves requested trending order');
select is(public.catalog_search_v1('shared','{"sort":"newest"}',null,24)->'items'->0->>'id','30000000-0000-0000-0000-000000000002','search preserves requested newest order');
create temporary table browse_page as select public.catalog_browse_v1(null,'{}','newest',null,1) body;
select throws_ok($$select public.catalog_browse_v1('nature','{}','newest',(select body->>'next_cursor' from browse_page),1)$$,'P0001','WALI_CURSOR_INVALID','cursor cannot cross selected category');
update wali.wallpapers set content_rating='mature' where id='30000000-0000-0000-0000-000000000002';
select is(jsonb_array_length(public.catalog_browse_v1(null,'{}','newest',null,24)->'items'),1,'Browse applies stored rating ceiling');
select is(jsonb_array_length(public.catalog_search_v1('shared','{"category_slug":"space","content_rating_ceiling":"mature","sort":"newest"}',null,24)->'items'),0,'search cannot widen stored rating ceiling');
-- Real lease-gated export: two owners have evidence, only one is exported.
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
insert into wali.automatic_publication_decisions(id,submission_id,generation,submission_revision,attempt_id,policy_version,submission_snapshot,rights_snapshot,artifact_set_digest) values
('93000000-0000-4000-8000-000000000001','71000000-0000-0000-0000-000000000001',1,1,'72000000-0000-0000-0000-000000000001','automatic-publication-2026-09-12','{"title":"Owner content","rights":{"proof_storage_path":"never-export"}}','{"rights_holder":"Owner","proof_storage_path":"never-export","proof_object_ids":["private-proof-reference"]}',repeat('a',64)),
('93000000-0000-4000-8000-000000000002','71000000-0000-0000-0000-000000000002',1,1,'72000000-0000-0000-0000-000000000002','automatic-publication-2026-09-12','{"title":"Other owner"}','{"rights_holder":"Other owner"}',repeat('b',64));
insert into wali.automatic_publication_jobs(id,submission_id,generation,status,attempts,lease_token,lease_expires_at) values
('93000000-0000-4000-8000-000000000003','71000000-0000-0000-0000-000000000001',1,'leased',1,'93000000-0000-4000-8000-000000000005',statement_timestamp()+interval '5 minutes'),
('93000000-0000-4000-8000-000000000004','71000000-0000-0000-0000-000000000002',1,'queued',0,null,null);
update wali.user_preferences set category_ids=array[(select id from wali.categories where slug='space')] where user_id='00000000-0000-0000-0000-000000000002';
create temporary table catalog_export_request as select public.wali_edge_request_account_export_v1(
  '00000000-0000-0000-0000-000000000002','93000000-0000-4000-8000-000000000006','catalog_export_owner_00001') body;
select wali.worker_begin_export((select body->>'export_id' from catalog_export_request)::uuid,
  '00000000-0000-0000-0000-000000000002','catalog-export-test',statement_timestamp()+interval '5 minutes');
create temporary table catalog_export_body as select wali.worker_read_account_export((select body->>'export_id' from catalog_export_request)::uuid,
  '00000000-0000-0000-0000-000000000002','catalog-export-test') body;
select ok((select jsonb_array_length(body->'submissions')=1 and
  body->'submissions'->0->'automatic_publication_decisions'->0->>'id'='93000000-0000-4000-8000-000000000001'
  and body::text not like '%93000000-0000-4000-8000-000000000002%' from catalog_export_body),'export includes only its owner publication decisions');
select ok((select jsonb_array_length(body->'submissions'->0->'automatic_publication_jobs')=1 and
  body->'submissions'->0->'automatic_publication_jobs'->0->>'id'='93000000-0000-4000-8000-000000000003' from catalog_export_body),'export includes only its owner publication job');
select ok((select body::text not like '%lease_token%' and body::text not like '%lease_expires_at%' and body::text not like '%proof_storage_path%'
  and body::text not like '%private-proof-reference%' and body::text not like '%never-export%' from catalog_export_body),'export excludes private leases and proof paths even from immutable snapshots');
select is((select body->'preferences'->'category_ids' from catalog_export_body),jsonb_build_array((select id from wali.categories where slug='space')),'export includes explicit category preferences');

select * from finish();
rollback;
