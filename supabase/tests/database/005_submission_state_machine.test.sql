begin;

select plan(13);

select has_table('wali', 'upload_sessions', 'upload sessions exist');
select has_table('wali', 'submissions', 'submissions exist');
select has_table('wali', 'rights_declarations', 'rights declarations exist');
select has_table('wali', 'processing_attempts', 'processing attempts exist');
select has_table('wali', 'classification_runs', 'classification runs exist');
select has_table('wali', 'model_registry', 'model registry exists');
select has_function(
  'wali', 'transition_submission',
  array['uuid', 'wali.submission_status', 'bigint', 'uuid'],
  'submission transition command exists'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '00000000-0000-0000-0000-000000000000', '20000000-0000-0000-0000-000000000001',
  'authenticated', 'authenticated', 'workflow-creator@example.invalid', crypt('local-only-password', gen_salt('bf')),
  statement_timestamp(), '{"provider":"email","providers":["email"]}', '{"display_name":"Workflow Creator"}',
  statement_timestamp(), statement_timestamp()
) on conflict (id) do nothing;

insert into wali.role_grants (user_id, role, granted_by, reason)
values (
  '20000000-0000-0000-0000-000000000001', 'creator',
  '20000000-0000-0000-0000-000000000001', 'pgTAP workflow fixture'
) on conflict (user_id, role) where revoked_at is null do nothing;

insert into wali.licenses (
  id, code, name, terms_url, attribution_required, commercial_use_allowed,
  derivatives_allowed, redistribution_allowed, terms_revision
) values (
  '21000000-0000-0000-0000-000000000001', 'workflow-license', 'Workflow License',
  'https://example.invalid/workflow-license', false, true, true, true, 1
) on conflict (id) do nothing;

insert into wali.categories (id, slug, name, description)
values ('22000000-0000-0000-0000-000000000001', 'workflow-category', 'Workflow', 'Synthetic workflow category')
on conflict (id) do nothing;

insert into wali.upload_sessions (
  id, creator_id, storage_path, original_filename, declared_byte_count,
  received_byte_count, source_digest, detected_media_type, status, expires_at,
  completed_at, idempotency_key, declared_media_type, storage_version
) values (
  '23000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001/23000000-0000-0000-0000-000000000001/source', 'synthetic.mp4',
  128, 128, repeat('a', 64), 'video/mp4', 'completed', statement_timestamp() + interval '1 day',
  statement_timestamp(), '24000000-0000-0000-0000-000000000001', 'video/mp4', 'fixture-version-1'
);

insert into wali.submissions (
  id, creator_id, proposed_title, proposed_description, primary_category_id,
  license_id, rights_holder, upload_session_id, status, generation, revision
) values (
  '25000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
  'Workflow Test', 'Synthetic state machine fixture',
  '22000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001',
  'WALI Test Fixture', '23000000-0000-0000-0000-000000000001',
  'ready_for_submission', 1, 1
);

insert into wali.rights_declarations (
  submission_id, basis, rights_holder, license_id, attested_at,
  creator_terms_version, review_status, reviewed_by, reviewed_at
) values (
  '25000000-0000-0000-0000-000000000001', 'original', 'WALI Test Fixture',
  '21000000-0000-0000-0000-000000000001', statement_timestamp(), '2026-09-01',
  'approved', '20000000-0000-0000-0000-000000000001', statement_timestamp()
);

insert into wali.processing_attempts (
  id, submission_id, generation, status, worker_build, media_image_digest,
  classifier_image_digest, started_at, finished_at, output_summary
) values (
  '26000000-0000-0000-0000-000000000001', '25000000-0000-0000-0000-000000000001',
  1, 'completed', 'test-worker', repeat('b', 64), repeat('c', 64),
  statement_timestamp(), statement_timestamp(), '{"verified":true}'
);

select set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;

select throws_ok(
  $$update wali.submissions set status = 'published'
     where id = '25000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'creator cannot write submission state directly'
);

reset role;
select set_config('request.jwt.claim.role', 'service_role', true);
set local role service_role;

select is(
  wali.transition_submission(
    '25000000-0000-0000-0000-000000000001', 'submitted', 1,
    '27000000-0000-0000-0000-000000000001'
  ) ->> 'status',
  'submitted',
  'the bounded service command submits the current ready generation'
);

select is(
  wali.transition_submission(
    '25000000-0000-0000-0000-000000000001', 'submitted', 1,
    '27000000-0000-0000-0000-000000000001'
  ) ->> 'replayed',
  'true',
  'same command key and request replays safely'
);

select throws_ok(
  $$select wali.transition_submission(
      '25000000-0000-0000-0000-000000000001', 'withdrawn', 1,
      '27000000-0000-0000-0000-000000000002'
    )$$,
  'P0001', 'WALI_REVISION_MISMATCH', 'stale expected revision is rejected'
);

select throws_ok(
  $$select wali.transition_submission(
      '25000000-0000-0000-0000-000000000001', 'withdrawn', 2,
      '27000000-0000-0000-0000-000000000001'
    )$$,
  'P0001', 'WALI_IDEMPOTENCY_CONFLICT', 'same command key cannot bind different input'
);

select throws_ok(
  $$select wali.advance_processing_attempt(
      '26000000-0000-0000-0000-000000000001', 'completed', 'completed',
      'worker-test', 2, '{"verified":true}'::jsonb, null
    )$$,
  'P0001', 'WALI_STALE_PROCESSING_GENERATION', 'stale worker generation cannot commit'
);

select * from finish();
rollback;
