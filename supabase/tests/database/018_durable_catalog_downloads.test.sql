-- Synthetic rollback-only acknowledgements and privacy/retention fixtures.
begin;
select plan(25);
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);

insert into wali.install_receipts(id,user_id,release_id,request_id) values
('95000000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000001','95000000-0000-4000-8000-000000000011'),
('95000000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000003','40000000-0000-0000-0000-000000000001','95000000-0000-4000-8000-000000000012'),
('95000000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000003','40000000-0000-0000-0000-000000000001','95000000-0000-4000-8000-000000000013'),
('95000000-0000-4000-8000-000000000004','00000000-0000-0000-0000-000000000003','40000000-0000-0000-0000-000000000001','95000000-0000-4000-8000-000000000014');
select is((select verified_install_count from wali.catalog_public_counts('30000000-0000-0000-0000-000000000001')),0::bigint,'issued receipts never increment completed downloads');
select public.record_install_v1('00000000-0000-0000-0000-000000000002','95000000-0000-4000-8000-000000000021','durable_install_self_001','95000000-0000-4000-8000-000000000001','40000000-0000-0000-0000-000000000001',(select manifest_digest from wali.wallpaper_releases where id='40000000-0000-0000-0000-000000000001'),'verified_installed');
select is((select verified_install_count from wali.catalog_public_counts('30000000-0000-0000-0000-000000000001')),1::bigint,'real publisher acknowledgement counts immediately');
select public.record_install_v1('00000000-0000-0000-0000-000000000002','95000000-0000-4000-8000-000000000022','durable_install_self_001','95000000-0000-4000-8000-000000000001','40000000-0000-0000-0000-000000000001',(select manifest_digest from wali.wallpaper_releases where id='40000000-0000-0000-0000-000000000001'),'verified_installed');
select is((select verified_install_count from wali.catalog_public_counts('30000000-0000-0000-0000-000000000001')),1::bigint,'lost-response replay increments once');
select throws_ok($$select public.record_install_v1('00000000-0000-0000-0000-000000000002','95000000-0000-4000-8000-000000000023','durable_install_self_002','95000000-0000-4000-8000-000000000001','40000000-0000-0000-0000-000000000001',(select manifest_digest from wali.wallpaper_releases where id='40000000-0000-0000-0000-000000000001'),'verified_installed')$$,'P0001','WALI_INSTALL_RECEIPT_CONSUMED','a new key cannot consume the same receipt again');
select ok((select not contributes_to_ranking and exclusion_reason='creator_self_interaction' from wali.engagement_events where install_receipt_id='95000000-0000-4000-8000-000000000001'),'public self-install count does not change ranking exclusion');
select public.record_install_v1('00000000-0000-0000-0000-000000000003','95000000-0000-4000-8000-000000000024','durable_install_other_001','95000000-0000-4000-8000-000000000002','40000000-0000-0000-0000-000000000001',(select manifest_digest from wali.wallpaper_releases where id='40000000-0000-0000-0000-000000000001'),'verified_installed');
select public.record_install_v1('00000000-0000-0000-0000-000000000003','95000000-0000-4000-8000-000000000025','durable_install_other_002','95000000-0000-4000-8000-000000000003','40000000-0000-0000-0000-000000000001',(select manifest_digest from wali.wallpaper_releases where id='40000000-0000-0000-0000-000000000001'),'verified_installed');
select is((select verified_install_count from wali.catalog_public_counts('30000000-0000-0000-0000-000000000001')),3::bigint,'two distinct verified receipts count independently');
select is((select count(*) from wali.engagement_events where user_id='00000000-0000-0000-0000-000000000003' and contributes_to_ranking),1::bigint,'same-day ranking deduplication stays independent');
select throws_ok($$select public.record_install_v1('00000000-0000-0000-0000-000000000003','95000000-0000-4000-8000-000000000024','durable_install_atomic_001','95000000-0000-4000-8000-000000000004','40000000-0000-0000-0000-000000000001',(select manifest_digest from wali.wallpaper_releases where id='40000000-0000-0000-0000-000000000001'),'verified_installed')$$,'23505',null,'failure after receipt update rolls back the whole acknowledgement');
select ok((select consumed_at is null from wali.install_receipts where id='95000000-0000-4000-8000-000000000004'),'failed acknowledgement leaves receipt unconsumed');
select is((select verified_install_count from wali.catalog_public_counts('30000000-0000-0000-0000-000000000001')),3::bigint,'failed acknowledgement never increments the durable total');

-- Real account-deletion function anonymizes the installer; it must neither
-- decrement nor replay completion. This subject owns no seeded source media.
create temporary table count_deletion_request as select public.wali_edge_request_account_deletion_v1('00000000-0000-0000-0000-000000000003','95000000-0000-4000-8000-000000000030','durable_count_delete_001',(select revision from wali.profiles where id='00000000-0000-0000-0000-000000000003')) body;
select public.wali_edge_mark_account_deletion_sessions_revoked_v1('00000000-0000-0000-0000-000000000003',(select (body->>'deletion_id')::uuid from count_deletion_request),'95000000-0000-4000-8000-000000000031');
select is(wali.worker_begin_account_deletion((select (body->>'deletion_id')::uuid from count_deletion_request),'00000000-0000-0000-0000-000000000003','durable-count-worker',statement_timestamp()+interval '5 minutes')->>'disposition','ready','synthetic deletion reaches the real worker cleanup seam');
select ok(wali.worker_complete_account_deletion((select (body->>'deletion_id')::uuid from count_deletion_request),'00000000-0000-0000-0000-000000000003','durable-count-worker'),'real account anonymization succeeds');
select is((select count(*) from wali.install_receipts where user_id='00000000-0000-0000-0000-000000000003'),0::bigint,'installer subject links are removed');
select is((select verified_install_count from wali.catalog_public_counts('30000000-0000-0000-0000-000000000001')),3::bigint,'account deletion preserves anonymous completed-download facts');

-- Synthetic historical consumed receipt with no retained engagement reference:
-- this is the exact state eligible for current receipt retention, not a change
-- to engagement retention or a fabricated production acknowledgement.
insert into wali.install_receipts(id,user_id,release_id,request_id,issued_at,expires_at) values
('95000000-0000-4000-8000-000000000005',null,'40000000-0000-0000-0000-000000000001','95000000-0000-4000-8000-000000000015',statement_timestamp()-interval '40 days',statement_timestamp()-interval '40 days'+interval '30 minutes');
update wali.install_receipts set consumed_at=statement_timestamp()-interval '40 days'+interval '1 minute' where id='95000000-0000-4000-8000-000000000005';
select is((select verified_install_count from wali.catalog_public_counts('30000000-0000-0000-0000-000000000001')),4::bigint,'historical consumed receipt contributes before retention');
select wali.cleanup_expired_marketplace_objects(statement_timestamp());
select is((select count(*) from wali.install_receipts where id='95000000-0000-4000-8000-000000000005'),0::bigint,'actual retention routine deletes the eligible historical receipt');
select is((select verified_install_count from wali.catalog_public_counts('30000000-0000-0000-0000-000000000001')),4::bigint,'completed total survives receipt deletion');
select wali.cleanup_expired_marketplace_objects(statement_timestamp());
select is((select verified_install_count from wali.catalog_public_counts('30000000-0000-0000-0000-000000000001')),4::bigint,'repeated retention does not change completed total');
select throws_ok($$update wali.install_receipts set consumed_at=null where id='95000000-0000-4000-8000-000000000001'$$,'P0001','WALI_INSTALL_RECEIPT_IMMUTABLE','consumption cannot be reset then counted again');
select lives_ok($$update wali.install_receipts set consumed_at=consumed_at where id='95000000-0000-4000-8000-000000000001'$$,'same-value receipt update remains idempotent');
select is((select verified_install_count from wali.catalog_public_counts('30000000-0000-0000-0000-000000000001')),4::bigint,'same-value update never increments twice');
select ok(not coalesce(has_table_privilege('anon',to_regclass('wali.wallpaper_download_totals'),'SELECT'),true) and not coalesce(has_table_privilege('authenticated',to_regclass('wali.wallpaper_download_totals'),'SELECT,INSERT,UPDATE,DELETE'),true),'no direct client access to private aggregate storage');
select is((select array_agg(column_name::text order by ordinal_position) from information_schema.columns where table_schema='wali' and table_name='wallpaper_download_totals'),array['wallpaper_id','completed_downloads']::text[],'durable total contains no user or receipt identifiers or event history');
select is((select count(*) from wali.catalog_public_counts('ffffffff-ffff-ffff-ffff-ffffffffffff')),0::bigint,'unknown wallpaper reveals no count');
select is((select verified_install_count from wali.catalog_public_counts('30000000-0000-0000-0000-000000000002')),0::bigint,'another wallpaper does not inherit these completions');
select * from finish();
rollback;
