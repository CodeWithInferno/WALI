begin;

select plan(67);

select has_function(
  'public', 'record_install_v1',
  array['uuid', 'uuid', 'text', 'uuid', 'uuid', 'text', 'text'],
  'record-install has one constrained service command'
);

select results_eq(
  $$select count(*)::bigint
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'wali'
       and (
         has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE')
       )
       and p.oid::regprocedure::text not in (
         'wali.current_user_id()',
         'wali.current_aal()',
         'wali.has_active_role(wali.role_name)',
         'wali.has_moderation_access()',
         'wali.can_insert_rights_proof(text)',
         'wali.moderator_can_preview_canonical(text,text)',
         'wali.encode_catalog_cursor(timestamp with time zone,uuid,numeric,text)',
         'wali.decode_catalog_cursor(text)',
         'wali.catalog_rating_limit()',
         'wali.catalog_public_counts(uuid)'
       )$$,
  array[0::bigint],
  'internal wali functions are not executable through Data API roles'
);

select results_eq(
  $$select count(*)::bigint
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname like 'wali_edge_%'
       and p.proname <> 'wali_edge_catalog_security_state_v1'
       and (
         has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE')
       )$$,
  array[0::bigint],
  'Edge command RPCs are callable only by service_role'
);

select set_config('request.jwt.claim.role', 'service_role', true);

select has_function(
  'public', 'wali_edge_accept_creator_terms_v1',
  array['uuid', 'uuid', 'uuid', 'text', 'text'],
  'creator terms acceptance requires the initiating subject'
);

select throws_ok(
  $$select public.wali_edge_accept_creator_terms_v1(
      '00000000-0000-4000-8000-000000000003',
      '00000000-0000-4000-8000-000000000002',
      '93000000-0000-4000-8000-000000000001',
      'accept_creator_terms_subject_change_01',
      '2026-09-01'
    )$$,
  'P0001',
  'WALI_AUTH_SUBJECT_CHANGED',
  'creator terms acceptance rejects an authenticated account switch'
);

select is(
  (select count(*) from wali.terms_acceptances
    where user_id = '00000000-0000-4000-8000-000000000003'
      and document_kind = 'creator_terms'
      and document_version = '2026-09-01'),
  0::bigint,
  'rejected account switch does not record creator terms acceptance'
);

insert into wali.role_grants (
  user_id, role, granted_by, revoked_by, revoked_at, reason, revision
) values (
  '00000000-0000-0000-0000-000000000003',
  'creator',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '2026-09-01T00:00:00Z',
  'revoked creator regression fixture',
  1
);

select throws_ok(
  $$select public.wali_edge_accept_creator_terms_v1(
      '00000000-0000-0000-0000-000000000003',
      '00000000-0000-0000-0000-000000000003',
      '93000000-0000-4000-8000-000000000002',
      'accept_creator_terms_revoked_role_01',
      (select creator_terms_version from wali.runtime_configuration where singleton)
    )$$,
  'P0001',
  'WALI_CREATOR_ROLE_REVOKED',
  'accepting terms cannot restore a historically revoked creator role'
);

select is(
  (select count(*) from wali.role_grants
    where user_id = '00000000-0000-0000-0000-000000000003'
      and role = 'creator'
      and revoked_at is null),
  0::bigint,
  'rejected creator self-restoration leaves no active grant'
);

select is(
  (select count(*) from wali.terms_acceptances
    where user_id = '00000000-0000-0000-0000-000000000003'
      and document_kind = 'creator_terms'
      and document_version = '2026-09-01'),
  0::bigint,
  'rejected creator self-restoration does not record terms acceptance'
);

savepoint revocation_document_publication_regression;

select is(
  public.wali_edge_publish_security_document_v1(
    '00000000-0000-0000-0000-000000000001',
    'aal2',
    '97000000-0000-4000-8000-000000000001',
    'revocations',
    2,
    translate(encode(convert_to(
      '{"schema":{"epoch":1,"revision":0},"key_id":"catalog-local-1","revision":2,"issued_at":"2026-09-01T00:00:01Z","revocations":[]}',
      'UTF8'
    ), 'base64'), E'+/=\n\r', '-_'),
    translate(encode(decode(repeat('24', 64), 'hex'), 'base64'), E'+/=\n\r', '-_'),
    'catalog-local-1'
  ) ->> 'kind',
  'revocations',
  'an admin can publish the initial empty signed revocation document through the operator RPC'
);

rollback to savepoint revocation_document_publication_regression;

insert into wali.install_receipts (id, user_id, release_id, request_id)
values (
  '91000000-0000-4000-8000-000000000010',
  '00000000-0000-0000-0000-000000000003',
  '40000000-0000-0000-0000-000000000001',
  '91000000-0000-4000-8000-000000000001'
);

select ok(
  (install.response ->> 'recorded')::boolean
  and install.response ->> 'result' = 'verified_installed'
  and install.response ->> 'release_id' = '40000000-0000-0000-0000-000000000001',
  'a valid one-use receipt records verified installation'
)
from lateral (
  select public.record_install_v1(
    '00000000-0000-0000-0000-000000000003',
    '91000000-0000-4000-8000-000000000002',
    'record_install_000000000000001',
    '91000000-0000-4000-8000-000000000010',
    '40000000-0000-0000-0000-000000000001',
    (select manifest_digest from wali.wallpaper_releases
      where id = '40000000-0000-0000-0000-000000000001'),
    'verified_installed'
  ) as response
) install;

select is(
  (select count(*) from wali.engagement_events
    where client_request_id = '91000000-0000-4000-8000-000000000002'),
  1::bigint,
  'record-install creates exactly one event'
);

select is(
  public.record_install_v1(
    '00000000-0000-0000-0000-000000000003',
    '91000000-0000-4000-8000-000000000009',
    'record_install_000000000000001',
    (select install_receipt_id from wali.engagement_events
      where client_request_id = '91000000-0000-4000-8000-000000000002'),
    '40000000-0000-0000-0000-000000000001',
    (select manifest_digest from wali.wallpaper_releases
      where id = '40000000-0000-0000-0000-000000000001'),
    'verified_installed'
  ) - 'replayed',
  jsonb_build_object(
    'release_id', '40000000-0000-0000-0000-000000000001'::uuid,
    'result', 'verified_installed',
    'recorded', true
  ),
  'idempotent replay returns the exact same safe acknowledgement'
);

select is(
  (select count(*) from wali.engagement_events
    where client_request_id = '91000000-0000-4000-8000-000000000002'),
  1::bigint,
  'idempotent replay contributes no second event'
);

select throws_ok(
  $$select public.record_install_v1(
      '00000000-0000-0000-0000-000000000003',
      '91000000-0000-4000-8000-000000000002',
      'record_install_000000000000001',
      (select install_receipt_id from wali.engagement_events
        where client_request_id = '91000000-0000-4000-8000-000000000002'),
      '40000000-0000-0000-0000-000000000001',
      repeat('0', 64),
      'verified_installed'
    )$$,
  'P0001', 'WALI_IDEMPOTENCY_CONFLICT',
  'reusing an idempotency key with changed input fails'
);

insert into wali.install_receipts (
  id, user_id, release_id, request_id, issued_at, expires_at
) values
  (
    '91000000-0000-4000-8000-000000000011',
    '00000000-0000-0000-0000-000000000003',
    '40000000-0000-0000-0000-000000000001',
    '91000000-0000-4000-8000-000000000003',
    statement_timestamp() - interval '31 minutes',
    statement_timestamp() - interval '1 minute'
  ),
  (
    '91000000-0000-4000-8000-000000000012',
    '00000000-0000-0000-0000-000000000006',
    '40000000-0000-0000-0000-000000000001',
    '91000000-0000-4000-8000-000000000005',
    statement_timestamp(),
    statement_timestamp() + interval '30 minutes'
  ),
  (
    '91000000-0000-4000-8000-000000000013',
    '00000000-0000-0000-0000-000000000003',
    '40000000-0000-0000-0000-000000000001',
    '91000000-0000-4000-8000-000000000007',
    statement_timestamp(),
    statement_timestamp() + interval '30 minutes'
  );

select throws_ok(
  $$select public.record_install_v1(
      '00000000-0000-0000-0000-000000000003',
      '91000000-0000-4000-8000-000000000004',
      'record_install_000000000000002',
      '91000000-0000-4000-8000-000000000011',
      '40000000-0000-0000-0000-000000000001',
      (select manifest_digest from wali.wallpaper_releases
        where id = '40000000-0000-0000-0000-000000000001'),
      'verified_installed'
    )$$,
  'P0001', 'WALI_INSTALL_RECEIPT_EXPIRED',
  'expired receipt fails closed'
);

select throws_ok(
  $$select public.record_install_v1(
      '00000000-0000-0000-0000-000000000003',
      '91000000-0000-4000-8000-000000000006',
      'record_install_000000000000003',
      '91000000-0000-4000-8000-000000000012',
      '40000000-0000-0000-0000-000000000001',
      (select manifest_digest from wali.wallpaper_releases
        where id = '40000000-0000-0000-0000-000000000001'),
      'verified_installed'
    )$$,
  'P0001', 'WALI_INSTALL_RECEIPT_INVALID',
  'another user cannot consume the receipt'
);

select throws_ok(
  $$select public.record_install_v1(
      '00000000-0000-0000-0000-000000000003',
      '91000000-0000-4000-8000-000000000008',
      'record_install_000000000000004',
      '91000000-0000-4000-8000-000000000013',
      '40000000-0000-0000-0000-000000000001',
      (select manifest_digest from wali.wallpaper_releases
        where id = '40000000-0000-0000-0000-000000000001'),
      'failed'
    )$$,
  'P0001', 'WALI_INSTALL_RESULT_INVALID',
  'only verified_installed is accepted'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.record_install_v1(uuid,uuid,text,uuid,uuid,text,text)',
    'EXECUTE'
  ),
  'record-install command is not directly exposed to authenticated clients'
);

create temporary table export_request_fixture as
select public.wali_edge_request_account_export_v1(
  '00000000-0000-0000-0000-000000000003',
  '94000000-0000-4000-8000-000000000001',
  'account_export_000000000000001'
) as response;

select is(
  wali.worker_begin_export(
    ((select response ->> 'export_id' from export_request_fixture))::uuid,
    '00000000-0000-0000-0000-000000000003', 'worker-export-test',
    statement_timestamp() + interval '5 minutes'
  ) ->> 'disposition',
  'started',
  'an owner export enters one lease-bound worker attempt'
);

select is(
  wali.worker_read_account_export(
    ((select response ->> 'export_id' from export_request_fixture))::uuid,
    '00000000-0000-0000-0000-000000000003', 'worker-export-test'
  ) -> 'account_identity' ->> 'email',
  'user-b@example.invalid',
  'account export includes the owner-readable allowlisted identity email'
);

select is(
  wali.worker_read_account_export(
    ((select response ->> 'export_id' from export_request_fixture))::uuid,
    '00000000-0000-0000-0000-000000000003', 'worker-export-test'
  ) -> 'account_identity' -> 'providers',
  '[]'::jsonb,
  'account export emits a bounded provider array without raw identity metadata'
);

insert into auth.sessions (id, user_id)
values ('94000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000003');

insert into wali.upload_sessions (
  id, creator_id, storage_path, original_filename, declared_byte_count,
  status, expires_at, idempotency_key, declared_media_type
) values (
  '94000000-0000-4000-8000-000000000003',
  '00000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-000000000003/94000000-0000-4000-8000-000000000003/source',
  'private-name.mp4', 1024, 'issued', statement_timestamp() + interval '1 hour',
  'account_deletion_upload_001', 'video/mp4'
);
insert into storage.objects (bucket_id, name, owner_id, metadata)
values ('uploads-private',
  '00000000-0000-0000-0000-000000000003/94000000-0000-4000-8000-000000000003/source',
  '00000000-0000-0000-0000-000000000003', '{"mimetype":"video/mp4","size":1024}');

create temporary table deletion_request_fixture as
select public.wali_edge_request_account_deletion_v1(
  '00000000-0000-0000-0000-000000000003',
  '94000000-0000-4000-8000-000000000004',
  'account_deletion_0000000000001',
  (select revision from wali.profiles where id = '00000000-0000-0000-0000-000000000003')
) as response;

select is((select response ->> 'status' from deletion_request_fixture), 'deletion_pending',
  'account deletion request atomically moves the profile to deletion_pending');
select is((select status::text from wali.profiles where id = '00000000-0000-0000-0000-000000000003'),
  'deletion_pending', 'a live access token is contained by durable inactive account state');

select is(
  wali.worker_begin_account_deletion(
    ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid,
    '00000000-0000-0000-0000-000000000003', 'worker-deletion-test',
    statement_timestamp() + interval '5 minutes'
  ) ->> 'disposition', 'cleanup_pending',
  'account cleanup cannot start before durable session revocation'
);

create temporary table deletion_mark_fixture as
select public.wali_edge_mark_account_deletion_sessions_revoked_v1(
  '00000000-0000-0000-0000-000000000003',
  ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid,
  '94000000-0000-4000-8000-000000000005'
) as response;

select is((select count(*) from auth.sessions where user_id = '00000000-0000-0000-0000-000000000003'),
  0::bigint, 'session revocation checkpoint removes every refresh session transactionally');
select is((select response ->> 'auth_identity_status' from deletion_mark_fixture), 'sessions_revoked',
  'session revocation persists an idempotent provider checkpoint');

select is(
  wali.worker_begin_account_deletion(
    ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid,
    '00000000-0000-0000-0000-000000000003', 'worker-deletion-test',
    statement_timestamp() + interval '5 minutes'
  ) ->> 'disposition', 'cleanup_pending',
  'an owned private object creates an exact cleanup dependency'
);

update wali.account_deletion_requests set status = 'processing', lease_owner = 'worker-deletion-test',
  lease_expires_at = statement_timestamp() + interval '5 minutes'
where id = ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid;

select is(
  wali.worker_complete_account_deletion(
    ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid,
    '00000000-0000-0000-0000-000000000003', 'worker-deletion-test'
  ), false,
  'account cleanup fails closed while an owned Storage object or cleanup intent remains'
);

update wali.cleanup_object_intents set status = 'completed', completed_at = statement_timestamp(),
  lease_owner = null, lease_expires_at = null
where storage_path = '00000000-0000-0000-0000-000000000003/94000000-0000-4000-8000-000000000003/source';
set local session_replication_role = replica;
delete from storage.objects where bucket_id = 'uploads-private'
  and name = '00000000-0000-0000-0000-000000000003/94000000-0000-4000-8000-000000000003/source';
set local session_replication_role = origin;
update wali.account_deletion_requests set status = 'pending', lease_owner = null, lease_expires_at = null
where id = ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid;

select is(
  wali.worker_begin_account_deletion(
    ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid,
    '00000000-0000-0000-0000-000000000003', 'worker-deletion-test',
    statement_timestamp() + interval '5 minutes'
  ) ->> 'disposition', 'ready',
  'account cleanup begins only after every private object is absent'
);

select is(
  wali.worker_complete_account_deletion(
    ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid,
    '00000000-0000-0000-0000-000000000003', 'wrong-worker'
  ), false, 'the wrong worker cannot complete account deletion'
);
update wali.account_deletion_requests set lease_expires_at = statement_timestamp() - interval '1 second'
where id = ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid;
select is(
  wali.worker_complete_account_deletion(
    ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid,
    '00000000-0000-0000-0000-000000000003', 'worker-deletion-test'
  ), false, 'an expired deletion lease cannot complete');
update wali.account_deletion_requests set lease_expires_at = statement_timestamp() + interval '5 minutes'
where id = ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid;

select ok(
  wali.worker_complete_account_deletion(
    ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid,
    '00000000-0000-0000-0000-000000000003', 'worker-deletion-test'
  ), 'account cleanup reaches the explicit provider-cleanup boundary');
select is((select count(*) from wali.engagement_events where user_id = '00000000-0000-0000-0000-000000000003'),
  0::bigint, 'account cleanup anonymizes append-only event subjects without changing event facts');
select is((select count(*) from wali.install_receipts where user_id = '00000000-0000-0000-0000-000000000003'),
  0::bigint, 'account cleanup removes the retained receipt subject link');
select is((select status::text from wali.profiles where id = '00000000-0000-0000-0000-000000000003'),
  'deleted', 'account cleanup retains a pseudonymous profile for published and audit foreign keys');
select is((select response ->> 'status' from deletion_request_fixture), 'deletion_pending',
  'the original command response remains immutable');

create temporary table deletion_status_fixture as
select public.wali_edge_account_deletion_status_v1(
  '00000000-0000-0000-0000-000000000003',
  ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid
) as response;
select is((select response ->> 'status' from deletion_status_fixture), 'awaiting_auth_cleanup',
  'owner-safe status does not report completion before provider identity cleanup');
select is(public.wali_edge_prepare_account_identity_deletion_v1(
  '00000000-0000-0000-0000-000000000001', 'aal2',
  ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid,
  ((select response ->> 'revision' from deletion_status_fixture))::bigint
) ->> 'completed', 'false', 'admin AAL2 prepares the exact soft-delete CAS');

create temporary table deletion_final_fixture as
select public.wali_edge_finalize_account_identity_deletion_v1(
  '00000000-0000-0000-0000-000000000001', 'aal2',
  '94000000-0000-4000-8000-000000000006',
  ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid,
  ((select response ->> 'revision' from deletion_status_fixture))::bigint
) as response;
select is((select response ->> 'status' from deletion_final_fixture), 'completed',
  'admin finalizer records completion only after the provider executor succeeds');
select is(public.wali_edge_account_deletion_status_v1(
  '00000000-0000-0000-0000-000000000003',
  ((select response ->> 'deletion_id' from deletion_request_fixture))::uuid
) ->> 'auth_identity_status', 'completed', 'final status exposes the completed provider cleanup checkpoint');

select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
select throws_ok(
  $$select public.set_favorite_v1('30000000-0000-0000-0000-000000000001', true, 0,
    'deleted_user_favorite_000001')$$,
  'P0001', 'WALI_ACCOUNT_INACTIVE',
  'a deprovisioned access JWT cannot use any public interaction mutation'
);
select set_config('request.jwt.claim.role', 'service_role', true);

create temporary table classifier_test_fixture (result jsonb not null);
with unit_vector as (
  select jsonb_agg(case when coordinate = 1 then 1.0 else 0.0 end order by coordinate) as value
  from generate_series(1, 768) coordinate
)
insert into classifier_test_fixture (result)
select jsonb_build_object(
  'available', true,
  'safe_code', 'ok',
  'model_id', 'google/siglip-base-patch16-224',
  'model_revision', '7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed',
  'model_digest', '2a86b6bf585b3b071c5ccc46a01c18abb08b018dacc868513e592da7bcc9f877',
  'taxonomy_revision', 'wali-taxonomy-v1',
  'input_frame_set_digest', repeat('e', 64),
  'categories', jsonb_build_array(jsonb_build_object('id', 'nature', 'confidence', 0.9)),
  'tags', jsonb_build_array(jsonb_build_object('id', 'calm', 'confidence', 0.8)),
  'visual_embedding', value,
  'text_embedding', value,
  'combined_embedding', value
)
from unit_vector;

select ok(
  wali.classifier_result_is_valid((select result from classifier_test_fixture)),
  'the pinned classifier accepts an exact normalized three-vector result with approved taxonomy labels'
);

select ok(
  not wali.classifier_result_is_valid(
    jsonb_set(
      (select result from classifier_test_fixture),
      '{tags}',
      '[{"id":"not_allowed","confidence":0.8}]'::jsonb
    )
  ),
  'classifier output containing an unapproved taxonomy label fails closed'
);

select ok(
  not wali.classifier_result_is_valid(
    jsonb_set((select result from classifier_test_fixture), '{combined_embedding,0}', '0'::jsonb)
  ),
  'classifier output containing a non-normalized embedding fails closed'
);

select cmp_ok(
  octet_length((select result::text from classifier_test_fixture)), '<=', 131072,
  'an exact three-by-768 classifier result stays within the worker completion byte contract'
);

insert into wali.upload_sessions (
  id, creator_id, storage_path, original_filename, declared_byte_count,
  received_byte_count, source_digest, detected_media_type, status, expires_at,
  completed_at, idempotency_key, declared_media_type, storage_version
) values (
  '92000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000002/92000000-0000-4000-8000-000000000001/source',
  'classifier-fixture.mp4', 4096, 4096, repeat('d', 64), 'video/mp4', 'completed',
  statement_timestamp() + interval '1 hour', statement_timestamp(),
  'classifier_fixture_upload_001', 'video/mp4', 'classifier-fixture-v1'
);

insert into storage.objects (bucket_id, name, owner_id, version, metadata)
values (
  'uploads-private',
  '00000000-0000-0000-0000-000000000002/92000000-0000-4000-8000-000000000001/source',
  '00000000-0000-0000-0000-000000000002', 'classifier-fixture-v1',
  '{"mimetype":"video/mp4","size":4096}'
);

insert into wali.wallpapers (
  id, creator_id, slug, title, description, primary_category_id, license_id,
  rights_holder_display, status
) values (
  '92000000-0000-4000-8000-000000000002',
  '00000000-0000-0000-0000-000000000002', 'classifier-persistence-fixture',
  'Classifier Persistence Fixture', 'Rollback-only classifier persistence coverage.',
  (select id from wali.categories where slug = 'nature'),
  '20000000-0000-0000-0000-000000000001', 'WALI Test', 'draft'
);

insert into wali.submissions (
  id, creator_id, wallpaper_id, proposed_title, proposed_description,
  primary_category_id, license_id, rights_holder, upload_session_id, status, generation
) values (
  '92000000-0000-4000-8000-000000000003',
  '00000000-0000-0000-0000-000000000002',
  '92000000-0000-4000-8000-000000000002',
  'Classifier Persistence Fixture', 'Rollback-only classifier persistence coverage.',
  (select id from wali.categories where slug = 'nature'),
  '20000000-0000-0000-0000-000000000001', 'WALI Test',
  '92000000-0000-4000-8000-000000000001', 'processing', 1
);

insert into wali.processing_attempts (
  id, submission_id, generation, status, lease_owner, lease_expires_at,
  worker_build, started_at
) values (
  '92000000-0000-4000-8000-000000000004',
  '92000000-0000-4000-8000-000000000003', 1, 'leased', 'worker-classifier-test',
  statement_timestamp() + interval '5 minutes', 'worker-classifier-test', statement_timestamp()
);

create temporary table classifier_artifact_fixture (claim jsonb not null);
insert into classifier_artifact_fixture (claim) values
  (jsonb_build_object('role','thumbnail','digest',repeat('9',64),'byte_count',1024,'media_type','image/jpeg','width',512,'height',512,'duration_ms',0,'frame_rate_numerator',0,'frame_rate_denominator',0,'codec','jpeg','pixel_format','yuvj420p','color_space','sRGB','has_audio',false)),
  (jsonb_build_object('role','poster','digest',repeat('a',64),'byte_count',2048,'media_type','image/jpeg','width',1920,'height',1080,'duration_ms',0,'frame_rate_numerator',0,'frame_rate_denominator',0,'codec','jpeg','pixel_format','yuvj420p','color_space','sRGB','has_audio',false)),
  (jsonb_build_object('role','preview','digest',repeat('b',64),'byte_count',4096,'media_type','video/mp4','width',960,'height',540,'duration_ms',5000,'frame_rate_numerator',30,'frame_rate_denominator',1,'codec','h264','pixel_format','yuv420p','color_space','bt709','has_audio',false)),
  (jsonb_build_object('role','video_default','digest',repeat('c',64),'byte_count',8192,'media_type','video/mp4','width',1920,'height',1080,'duration_ms',30000,'frame_rate_numerator',30,'frame_rate_denominator',1,'codec','h264','pixel_format','yuv420p','color_space','bt709','has_audio',false));

do $$
declare artifact jsonb; extension text; object_path text;
begin
  for artifact in select claim from classifier_artifact_fixture loop
    if not wali.worker_authorize_staged_artifact(
      '92000000-0000-4000-8000-000000000004', 1, 'worker-classifier-test', artifact
    ) then
      raise exception 'classifier artifact authorization failed';
    end if;
    extension := case artifact ->> 'media_type' when 'image/jpeg' then 'jpg' else 'mp4' end;
    object_path := 'sha256/' || substring((artifact ->> 'digest') from 1 for 2) || '/' ||
      substring((artifact ->> 'digest') from 3 for 2) || '/' || (artifact ->> 'digest') || '/' ||
      replace((artifact ->> 'role'), '_', '-') || '.' || extension;
    insert into storage.objects (bucket_id, name, metadata)
    values ('processing-private', object_path,
      jsonb_build_object('mimetype', artifact ->> 'media_type', 'size', (artifact ->> 'byte_count')::bigint));
  end loop;
end $$;

select ok(
  wali.worker_complete_attempt(
    '92000000-0000-4000-8000-000000000004', 1, 'worker-classifier-test',
    jsonb_build_object(
      'source_digest', repeat('d', 64),
      'artifacts', (select jsonb_agg(claim order by claim ->> 'role') from classifier_artifact_fixture),
      'classification', (select result from classifier_test_fixture)
    )
  ),
  'worker completion accepts and atomically persists the exact classifier contract'
);

select is(
  (select count(*) from wali.classification_runs
    where attempt_id = '92000000-0000-4000-8000-000000000004' and status = 'completed'),
  1::bigint,
  'worker completion persists one provenance-bound classification run without embedding blobs in raw_result'
);

select is(
  (select count(*) from wali.submission_tag_suggestions
    where submission_id = '92000000-0000-4000-8000-000000000003'
      and source = 'classifier'),
  1::bigint,
  'worker completion persists bounded classifier tag suggestions'
);

select is(
  (select count(*) from wali.wallpaper_embeddings
    where wallpaper_id = '92000000-0000-4000-8000-000000000002'),
  3::bigint,
  'worker completion persists all three 768-dimensional embeddings separately'
);

insert into wali.rights_declarations (
  submission_id, basis, rights_holder, license_id, attribution_text,
  attested_at, creator_terms_version, review_status, reviewed_by, reviewed_at
) values (
  '92000000-0000-4000-8000-000000000003', 'original', 'WALI Test',
  '20000000-0000-0000-0000-000000000001', 'Synthetic test attribution.',
  statement_timestamp(), '2026-09-01', 'approved',
  '00000000-0000-0000-0000-000000000004', statement_timestamp()
);

select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select is(
  public.creator_metadata_v1() -> 'rights_bases' -> 2 ->> 'available', 'true',
  'creator metadata exposes licensed attestations under the automatic publication policy'
);
select cmp_ok(
  jsonb_array_length(public.my_creator_submissions_v1(null, 24) -> 'items'), '>=', 1,
  'creator submission projection is owner-scoped and includes rich draft and processing state'
);
select is(
  public.creator_processing_status_v1('92000000-0000-4000-8000-000000000003', 1) ->> 'generation',
  '1', 'creator processing projection is bound to the requested generation'
);
select set_config('request.jwt.claim.role', 'service_role', true);

update wali.submissions set status = 'submitted', submitted_at = statement_timestamp()
 where id = '92000000-0000-4000-8000-000000000003';
update wali.submissions set status = 'under_review'
 where id = '92000000-0000-4000-8000-000000000003';

select is(
  array(select artifact ->> 'role' from jsonb_array_elements(
    public.moderation_queue_v1(
      '00000000-0000-0000-0000-000000000004', 'aal2',
      'pending', 'oldest_submitted', null, 24
    ) -> 'items' -> 0 -> 'canonical_artifacts'
  ) artifact order by artifact ->> 'role'),
  array['poster', 'preview', 'video_default'],
  'moderation queue exposes the current poster, preview, and full review video'
);
select is(
  jsonb_typeof(public.moderation_reports_v1(
    '00000000-0000-0000-0000-000000000004', 'aal2', null, 24
  ) -> 'items'), 'array', 'moderation report projection is bounded and role-gated'
);

select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000004","role":"authenticated","aal":"aal2"}', true);
select is(public.moderation_metadata_v1() ->> 'checklist_revision', '1',
  'moderation policy metadata is server-owned and revisioned');
select ok(
  wali.moderator_can_preview_canonical(
    'processing-private',
    (select staged.storage_path from wali.staged_artifacts staged
      join wali.processing_attempts attempt on attempt.id = staged.verified_by_attempt_id
      where attempt.submission_id = '92000000-0000-4000-8000-000000000003'
      order by staged.storage_path limit 1)
  ), 'AAL2 moderator can read only a current canonical review artifact'
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select throws_ok(
  $$select public.moderation_metadata_v1()$$,
  'P0001', 'WALI_MODERATOR_AAL2_REQUIRED',
  'ordinary creator cannot read moderator controls or policy metadata'
);
select ok(
  not wali.moderator_can_preview_canonical(
    'processing-private',
    (select staged.storage_path from wali.staged_artifacts staged
      join wali.processing_attempts attempt on attempt.id = staged.verified_by_attempt_id
      where attempt.submission_id = '92000000-0000-4000-8000-000000000003'
      order by staged.storage_path limit 1)
  ), 'ordinary creator cannot read canonical moderation artifacts'
);
select set_config('request.jwt.claim.role', 'service_role', true);
select throws_ok(
  $$select public.moderation_queue_v1(
    '00000000-0000-0000-0000-000000000002', 'aal2',
    'pending', 'oldest_submitted', null, 24)$$,
  'P0001', 'WALI_MODERATOR_AAL2_REQUIRED',
  'service boundary still rejects a caller without a current moderator grant'
);
select throws_ok(
  $$select public.wali_edge_moderate_submission_v1(
    '00000000-0000-0000-0000-000000000004', 'aal2',
    '96000000-0000-4000-8000-000000000001', 'moderation_reason_policy_001',
    '92000000-0000-4000-8000-000000000003',
    (select revision from wali.submissions where id = '92000000-0000-4000-8000-000000000003'),
    1, 'approved', 1, array['unsafe_content'], 'Approved.', null)$$,
  'P0001', 'WALI_MODERATION_INPUT_INVALID',
  'moderation command accepts only reason codes allowed for the selected decision'
);

create temporary table revocation_prepare_fixture as
select public.wali_edge_prepare_catalog_revocation_v1(
  '00000000-0000-0000-0000-000000000001', 'aal2', 'catalog_revoke_000000000000001',
  '40000000-0000-0000-0000-000000000001', repeat('4', 64),
  1, 0, 'critical_security'
) as prepared;

create temporary table revocation_document_fixture as
select jsonb_build_object(
  'schema', jsonb_build_object('epoch', 1, 'revision', 0),
  'key_id', prepared ->> 'key_id',
  'revision', (prepared ->> 'revision')::bigint,
  'issued_at', prepared ->> 'issued_at',
  'revocations', prepared -> 'revocations'
) as document
from revocation_prepare_fixture;

create temporary table revocation_result_fixture as
select public.wali_edge_finalize_catalog_revocation_v1(
  '00000000-0000-0000-0000-000000000001', 'aal2',
  '93000000-0000-4000-8000-000000000001', 'catalog_revoke_000000000000001',
  '40000000-0000-0000-0000-000000000001', repeat('4', 64),
  1, 0, 'critical_security',
  translate(encode(convert_to(document::text, 'UTF8'), 'base64'), E'+/=\n\r', '-_'),
  translate(encode(decode(repeat('24', 64), 'hex'), 'base64'), E'+/=\n\r', '-_'),
  'catalog-local-1'
) as result
from revocation_document_fixture;

select is(
  (select result ->> 'revision' from revocation_result_fixture), '2',
  'a security responder publishes the next cumulative signed revocation revision'
);

select is(
  (select count(*) from wali.catalog_revocations
    where release_id = '40000000-0000-0000-0000-000000000001'
      and artifact_digest = repeat('4', 64)
      and reason = 'critical_security'),
  1::bigint,
  'revocation publication atomically materializes the exact server-side install denial row'
);

select is(
  (select status::text from wali.wallpaper_releases
    where id = '40000000-0000-0000-0000-000000000001'),
  'revoked',
  'revocation publication marks the targeted published release revoked'
);

select throws_ok(
  $$select public.wali_edge_request_install_v1(
      '00000000-0000-0000-0000-000000000006',
      '93000000-0000-4000-8000-000000000002',
      'revoked_install_000000000001',
      '30000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      (select revision from wali.wallpapers where id = '30000000-0000-0000-0000-000000000001')
    )$$,
  'P0001', 'WALI_RELEASE_NOT_AVAILABLE',
  'the install command fails closed immediately after revocation materialization'
);

select is(
  (select public.wali_edge_prepare_catalog_revocation_v1(
    '00000000-0000-0000-0000-000000000001', 'aal2', 'catalog_revoke_000000000000001',
    '40000000-0000-0000-0000-000000000001', repeat('4', 64),
    1, 0, 'critical_security'
  ) -> 'response'),
  (select result from revocation_result_fixture),
  'the prepare boundary replays a completed revocation before checking post-revocation state'
);

select is(
  (select public.wali_edge_finalize_catalog_revocation_v1(
    '00000000-0000-0000-0000-000000000001', 'aal2',
    '93000000-0000-4000-8000-000000000009', 'catalog_revoke_000000000000001',
    '40000000-0000-0000-0000-000000000001', repeat('4', 64),
    1, 0, 'critical_security',
    translate(encode(convert_to(document::text, 'UTF8'), 'base64'), E'+/=\n\r', '-_'),
    translate(encode(decode(repeat('24', 64), 'hex'), 'base64'), E'+/=\n\r', '-_'),
    'catalog-local-1'
  ) - 'replayed' from revocation_document_fixture),
  (select result from revocation_result_fixture),
  'revocation retry replays the exact response without a second audit or catalog row'
);

select * from finish();
rollback;
