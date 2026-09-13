begin;
set local search_path=public,extensions;
select no_plan();
select has_table('wali','creator_blocks','private relation exists');
select has_function('public','set_creator_block_v1',array['uuid','boolean','bigint','text'],'block mutation interface');
create temporary table blocking_receipts(name text primary key,payload jsonb);
grant all on blocking_receipts to authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.aal','aal1',true);
set local role authenticated;
select is((select count(*) from public.catalog_wallpapers_v1),2::bigint,'baseline V1 visible');
select is((select count(*) from public.catalog_wallpapers_v2),2::bigint,'baseline V2 visible');
select lives_ok($$select public.set_saved_v1('30000000-0000-0000-0000-000000000001',true,0,'block_save_before_01')$$,'save before block');
select lives_ok($$select public.set_favorite_v1('30000000-0000-0000-0000-000000000001',true,0,'block_favorite_before_01')$$,'favorite before block');
select lives_ok($$select public.set_creator_follow_v1('00000000-0000-0000-0000-000000000002',true,0,'block_follow_before_01')$$,'follow before block');
insert into blocking_receipts values('block',public.set_creator_block_v1('00000000-0000-0000-0000-000000000002',true,0,'creator_block_regression_01'));
select is((select payload->>'generation' from blocking_receipts where name='block'),'1','effective block advances generation');
select is(public.set_creator_block_v1('00000000-0000-0000-0000-000000000002',true,0,'creator_block_regression_01')-'replayed',(select payload from blocking_receipts where name='block'),'identical replay is stable');
select throws_ok($$select public.set_creator_block_v1('00000000-0000-0000-0000-000000000002',false,1,'creator_block_regression_01')$$,'P0001','WALI_IDEMPOTENCY_CONFLICT','changed replay rejected');
select is(public.set_creator_block_v1('00000000-0000-0000-0000-000000000002',true,1,'creator_block_noop_0001')->>'generation','1','unchanged state preserves generation');
select is((select count(*) from public.catalog_wallpapers_v1),1::bigint,'V1 hides blocked creator');
select is((select count(*) from public.catalog_wallpapers_v2),1::bigint,'V2 hides blocked creator');
select throws_ok($$select public.catalog_wallpaper_detail_v1('30000000-0000-0000-0000-000000000001')$$,'P0001','WALI_WALLPAPER_NOT_FOUND','direct V1 detail cannot bypass');
select throws_ok($$select public.catalog_wallpaper_detail_v2('30000000-0000-0000-0000-000000000001')$$,'P0001','WALI_WALLPAPER_NOT_FOUND','direct V2 detail cannot bypass');
select is(jsonb_array_length(public.catalog_browse_v1(null,null,'newest',null,24)->'items'),1,'V1 browse filters before paging');
select is(jsonb_array_length(public.catalog_browse_v2(null,null,'newest',null,24)->'items'),1,'V2 browse filters before paging');
select ok(public.catalog_home_v1('en','mature')::text not like '%30000000-0000-0000-0000-000000000001%','V1 home hides blocked item');
select ok(public.catalog_home_v2('en','mature')::text not like '%30000000-0000-0000-0000-000000000001%','V2 home hides blocked item');
select is((select count(*) from public.catalog_creators_v1 where id='00000000-0000-0000-0000-000000000002'),0::bigint,'creator profile hidden');
select ok((select jsonb_agg(to_jsonb(c))::text from public.catalog_collections_v1 c) not like '%30000000-0000-0000-0000-000000000001%','collection membership hidden');
select is((select count(*) from public.my_saved_wallpapers_v1),0::bigint,'saved V1 hidden');
select is((select count(*) from public.my_saved_wallpapers_v2),0::bigint,'saved V2 hidden');
select is((select count(*) from public.my_favorites_v1),0::bigint,'favorite V1 hidden');
select is((select count(*) from public.my_favorites_v2),0::bigint,'favorite V2 hidden');
select throws_ok($$select public.set_saved_v1('30000000-0000-0000-0000-000000000001',true,1,'blocked_save_new_0001')$$,'P0001','WALI_CREATOR_BLOCKED','new positive save rejected');
select throws_ok($$select public.set_favorite_v1('30000000-0000-0000-0000-000000000001',true,1,'blocked_favorite_0001')$$,'P0001','WALI_CREATOR_BLOCKED','new positive favorite rejected');
select throws_ok($$select public.set_creator_follow_v1('00000000-0000-0000-0000-000000000002',true,1,'blocked_follow_new_01')$$,'P0001','WALI_CREATOR_BLOCKED','new positive follow rejected');
select is(jsonb_array_length(public.my_hidden_interactions_v1(null,100)->'items'),3,'hidden cleanup survives without detail');
select ok(public.my_hidden_interactions_v1(null,100)::text not like '%url%','hidden cleanup exposes no media');
select lives_ok($$select public.set_saved_v1('30000000-0000-0000-0000-000000000001',false,1,'blocked_unsave_000001')$$,'hidden save can be removed');
select lives_ok($$select public.set_favorite_v1('30000000-0000-0000-0000-000000000001',false,1,'blocked_unfavorite01')$$,'hidden favorite can be removed');
select lives_ok($$select public.set_creator_follow_v1('00000000-0000-0000-0000-000000000002',false,1,'blocked_unfollow_001')$$,'hidden follow can be removed');
select is(jsonb_array_length(public.my_hidden_interactions_v1(null,100)->'items'),0,'removed interactions disappear from cleanup');
select throws_ok($$insert into wali.creator_blocks(user_id,creator_id,active,revision) values('00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000006',true,1)$$,'42501',null,'direct block writes denied');
select throws_ok($$select * from wali.creator_block_preferences$$,'42501',null,'generation only through RPC');
select throws_ok($$select public.set_creator_block_v1(null,true,0,'blocked_null_id_0001')$$,'P0001','WALI_REQUEST_INVALID','null target rejected');
select throws_ok($$select public.set_creator_block_v1('00000000-0000-0000-0000-000000000006',null,0,'blocked_null_bool_01')$$,'P0001','WALI_REQUEST_INVALID','null desired rejected');
select throws_ok($$select public.set_creator_block_v1('00000000-0000-0000-0000-000000000003',true,0,'blocked_self_000001')$$,'P0001','WALI_REQUEST_INVALID','self rejected');
select throws_ok($$select public.my_creator_blocks_v1(null,101)$$,'P0001','WALI_REQUEST_INVALID','page hard bound');
select throws_ok($$select public.my_creator_blocks_v1('bad!',1)$$,'P0001','WALI_CURSOR_INVALID','malformed cursor rejected');
insert into blocking_receipts values('first_page',public.my_creator_blocks_v1(null,1));
select lives_ok($$select public.my_creator_blocks_v1((select payload->>'next_cursor' from blocking_receipts where name='first_page'),1)$$,'own generated cursor can be read');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000006',true);
select is((select count(*) from wali.creator_blocks),0::bigint,'creator cannot see incoming block');
select is(jsonb_array_length(public.my_creator_blocks_v1(null,100)->'items'),0,'other account list is separate');
select is((select count(*) from public.catalog_wallpapers_v1),2::bigint,'other viewer catalog unaffected');
select throws_ok($$select public.my_creator_blocks_v1((select payload->>'next_cursor' from blocking_receipts where name='first_page'),1)$$,'P0001','WALI_CURSOR_INVALID','cross-subject cursor rejected');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
select lives_ok($$select public.set_creator_block_v1('00000000-0000-0000-0000-000000000006',true,0,'creator_second_00001')$$,'another public creator can be blocked');
select throws_ok($$select public.my_creator_blocks_v1((select payload->>'next_cursor' from blocking_receipts where name='first_page'),1)$$,'P0001','WALI_CURSOR_INVALID','changed generation invalidates cursor');
select lives_ok($$select public.set_creator_block_v1('00000000-0000-0000-0000-000000000002',false,1,'creator_unblock_0001')$$,'unblock uses known revision');
select throws_ok($$select public.set_creator_block_v1('00000000-0000-0000-0000-000000000002',true,0,'creator_delayed_0001')$$,'P0001','WALI_REVISION_MISMATCH','tombstone rejects delayed revision zero');
select is((select revision from wali.creator_blocks where creator_id='00000000-0000-0000-0000-000000000002'),2::bigint,'inactive tombstone retained');
select is(public.my_creator_blocks_v1(null,1,'00000000-0000-0000-0000-000000000002')->'items'->0->>'revision','2','exact outgoing lookup recovers inactive revision after relaunch');
select is(public.my_creator_blocks_v1(null,1,'00000000-0000-0000-0000-000000000002')->'items'->0->>'active','false','exact lookup preserves tombstone state');
reset role;
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claim.role','anon',true);
set local role anon;
select is((select count(*) from public.catalog_wallpapers_v1),2::bigint,'anonymous catalog unchanged');
select throws_ok($$select * from wali.creator_blocks$$,'42501',null,'anonymous cannot read private blocks');
select throws_ok($$select public.my_creator_blocks_v1(null,10)$$,'42501',null,'anonymous cannot call account block RPC');
reset role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select lives_ok($$select public.set_creator_block_v1('00000000-0000-0000-0000-000000000006',false,1,'grant_before_unblock_01')$$,'prepare unblocked grant target');
reset role;
select set_config('request.jwt.claim.role','service_role',true);
insert into blocking_receipts values('grant',public.wali_edge_request_install_v1(
 '00000000-0000-0000-0000-000000000003','a1000000-0000-4000-8000-000000000001','block_grant_existing_01',
 '30000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000002',
 (select revision from wali.wallpapers where id='30000000-0000-0000-0000-000000000002')));
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select lives_ok($$select public.set_creator_block_v1('00000000-0000-0000-0000-000000000006',true,2,'grant_after_block_001')$$,'block after existing grant');
reset role;
select set_config('request.jwt.claim.role','service_role',true);
select is(public.wali_edge_request_install_v1(
 '00000000-0000-0000-0000-000000000003','a1000000-0000-4000-8000-000000000001','block_grant_existing_01',
 '30000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000002',
 (select revision from wali.wallpapers where id='30000000-0000-0000-0000-000000000002'))-'replayed',
 (select payload from blocking_receipts where name='grant'),'already issued grant replay is retained');
select throws_ok($$select public.wali_edge_request_install_v1(
 '00000000-0000-0000-0000-000000000003','a1000000-0000-4000-8000-000000000002','block_grant_new_v1_01',
 '30000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000002',
 (select revision from wali.wallpapers where id='30000000-0000-0000-0000-000000000002'))$$,
 'P0001','WALI_CREATOR_BLOCKED','new V1 install grant refused');
select throws_ok($$select public.wali_edge_request_install_v2(
 '00000000-0000-0000-0000-000000000003','a1000000-0000-4000-8000-000000000003','block_grant_new_v2_01',
 '30000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000002',
 (select revision from wali.wallpapers where id='30000000-0000-0000-0000-000000000002'))$$,
 'P0001','WALI_CREATOR_BLOCKED','new V2 install grant refused');
select lives_ok($$select public.record_install_v1(
 '00000000-0000-0000-0000-000000000003','a1000000-0000-4000-8000-000000000004','block_record_grant_01',
 (select payload->>'install_receipt' from blocking_receipts where name='grant')::uuid,
 '40000000-0000-0000-0000-000000000002',
 (select manifest_digest from wali.wallpaper_releases where id='40000000-0000-0000-0000-000000000002'),'verified_installed')$$,
 'previous grant can still record its verified local installation');
insert into wali.creator_blocks(user_id,creator_id,active,revision) values
 ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',true,1);
create temporary table block_export_request as select public.wali_edge_request_account_export_v1(
 '00000000-0000-0000-0000-000000000003','a1000000-0000-4000-8000-000000000005','block_export_owner_01') body;
select wali.worker_begin_export((select body->>'export_id' from block_export_request)::uuid,
 '00000000-0000-0000-0000-000000000003','block-export-test',statement_timestamp()+interval '5 minutes');
create temporary table block_export_document as select wali.worker_read_account_export((select body->>'export_id' from block_export_request)::uuid,
 '00000000-0000-0000-0000-000000000003','block-export-test') body;
select is(jsonb_array_length((select body->'creator_blocks' from block_export_document)),2,'export contains outgoing active and inactive relations');
select ok((select body->'creator_blocks' from block_export_document)::text not like '%00000000-0000-0000-0000-000000000003%','export never exposes incoming relationships');
-- At the exact active cap, no choice is evicted and existing unblocks still work.
insert into auth.users(id,aud,role,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)
 select ('80000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'authenticated','authenticated','block-fixture-'||n||'@example.invalid',statement_timestamp(),'{}','{}'
 from generate_series(1,10000) n;
insert into wali.creator_blocks(user_id,creator_id,active,revision)
 select '00000000-0000-0000-0000-000000000001',('80000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,true,1 from generate_series(1,10000) n;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
set local role authenticated;
select throws_ok($$select public.set_creator_block_v1('00000000-0000-0000-0000-000000000002',true,0,'block_limit_new_00001')$$,'P0001','WALI_BLOCK_LIMIT_REACHED','10001st active block refused');
select is((select count(*) from wali.creator_blocks where active),10000::bigint,'cap refusal never evicts');
select lives_ok($$select public.set_creator_block_v1('80000000-0000-0000-0000-000000000001',false,1,'block_limit_unblock01')$$,'unblock remains possible at cap and for nonpublic target');
select is((select count(*) from wali.creator_blocks where active),9999::bigint,'unblock frees one active slot');
reset role;

select * from finish();
rollback;
