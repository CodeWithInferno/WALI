begin;

select plan(12);

select has_table('wali', 'wallpaper_releases', 'release table exists');
select has_table('wali', 'artifacts', 'artifact table exists');
select has_table('wali', 'release_artifacts', 'release artifact table exists');
select has_index('wali', 'artifacts', 'artifacts_storage_path_key', 'artifact paths are globally unique');
select fk_ok(
  'wali', 'wallpapers', array['current_release_id'],
  'wali', 'wallpaper_releases', array['id'],
  'wallpapers current release is constrained'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '00000000-0000-0000-0000-000000000000', '10000000-0000-0000-0000-000000000001',
  'authenticated', 'authenticated', 'release-owner@example.invalid', crypt('local-only-password', gen_salt('bf')),
  statement_timestamp(), '{"provider":"email","providers":["email"]}', '{"display_name":"Release Owner"}',
  statement_timestamp(), statement_timestamp()
) on conflict (id) do nothing;

insert into wali.licenses (
  id, code, name, terms_url, attribution_required, commercial_use_allowed,
  derivatives_allowed, redistribution_allowed, terms_revision
) values (
  '11000000-0000-0000-0000-000000000001', 'test-license', 'Test License',
  'https://example.invalid/license', false, true, true, true, 1
) on conflict (id) do nothing;

insert into wali.categories (id, slug, name, description)
values ('12000000-0000-0000-0000-000000000001', 'test-category', 'Test Category', 'Synthetic test category')
on conflict (id) do nothing;

insert into wali.wallpapers (
  id, creator_id, slug, title, description, status, visibility, content_rating,
  primary_category_id, license_id, rights_holder_display
) values (
  '13000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
  'immutable-release-test', 'Immutable Release Test', 'Synthetic release invariant fixture',
  'draft', 'public', 'everyone', '12000000-0000-0000-0000-000000000001',
  '11000000-0000-0000-0000-000000000001', 'WALI Test Fixture'
);

insert into wali.upload_sessions (
  id, creator_id, storage_path, original_filename, declared_byte_count,
  received_byte_count, source_digest, detected_media_type, status, expires_at,
  completed_at, idempotency_key, declared_media_type, storage_version
) values
  ('15000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001/15000000-0000-0000-0000-000000000010/source', 'release-one.mp4', 128, 128,
   repeat('e', 64), 'video/mp4', 'completed', statement_timestamp() + interval '1 day',
   statement_timestamp(), '15000000-0000-0000-0000-000000000011', 'video/mp4', 'fixture-version-1'),
  ('15000000-0000-0000-0000-000000000020', '10000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001/15000000-0000-0000-0000-000000000020/source', 'release-two.mp4', 128, 128,
   repeat('f', 64), 'video/mp4', 'completed', statement_timestamp() + interval '1 day',
   statement_timestamp(), '15000000-0000-0000-0000-000000000021', 'video/mp4', 'fixture-version-2');

insert into wali.submissions (
  id, creator_id, wallpaper_id, proposed_title, proposed_description,
  primary_category_id, license_id, rights_holder, upload_session_id,
  status, generation, submitted_at, decided_at
) values
  ('15000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '13000000-0000-0000-0000-000000000001', 'Immutable Release Test', 'Synthetic release one',
   '12000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000001',
   'WALI Test Fixture', '15000000-0000-0000-0000-000000000010', 'approved', 1,
   statement_timestamp(), statement_timestamp()),
  ('15000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '13000000-0000-0000-0000-000000000001', 'Immutable Release Test Two', 'Synthetic release two',
   '12000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000001',
   'WALI Test Fixture', '15000000-0000-0000-0000-000000000020', 'approved', 2,
   statement_timestamp(), statement_timestamp());

insert into wali.catalog_signing_keys (
  key_id, public_key, valid_from, status
) values (
  'catalog-test-1', decode(repeat('ab', 32), 'hex'), statement_timestamp(), 'pending'
);

insert into wali.wallpaper_releases (
  id, wallpaper_id, edition, source_submission_id, status,
  manifest_epoch, manifest_revision, manifest_body, manifest_digest, manifest_signature,
  signing_key_id, published_at
) values (
  '14000000-0000-0000-0000-000000000001', '13000000-0000-0000-0000-000000000001',
  1, '15000000-0000-0000-0000-000000000001', 'approved', 1, 0,
  convert_to('{"fixture":"immutable-release"}', 'UTF8'),
  encode(digest(convert_to('{"fixture":"immutable-release"}', 'UTF8'), 'sha256'), 'hex'),
  decode(repeat('01', 64), 'hex'), 'catalog-test-1', statement_timestamp()
);

insert into wali.artifacts (
  digest, media_type, byte_count, storage_bucket, storage_path,
  width, height, duration_ms, frame_rate_numerator, frame_rate_denominator,
  codec, pixel_format, color_space, has_audio
) values
  (repeat('9', 64), 'image/jpeg', 16, 'catalog-public', 'sha256/99/99/' || repeat('9', 64) || '/thumbnail.jpg', 512, 512, null, null, null, 'jpeg', 'yuvj420p', 'sRGB', false),
  (repeat('a', 64), 'image/jpeg', 32, 'catalog-public', 'sha256/aa/aa/' || repeat('a', 64) || '/poster.jpg', 1920, 1080, null, null, null, 'jpeg', 'yuvj420p', 'sRGB', false),
  (repeat('b', 64), 'video/mp4', 64, 'catalog-public', 'sha256/bb/bb/' || repeat('b', 64) || '/preview.mp4', 960, 540, 5000, 30, 1, 'h264', 'yuv420p', 'bt709', false),
  (repeat('c', 64), 'video/mp4', 128, 'catalog-public', 'sha256/cc/cc/' || repeat('c', 64) || '/default.mp4', 1920, 1080, 30000, 30, 1, 'h264', 'yuv420p', 'bt709', false);

insert into wali.release_artifacts (release_id, role, artifact_digest, sort_order) values
  ('14000000-0000-0000-0000-000000000001', 'thumbnail', repeat('9', 64), 10),
  ('14000000-0000-0000-0000-000000000001', 'poster', repeat('a', 64), 20),
  ('14000000-0000-0000-0000-000000000001', 'preview', repeat('b', 64), 30),
  ('14000000-0000-0000-0000-000000000001', 'video_default', repeat('c', 64), 40);

update wali.wallpaper_releases set status = 'published'
where id = '14000000-0000-0000-0000-000000000001';

select throws_ok(
  $$update wali.wallpaper_releases set manifest_digest = repeat('b', 64)
     where id = '14000000-0000-0000-0000-000000000001'$$,
  'P0001', 'WALI_RELEASE_IMMUTABLE', 'published release media and manifest facts are immutable'
);

select throws_ok(
  $$update wali.artifacts set byte_count = 999 where digest = repeat('9', 64)$$,
  'P0001', 'WALI_ARTIFACT_IMMUTABLE', 'artifact facts are immutable'
);

select throws_ok(
  $$delete from wali.release_artifacts
     where release_id = '14000000-0000-0000-0000-000000000001' and role = 'poster'$$,
  'P0001', 'WALI_RELEASE_IMMUTABLE', 'published release bindings are immutable'
);

select lives_ok(
  $$update wali.wallpapers
       set current_release_id = '14000000-0000-0000-0000-000000000001',
           status = 'published', published_at = statement_timestamp()
     where id = '13000000-0000-0000-0000-000000000001'$$,
  'matching published release can become current'
);

select throws_ok(
  $$insert into wali.artifacts (
      digest, media_type, byte_count, storage_bucket, storage_path,
      width, height, codec, pixel_format, color_space, has_audio
    ) values (
      repeat('d', 64), 'image/jpeg', 8, 'catalog-public',
      'sha256/99/99/' || repeat('9', 64) || '/thumbnail.jpg',
      10, 10, 'jpeg', 'yuvj420p', 'sRGB', false
    )$$,
  '23514', null, 'one storage path cannot identify a different digest'
);

select throws_ok(
  $$insert into wali.wallpaper_releases (
      wallpaper_id, edition, source_submission_id, status, manifest_epoch, manifest_revision,
      manifest_body, manifest_digest, manifest_signature, signing_key_id
    ) values (
      '13000000-0000-0000-0000-000000000001', 2,
      '15000000-0000-0000-0000-000000000002', 'published', 1, 0,
      convert_to('{"fixture":"missing-artifacts"}', 'UTF8'),
      encode(digest(convert_to('{"fixture":"missing-artifacts"}', 'UTF8'), 'sha256'), 'hex'),
      decode(repeat('02', 64), 'hex'), 'catalog-test-1'
    )$$,
  'P0001', 'WALI_RELEASE_REQUIRED_ARTIFACTS', 'release cannot publish without required artifacts'
);

select results_eq(
  $$select count(*)::bigint from information_schema.role_table_grants
     where table_schema = 'wali' and table_name in ('wallpaper_releases', 'artifacts', 'release_artifacts')
       and grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE', 'DELETE')$$,
  array[0::bigint],
  'authenticated cannot mutate releases or artifacts'
);

select * from finish();
rollback;
