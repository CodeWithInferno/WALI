begin;

select plan(8);

select has_schema('wali', 'authoritative schema exists');
select has_table('wali', 'profiles', 'profiles table exists');
select has_table('wali', 'role_grants', 'role grants table exists');
select has_table('wali', 'creator_profiles', 'creator profiles table exists');
select has_table('wali', 'terms_acceptances', 'terms acceptances table exists');
select has_table('wali', 'user_preferences', 'user preferences table exists');
select results_eq(
  $$select c.relrowsecurity
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'wali' and c.relname = 'profiles'$$,
  array[true],
  'profiles enables RLS'
);
select results_eq(
  $$select c.relrowsecurity
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'wali' and c.relname = 'user_preferences'$$,
  array[true],
  'preferences enable RLS'
);

select * from finish();
rollback;
