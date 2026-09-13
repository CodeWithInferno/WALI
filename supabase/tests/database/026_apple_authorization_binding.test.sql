begin;
set local search_path=public,extensions;
select plan(16);
select has_table('wali','apple_authorizations','Apple custody is private');
select set_config('request.jwt.claim.role','service_role',true);
insert into auth.identities(id,user_id,provider,provider_id,identity_data)
values(gen_random_uuid(),'00000000-0000-0000-0000-000000000003','apple','local-apple-subject','{"sub":"local-apple-subject"}');
select throws_ok($$select public.wali_edge_begin_apple_authorization_v1('00000000-0000-0000-0000-000000000003','com.wali.other','local-apple-subject',repeat('a',64))$$,'P0001','WALI_REQUEST_INVALID','unapproved native audience fails');
select throws_ok($$select public.wali_edge_begin_apple_authorization_v1('00000000-0000-0000-0000-000000000003','com.wali.store.WALI','other-subject',repeat('a',64))$$,'P0001','WALI_AUTH_SUBJECT_CHANGED','server identity mapping binds Apple subject');
create temporary table first_binding as select public.wali_edge_begin_apple_authorization_v1('00000000-0000-0000-0000-000000000003','com.wali.store.WALI','local-apple-subject',repeat('a',64)) result;
select is((select result->>'status' from first_binding),'exchange','new code receives a lease');
select is(public.wali_edge_begin_apple_authorization_v1('00000000-0000-0000-0000-000000000003','com.wali.store.WALI','local-apple-subject',repeat('a',64))->>'status','busy','same-code replay cannot duplicate an in-flight exchange');
select is(public.wali_edge_complete_apple_authorization_v1('00000000-0000-0000-0000-000000000003','com.wali.store.WALI','local-apple-subject',repeat('a',64),(select (result->>'lease_token')::uuid from first_binding),'v1.'||repeat('a',16)||'.'||repeat('b',48),'local-v1')->>'status','bound','exact active lease commits encrypted material');
select is(public.wali_edge_begin_apple_authorization_v1('00000000-0000-0000-0000-000000000003','com.wali.store.WALI','local-apple-subject',repeat('a',64))->>'status','bound','lost-reply replay does not consume authorization code again');
select ok(not has_table_privilege('authenticated','wali.apple_authorizations','SELECT'),'signed-in clients cannot read token custody');
select ok(not has_table_privilege('wali_worker','wali.apple_authorizations','SELECT'),'media worker cannot read token custody');
select ok(not has_function_privilege('authenticated','public.wali_edge_begin_apple_authorization_v1(uuid,text,text,text)','EXECUTE'),'ordinary clients cannot call service binding RPC');
create temporary table replacement as select public.wali_edge_begin_apple_authorization_v1('00000000-0000-0000-0000-000000000003','com.wali.store.WALI','local-apple-subject',repeat('c',64)) result;
select is((select encrypted_refresh_token from wali.apple_authorizations where actor_id='00000000-0000-0000-0000-000000000003'),'v1.'||repeat('a',16)||'.'||repeat('b',48),'replacement preserves old ciphertext until commit');
-- The SQL statement begins before expiry, just as it does before a lock wait.
-- Advancing the live clock must not permit that statement to commit a late token.
create function pg_temp.complete_expired_apple_binding() returns jsonb language plpgsql as $$
begin
 update wali.apple_authorizations set binding_lease_expires_at=clock_timestamp()+interval '25 milliseconds'
  where actor_id='00000000-0000-0000-0000-000000000003' and client_id='com.wali.store.WALI';
 perform pg_sleep(0.05);
 return public.wali_edge_complete_apple_authorization_v1('00000000-0000-0000-0000-000000000003','com.wali.store.WALI','local-apple-subject',repeat('c',64),
  (select (result->>'lease_token')::uuid from replacement),'v1.'||repeat('c',16)||'.'||repeat('d',48),'local-v1');
end $$;
savepoint before_expired_apple_binding;
select is(pg_temp.complete_expired_apple_binding()->>'status','rejected','elapsed binding lease rejects completion despite earlier statement clock');
select is((select encrypted_refresh_token from wali.apple_authorizations where actor_id='00000000-0000-0000-0000-000000000003'),'v1.'||repeat('a',16)||'.'||repeat('b',48),'expired replacement preserves credential already held for deletion');
rollback to savepoint before_expired_apple_binding;
update wali.profiles set status='deletion_pending' where id='00000000-0000-0000-0000-000000000003';
select is(public.wali_edge_complete_apple_authorization_v1('00000000-0000-0000-0000-000000000003','com.wali.store.WALI','local-apple-subject',repeat('a',64),(select (result->>'lease_token')::uuid from first_binding),'v1.'||repeat('a',16)||'.'||repeat('b',48),'local-v1')->>'status','retained','lost committed reply after freeze preserves custody without admitting sign-in');
select is(public.wali_edge_complete_apple_authorization_v1('00000000-0000-0000-0000-000000000003','com.wali.store.WALI','local-apple-subject',repeat('c',64),(select (result->>'lease_token')::uuid from replacement),'v1.'||repeat('c',16)||'.'||repeat('d',48),'local-v1')->>'status','rejected','deletion freeze fences late bind completion');
select is((select encrypted_refresh_token from wali.apple_authorizations where actor_id='00000000-0000-0000-0000-000000000003'),'v1.'||repeat('a',16)||'.'||repeat('b',48),'rejected exchange cannot overwrite deletion credential');
select * from finish();
rollback;
