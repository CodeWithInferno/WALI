begin;

select plan(11);

insert into auth.users (
  instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', 'a1400000-0000-4000-8000-000000000001',
   'authenticated', 'authenticated', 'profile-owner@example.invalid',
   '{"provider":"email","providers":["email"]}', '{"display_name":"Profile Owner"}',
   statement_timestamp(), statement_timestamp()),
  ('00000000-0000-0000-0000-000000000000', 'a1400000-0000-4000-8000-000000000002',
   'authenticated', 'authenticated', 'profile-other@example.invalid',
   '{"provider":"email","providers":["email"]}', '{"display_name":"Other Profile"}',
   statement_timestamp(), statement_timestamp());

update wali.profiles
set avatar_path = 'avatars/' || id::text || '/' || repeat('a', 64) || '.png'
where id = 'a1400000-0000-4000-8000-000000000001';

delete from wali.runtime_configuration;

select ok(
  (select reloptions @> array['security_invoker=true', 'security_barrier=true']
   from pg_class where oid = 'public.my_profile_v1'::regclass),
  'self profile retains invoker and barrier protection'
);
select ok(
  has_table_privilege('authenticated', 'public.my_profile_v1', 'select')
    and not has_table_privilege('anon', 'public.my_profile_v1', 'select'),
  'self profile remains authenticated-only'
);

select set_config('request.jwt.claim.sub', 'a1400000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"a1400000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;

select results_eq(
  $$select id, display_name, status from public.my_profile_v1$$,
  $$values ('a1400000-0000-4000-8000-000000000001'::uuid, 'Profile Owner'::text, 'active'::text)$$,
  'own profile loads before catalog configuration exists'
);
select is(
  (select avatar_url from public.my_profile_v1), null::text,
  'an avatar path has no public URL before catalog configuration exists'
);
select is(
  (select count(*) from public.my_profile_v1 where id = 'a1400000-0000-4000-8000-000000000002'),
  0::bigint,
  'missing catalog configuration does not expose another account'
);
select is(
  (select preferences_revision from public.my_profile_v1), 1::bigint,
  'own preferences remain available before catalog configuration exists'
);

reset role;
update wali.profiles set status = 'suspended'
where id = 'a1400000-0000-4000-8000-000000000001';
set local role authenticated;
select is(
  (select status from public.my_profile_v1), 'suspended'::text,
  'a suspended account can still read its own profile without catalog configuration'
);

reset role;
insert into wali.runtime_configuration (
  singleton, environment, catalog_public_base_url, creator_terms_version, media_policy_digest
) values (
  true, 'local', 'https://profile.example.invalid/storage/v1/object/public/catalog-public',
  '2026-09-01', repeat('b', 64)
);
set local role authenticated;
select is(
  (select avatar_url from public.my_profile_v1),
  'https://profile.example.invalid/storage/v1/object/public/catalog-public/avatars/a1400000-0000-4000-8000-000000000001/' || repeat('a', 64) || '.png',
  'configured catalog base still resolves the caller avatar'
);
select is(
  (select count(*) from public.my_profile_v1), 1::bigint,
  'configured profile still returns exactly one own row'
);

reset role;
select set_config('request.jwt.claim.sub', 'a1400000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claims', '{"sub":"a1400000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select is(
  (select avatar_url from public.my_profile_v1), null::text,
  'a profile without an avatar remains null after catalog configuration'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', 'anon', true);
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
select throws_ok(
  $$select * from public.my_profile_v1$$, '42501', null,
  'anonymous callers cannot read self profiles'
);

reset role;
select * from finish();
rollback;
