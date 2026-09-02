begin;

select plan(6);

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


select has_table('wali', 'moderation_actions', 'moderation action table exists');
select has_table('wali', 'audit_events', 'audit event table exists');

insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
values (
  null, 'test.audit', 'account', '00000000-0000-0000-0000-000000000001',
  '29000000-0000-0000-0000-000000000001', '{"fixture":true}'
) returning id \gset audit_

select throws_ok(
  format('update wali.audit_events set action = %L where id = %L', 'tampered', :'audit_id'),
  'P0001', 'WALI_APPEND_ONLY', 'audit rows cannot be updated'
);

select throws_ok(
  format('delete from wali.audit_events where id = %L', :'audit_id'),
  'P0001', 'WALI_APPEND_ONLY', 'audit rows cannot be deleted'
);

insert into wali.moderation_actions (
  actor_id, action, target_type, target_id, reason_code, request_id, metadata
) values (
  '00000000-0000-0000-0000-000000000004', 'test.action', 'submission',
  '25000000-0000-0000-0000-000000000001', 'test-only',
  '29000000-0000-0000-0000-000000000002', '{"fixture":true}'
) returning id \gset action_

select throws_ok(
  format('update wali.moderation_actions set reason_code = %L where id = %L', 'tampered', :'action_id'),
  'P0001', 'WALI_APPEND_ONLY', 'moderation actions cannot be updated'
);

select throws_ok(
  format('delete from wali.moderation_actions where id = %L', :'action_id'),
  'P0001', 'WALI_APPEND_ONLY', 'moderation actions cannot be deleted'
);

select * from finish();
rollback;
