-- Real restricted-login issuance is covered by the local-only Python harness.
-- These nonsuperuser administrator/API denial assertions remain rollback-only.
begin;
-- Synthetic role selection for this rollback-only test; session_user stays postgres.
grant wali_worker to postgres with set true;
select plan(9);
select has_function('wali','renew_storage_worker_token',array[]::text[],'private renewal function exists');
select ok(not has_function_privilege('anon','wali.renew_storage_worker_token()','execute') and not has_function_privilege('authenticated','wali.renew_storage_worker_token()','execute') and not has_function_privilege('service_role','wali.renew_storage_worker_token()','execute'),'API roles cannot issue worker credentials');
select ok(has_function_privilege('wali_worker','wali.renew_storage_worker_token()','execute'),'only restricted worker group receives issuance');
select ok(not has_table_privilege('wali_worker','wali.worker_storage_auth_bindings','select') and not has_table_privilege('service_role','wali.worker_storage_auth_bindings','select'),'bindings cannot be read by worker or service role');
select throws_ok($$select wali.renew_storage_worker_token()$$,'P0001','WALI_STORAGE_CREDENTIAL_UNAVAILABLE','administrator cannot impersonate worker by default');
create temporary table renewal_denial(code text);
grant insert on renewal_denial to wali_worker;
create function pg_temp.renewal_error() returns text language plpgsql as $$begin perform wali.renew_storage_worker_token(); return 'unexpected success'; exception when others then return sqlstate||':'||sqlerrm; end;$$;
set role wali_worker;
select set_config('request.jwt.claims','{"role":"wali_worker","worker_id":"renewal-fixture"}',true);
insert into renewal_denial values(pg_temp.renewal_error());
reset role;
select is((select code from renewal_denial),'P0001:WALI_STORAGE_CREDENTIAL_UNAVAILABLE','JWT claims cannot replace real login identity');
select ok(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like '%storage_worker_token%'),'no public RPC is exposed');
select throws_ok($$insert into wali.worker_storage_auth_bindings(login_role_oid,login_role_name,worker_id,storage_origin,issuer_secret_id) values(0,'wali_invalid_origin_fixture','invalid-origin-fixture','https://fixture.supabase.co/foreign','00000000-0000-0000-0000-000000000000')$$,'23514',null,'binding accepts an exact HTTPS origin only');
select is((select count(*) from wali.worker_storage_auth_bindings),0::bigint,'migration added no real binding');
select * from finish();
rollback;
