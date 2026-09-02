begin;

select plan(10);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000002',
   'authenticated', 'authenticated', 'creator-a@example.invalid', crypt('local-only-password', gen_salt('bf')),
   statement_timestamp(), '{"provider":"email","providers":["email"]}', '{"display_name":"Creator A"}',
   statement_timestamp(), statement_timestamp()),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000003',
   'authenticated', 'authenticated', 'user-b@example.invalid', crypt('local-only-password', gen_salt('bf')),
   statement_timestamp(), '{"provider":"email","providers":["email"]}', '{"display_name":"User B"}',
   statement_timestamp(), statement_timestamp())
on conflict (id) do nothing;

insert into wali.role_grants (user_id, role, granted_by, reason)
values (
  '00000000-0000-0000-0000-000000000002', 'creator',
  '00000000-0000-0000-0000-000000000003', 'pgTAP creator fixture'
)
on conflict (user_id, role) where revoked_at is null do nothing;

select has_function('wali', 'current_user_id', array[]::text[], 'current user helper exists');
select has_function('wali', 'has_active_role', array['wali.role_name'], 'role helper exists');
select has_function('wali', 'current_aal', array[]::text[], 'AAL helper exists');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;

select is(wali.current_user_id(), '00000000-0000-0000-0000-000000000002'::uuid, 'current user comes from JWT');
select is(wali.current_aal(), 'aal1', 'current AAL comes from JWT');
select ok(wali.has_active_role('creator'), 'creator sees active creator grant');
select is(wali.has_active_role('moderator'), false, 'creator does not inherit moderator');
select is(wali.has_active_role('admin'), false, 'creator does not inherit admin');

select throws_ok(
  $$insert into wali.role_grants (user_id, role, granted_by, reason)
    values ('00000000-0000-0000-0000-000000000002', 'admin',
            '00000000-0000-0000-0000-000000000002', 'self escalation')$$,
  '42501',
  null,
  'client cannot grant itself a role'
);

select throws_ok(
  $$update wali.profiles set status = 'active'
     where id = '00000000-0000-0000-0000-000000000003'$$,
  '42501',
  null,
  'client cannot update another profile status'
);

select * from finish();
rollback;
