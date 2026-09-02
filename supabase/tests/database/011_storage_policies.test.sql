begin;

select plan(21);

select results_eq(
  $$select id from storage.buckets where id in (
      'catalog-public', 'exports-private', 'moderation-private', 'uploads-private'
    ) order by id$$,
  $$values ('catalog-public'::text), ('exports-private'), ('moderation-private'), ('uploads-private')$$,
  'all four marketplace buckets exist'
);

select results_eq(
  $$select public from storage.buckets where id = 'catalog-public'$$,
  array[true],
  'only catalog artifacts use a public bucket'
);

select results_eq(
  $$select count(*)::bigint from storage.buckets
     where id in ('uploads-private', 'moderation-private', 'exports-private') and public$$,
  array[0::bigint],
  'raw uploads, evidence, and exports remain private'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '00000000-0000-0000-0000-000000000000', '60000000-0000-0000-0000-000000000001',
  'authenticated', 'authenticated', 'storage-owner@example.invalid', crypt('local-only-password', gen_salt('bf')),
  statement_timestamp(), '{"provider":"email","providers":["email"]}', '{"display_name":"Storage Owner"}',
  statement_timestamp(), statement_timestamp()
) on conflict (id) do nothing;

insert into wali.upload_sessions (
  id, creator_id, storage_path, original_filename, declared_byte_count,
  status, expires_at, idempotency_key
) values (
  '61000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001/61000000-0000-0000-0000-000000000001/source', 'fixture.mp4', 128,
  'issued', statement_timestamp() + interval '1 hour',
  '62000000-0000-0000-0000-000000000001'
);

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;

select lives_ok(
  $$insert into storage.objects (bucket_id, name, owner_id, metadata)
    values (
      'uploads-private', '60000000-0000-0000-0000-000000000001/61000000-0000-0000-0000-000000000001/source',
      '60000000-0000-0000-0000-000000000001', '{"mimetype":"video/mp4","size":128}'
    )$$,
  'creator may upload only to the issued opaque path'
);

select throws_ok(
  $$insert into storage.objects (bucket_id, name, owner_id, metadata)
    values (
      'uploads-private', 'uploads/61000000-0000-0000-0000-000000000099/source',
      '60000000-0000-0000-0000-000000000001', '{"mimetype":"video/mp4","size":128}'
    )$$,
  '42501', null, 'creator cannot guess an unissued upload path'
);

select lives_ok(
  $$update storage.objects set metadata = '{"mimetype":"video/mp4","size":64}'
     where bucket_id = 'uploads-private'
       and name = 'uploads/61000000-0000-0000-0000-000000000001/source'$$,
  'an invisible upload update safely affects no rows'
);

select throws_ok(
  $$insert into storage.objects (bucket_id, name, owner_id, metadata)
    values (
      'catalog-public', 'sha256/aa/bb/' || repeat('a', 64) || '/default.mp4',
      '60000000-0000-0000-0000-000000000001', '{"mimetype":"video/mp4","size":128}'
    )$$,
  '42501', null, 'creator cannot promote bytes into public catalog storage'
);

select results_eq(
  $$select count(*)::bigint from storage.objects where bucket_id = 'uploads-private'$$,
  array[0::bigint],
  'creators cannot list private bucket objects'
);

reset role;
select results_eq(
  $$select metadata ->> 'size' from storage.objects
    where bucket_id = 'uploads-private'
      and name = '60000000-0000-0000-0000-000000000001/61000000-0000-0000-0000-000000000001/source'$$,
  $$values ('128'::text)$$,
  'creator cannot overwrite uploaded bytes'
);

insert into wali.cleanup_object_intents (
  id, bucket_id, storage_path, reason, status, lease_owner, lease_expires_at
) values (
  '63000000-0000-0000-0000-000000000001',
  'uploads-private',
  '60000000-0000-0000-0000-000000000001/61000000-0000-0000-0000-000000000001/source',
  'expired_upload', 'processing', 'worker-a', statement_timestamp() + interval '5 minutes'
);

create temporary table storage_policy_observations (
  name text primary key,
  observed bigint not null
);
grant insert, select on storage_policy_observations to wali_storage_worker;

select set_config('request.jwt.claim.role', 'wali_storage_worker', true);
select set_config('request.jwt.claims', '{"role":"wali_storage_worker","worker_id":"worker-a"}', true);
set local role wali_storage_worker;

insert into storage_policy_observations values (
  'active_visible',
  (select count(*) from storage.objects
    where bucket_id = 'uploads-private'
      and name = '60000000-0000-0000-0000-000000000001/61000000-0000-0000-0000-000000000001/source')
);

select set_config('request.jwt.claims', '{"role":"wali_storage_worker","worker_id":"worker-b"}', true);

insert into storage_policy_observations values (
  'wrong_worker_visible',
  (select count(*) from storage.objects
    where bucket_id = 'uploads-private'
      and name = '60000000-0000-0000-0000-000000000001/61000000-0000-0000-0000-000000000001/source')
);
insert into storage_policy_observations values (
  'wrong_worker_delete_authorized',
  wali.storage_worker_can_delete(
    'uploads-private',
    '60000000-0000-0000-0000-000000000001/61000000-0000-0000-0000-000000000001/source',
    'worker-b'
  )::integer
);
insert into storage_policy_observations values (
  'wrong_path_delete_authorized',
  wali.storage_worker_can_delete('uploads-private', 'unleased/private/object', 'worker-b')::integer
);

reset role;
update wali.cleanup_object_intents
set lease_expires_at = statement_timestamp() - interval '1 second'
where id = '63000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claims', '{"role":"wali_storage_worker","worker_id":"worker-a"}', true);
set local role wali_storage_worker;

insert into storage_policy_observations values (
  'expired_visible',
  (select count(*) from storage.objects
    where bucket_id = 'uploads-private'
      and name = '60000000-0000-0000-0000-000000000001/61000000-0000-0000-0000-000000000001/source')
);
insert into storage_policy_observations values (
  'expired_delete_authorized',
  wali.storage_worker_can_delete(
    'uploads-private',
    '60000000-0000-0000-0000-000000000001/61000000-0000-0000-0000-000000000001/source',
    'worker-a'
  )::integer
);

reset role;
update wali.cleanup_object_intents
set lease_expires_at = statement_timestamp() + interval '5 minutes'
where id = '63000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claims', '{"role":"wali_storage_worker","worker_id":"worker-a"}', true);
set local role wali_storage_worker;

insert into storage_policy_observations values (
  'active_delete_authorized',
  wali.storage_worker_can_delete(
    'uploads-private',
    '60000000-0000-0000-0000-000000000001/61000000-0000-0000-0000-000000000001/source',
    'worker-a'
  )::integer
);

reset role;
select is((select observed from storage_policy_observations where name = 'active_visible'), 1::bigint,
  'the exact worker with an active cleanup lease may observe the private object');
select is((select observed from storage_policy_observations where name = 'wrong_worker_visible'), 0::bigint,
  'a different storage worker cannot observe the leased cleanup object');
select is((select observed from storage_policy_observations where name = 'wrong_worker_delete_authorized'), 0::bigint,
  'a different storage worker cannot delete the leased cleanup object');
select is((select observed from storage_policy_observations where name = 'wrong_path_delete_authorized'), 0::bigint,
  'a storage worker cannot delete an unleased path');
select is((select observed from storage_policy_observations where name = 'expired_visible'), 0::bigint,
  'an expired cleanup lease cannot observe the private object');
select is((select observed from storage_policy_observations where name = 'expired_delete_authorized'), 0::bigint,
  'an expired cleanup lease cannot delete the private object');
select is((select observed from storage_policy_observations where name = 'active_delete_authorized'), 1::bigint,
  'the exact active cleanup lease authorizes deletion of only its frozen object');
select ok(
  (select qual like '%storage_worker_can_delete%'
     from pg_policies where schemaname = 'storage' and tablename = 'objects'
       and policyname = 'wali_worker_delete_leased_private_object'),
  'the Storage DELETE policy is bound to the exact lease authorization predicate'
);
select results_eq(
  $$select count(*)::bigint from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname = 'wali_upload_update'$$,
  array[0::bigint],
  'no upload overwrite policy exists'
);

select is(
  (select allowed_mime_types from storage.buckets where id = 'uploads-private'),
  array['video/mp4', 'video/quicktime']::text[],
  'upload MIME allowlist is explicit'
);

select results_eq(
  $$select file_size_limit from storage.buckets where id = 'uploads-private'$$,
  array[1073741824::bigint],
  'upload byte limit is one GiB'
);

select results_eq(
  $$select count(*)::bigint from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname = 'wali_catalog_public_read'$$,
  array[1::bigint],
  'public catalog read policy exists'
);

select * from finish();
rollback;
