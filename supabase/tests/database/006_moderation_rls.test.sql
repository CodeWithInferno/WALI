begin;

select plan(12);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000004',
  'authenticated', 'authenticated', 'moderator@example.invalid', crypt('local-only-password', gen_salt('bf')),
  statement_timestamp(), '{"provider":"email","providers":["email"]}', '{"display_name":"Moderator"}',
  statement_timestamp(), statement_timestamp()
) on conflict (id) do nothing;

insert into wali.role_grants (user_id, role, granted_by, reason)
values (
  '00000000-0000-0000-0000-000000000004', 'moderator',
  '00000000-0000-0000-0000-000000000004', 'pgTAP moderator fixture'
)
on conflict (user_id, role) where revoked_at is null do nothing;


select has_table('wali', 'moderation_reviews', 'moderation reviews exist');
select has_table('wali', 'moderation_actions', 'moderation actions exist');
select has_table('wali', 'reports', 'reports exist');
select has_table('wali', 'copyright_cases', 'copyright cases exist');
select has_table('wali', 'catalog_revocations', 'catalog revocations exist');
select has_table('wali', 'catalog_signing_keys', 'catalog signing keys exist');
select has_table('wali', 'audit_events', 'audit events exist');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000004","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;

select is(wali.has_moderation_access(), false, 'AAL1 moderator is denied');

select throws_ok(
  $$select wali.record_moderation_decision(
      '25000000-0000-0000-0000-000000000001', 'approved', 2,
      '28000000-0000-0000-0000-000000000001', 'Approved', null, array['policy-ok']
    )$$,
  '42501', 'permission denied for function record_moderation_decision',
  'direct moderation command is unavailable even to an AAL1 moderator'
);

reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000004","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;

select ok(wali.has_moderation_access(), 'active AAL2 moderator is authorized');

select is(
  has_table_privilege('authenticated', 'wali.rights_declarations', 'SELECT'),
  false,
  'moderator cannot list rights rows through direct tables'
);

select results_eq(
  $$select count(*)::bigint from wali.reports$$,
  array[0::bigint],
  'moderator cannot list reports through raw tables'
);

select * from finish();
rollback;
