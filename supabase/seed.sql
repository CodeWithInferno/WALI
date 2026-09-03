-- Deterministic, synthetic-only local marketplace fixtures.
-- No row below references production identities, credentials, or third-party media.

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000'::uuid,
  ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
  'authenticated', 'authenticated', email,
  crypt('local-only-password', gen_salt('bf')), statement_timestamp(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('display_name', display_name), statement_timestamp(), statement_timestamp()
from (values
  (1, 'admin@example.invalid', 'Local Admin'),
  (2, 'creator-a@example.invalid', 'Synthetic Studio'),
  (3, 'user-b@example.invalid', 'Local User'),
  (4, 'moderator@example.invalid', 'Local Moderator'),
  (5, 'suspended@example.invalid', 'Suspended Fixture'),
  (6, 'creator-b@example.invalid', 'Second Studio')
) as fixture(n, email, display_name)
on conflict (id) do nothing;

insert into wali.categories (id, slug, name, description, sort_order) values
  ('10000000-0000-0000-0000-000000000013', 'city', 'City', 'Classifier-controlled city and urban environments.', 130),
  ('10000000-0000-0000-0000-000000000014', 'illustration', 'Illustration', 'Classifier-controlled illustrated scenes.', 140)
on conflict (slug) do nothing;

update wali.profiles set handle = fixture.handle::extensions.citext
from (values
  ('00000000-0000-0000-0000-000000000001'::uuid, 'local_admin'),
  ('00000000-0000-0000-0000-000000000002'::uuid, 'synthetic_studio'),
  ('00000000-0000-0000-0000-000000000003'::uuid, 'local_user'),
  ('00000000-0000-0000-0000-000000000004'::uuid, 'local_moderator'),
  ('00000000-0000-0000-0000-000000000005'::uuid, 'suspended_fixture'),
  ('00000000-0000-0000-0000-000000000006'::uuid, 'second_studio')
) as fixture(id, handle)
where wali.profiles.id = fixture.id;

update wali.profiles set status = 'suspended'
where id = '00000000-0000-0000-0000-000000000005';

insert into wali.runtime_configuration (
  singleton, environment, catalog_public_base_url, creator_terms_version, media_policy_digest
) values (
  true, 'local', 'https://example.invalid/storage/v1/object/public/catalog-public', '2026-09-01',
  '9710d4e665b29989a0c6109c1f807ae5fb52ef009536194663b365ae06e28875'
) on conflict (singleton) do update set
  environment = excluded.environment,
  catalog_public_base_url = excluded.catalog_public_base_url,
  creator_terms_version = excluded.creator_terms_version,
  media_policy_digest = excluded.media_policy_digest;

insert into wali.role_grants (user_id, role, granted_by, reason) values
  ('00000000-0000-0000-0000-000000000001', 'admin', '00000000-0000-0000-0000-000000000001', 'local deterministic seed'),
  ('00000000-0000-0000-0000-000000000002', 'creator', '00000000-0000-0000-0000-000000000001', 'local deterministic seed'),
  ('00000000-0000-0000-0000-000000000004', 'moderator', '00000000-0000-0000-0000-000000000001', 'local deterministic seed'),
  ('00000000-0000-0000-0000-000000000006', 'creator', '00000000-0000-0000-0000-000000000001', 'local deterministic seed')
on conflict (user_id, role) where revoked_at is null do nothing;

insert into wali.security_response_grants (user_id, granted_by)
values ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001')
on conflict (user_id) do nothing;

insert into wali.terms_acceptances (
  user_id, document_kind, document_version, request_id
) values
  ('00000000-0000-0000-0000-000000000002', 'creator_terms', '2026-09-01', '00000000-0000-4000-8000-000000000021'),
  ('00000000-0000-0000-0000-000000000006', 'creator_terms', '2026-09-01', '00000000-0000-4000-8000-000000000022')
on conflict (user_id, document_kind, document_version) do nothing;

insert into wali.creator_profiles (
  user_id, bio, website_url, verification_status, verified_at, verified_by
) values
  ('00000000-0000-0000-0000-000000000002', 'Synthetic creator used only by local marketplace tests.', 'https://example.invalid/synthetic-studio', 'verified', statement_timestamp(), '00000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000006', 'Second synthetic creator used for diversity fixtures.', 'https://example.invalid/second-studio', 'verified', statement_timestamp(), '00000000-0000-0000-0000-000000000001')
on conflict (user_id) do nothing;

insert into wali.licenses (
  id, code, name, terms_url, attribution_required, commercial_use_allowed,
  derivatives_allowed, redistribution_allowed, terms_revision
) values (
  '20000000-0000-0000-0000-000000000001', 'wali-synthetic-fixture',
  'WALI Synthetic Fixture License', 'https://example.invalid/wali-synthetic-fixture-license',
  true, true, true, true, 1
) on conflict (id) do nothing;

insert into wali.categories (id, slug, name, description, sort_order)
select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
  slug, name, description, n * 10
from (values
  (1, 'nature', 'Nature', 'Landscapes and natural environments.'),
  (2, 'space', 'Space', 'Stars, planets, and imagined cosmic scenes.'),
  (3, 'abstract', 'Abstract', 'Abstract color, geometry, and motion.'),
  (4, 'anime-illustration', 'Anime & Illustration', 'Illustrated and animated artwork.'),
  (5, 'games', 'Games', 'Game-inspired scenes with documented rights.'),
  (6, 'film-tv', 'Film & TV', 'Film and television material with documented rights.'),
  (7, 'cars', 'Cars', 'Automotive scenes and motion.'),
  (8, 'cities', 'Cities', 'Cityscapes and urban environments.'),
  (9, 'technology', 'Technology', 'Digital systems and technology-inspired scenes.'),
  (10, 'minimal', 'Minimal', 'Quiet, low-complexity compositions.'),
  (11, 'retro', 'Retro', 'Historical and retro-inspired aesthetics.'),
  (12, 'other', 'Other', 'Material not represented by another active category.')
) as fixture(n, slug, name, description)
on conflict (id) do nothing;

insert into wali.tags (id, slug, label, kind) values
  ('11000000-0000-0000-0000-000000000009', 'mountains', 'Mountains', 'subject'),
  ('11000000-0000-0000-0000-000000000010', 'ocean', 'Ocean', 'subject'),
  ('11000000-0000-0000-0000-000000000011', 'forest', 'Forest', 'subject'),
  ('11000000-0000-0000-0000-000000000012', 'aurora', 'Aurora', 'subject'),
  ('11000000-0000-0000-0000-000000000013', 'rain', 'Rain', 'setting'),
  ('11000000-0000-0000-0000-000000000014', 'minimal', 'Minimal', 'style'),
  ('11000000-0000-0000-0000-000000000015', 'neon', 'Neon', 'style'),
  ('11000000-0000-0000-0000-000000000016', 'cyber', 'Cyber', 'style'),
  ('11000000-0000-0000-0000-000000000017', 'energetic', 'Energetic', 'mood'),
  ('11000000-0000-0000-0000-000000000018', 'dark', 'Dark', 'mood'),
  ('11000000-0000-0000-0000-000000000019', 'colorful', 'Colorful', 'color'),
  ('11000000-0000-0000-0000-000000000020', 'loop', 'Loop', 'motion')
on conflict (slug) do nothing;

insert into wali.tags (id, slug, label, kind)
select ('11000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
  slug, label, kind::wali.tag_kind
from (values
  (1, 'gradient', 'Gradient', 'style'), (2, 'calm', 'Calm', 'mood'),
  (3, 'blue', 'Blue', 'color'), (4, 'slow-motion', 'Slow Motion', 'motion'),
  (5, 'stars', 'Stars', 'subject'), (6, 'night', 'Night', 'setting'),
  (7, 'synthetic', 'Synthetic', 'format'), (8, 'vivid', 'Vivid', 'style')
) as fixture(n, slug, label, kind)
on conflict (id) do nothing;

insert into wali.catalog_signing_keys (
  key_id, public_key, valid_from, status, activated_by, activated_at
) values (
  'catalog-local-1', decode('81497566ab97f243b6171798fb52fe015f8a671be0e0ec9ca6df39e5c384828b', 'hex'), '2026-01-01T00:00:00Z',
  'active', '00000000-0000-0000-0000-000000000001', statement_timestamp()
) on conflict (key_id) do nothing;

insert into wali.catalog_signed_documents (
  kind, revision, issued_at, body, body_digest, signature, signing_key_id,
  created_by, request_id
)
select 'revocations', 1, '2026-09-01T00:00:00Z', fixture.body,
  encode(extensions.digest(fixture.body, 'sha256'), 'hex'),
  decode('ef23ee09c75edd0fc72e644e1f72b28567136a33518586d282151a50d934bf5de84ce2623fb1804be84f0a792e8b2d1c3760316a190ffa54af9a50740362a807', 'hex'),
  'catalog-local-1', '00000000-0000-0000-0000-000000000001',
  '99000000-0000-4000-8000-000000000001'
from (values (convert_to('{"schema":{"epoch":1,"revision":0},"key_id":"catalog-local-1","revision":1,"issued_at":"2026-09-01T00:00:00Z","revocations":[]}', 'UTF8'))) fixture(body)
on conflict (kind, revision) do nothing;

insert into wali.model_registry (
  model_id, model_revision, task, source_url, upstream_license, artifact_digest,
  embedding_dimension, taxonomy_revision, approved_labels, approved_by, approved_at, status
) values (
  'google/siglip-base-patch16-224', '7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed', 'classification',
  'https://huggingface.co/google/siglip-base-patch16-224', 'Apache-2.0',
  '2a86b6bf585b3b071c5ccc46a01c18abb08b018dacc868513e592da7bcc9f877',
  768, 'wali-taxonomy-v1',
  '["category:nature","category:space","category:city","category:abstract","category:technology","category:illustration","tag:mountains","tag:ocean","tag:forest","tag:night","tag:aurora","tag:rain","tag:minimal","tag:neon","tag:cyber","tag:calm","tag:energetic","tag:dark","tag:colorful","tag:loop"]',
  '00000000-0000-0000-0000-000000000001',
  statement_timestamp(), 'active'
) on conflict (model_id, model_revision) do nothing;

insert into wali.upload_sessions (
  id, creator_id, storage_path, original_filename, declared_byte_count,
  received_byte_count, source_digest, detected_media_type, status, expires_at,
  completed_at, idempotency_key, created_at, updated_at, declared_media_type, storage_version
) values
  ('70000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000002/70000000-0000-0000-0000-000000000001/source', 'synthetic-blue-loop.mp4', 4096, 4096, repeat('a', 64), 'video/mp4', 'completed', '2026-10-01T00:00:00Z', '2026-09-01T00:00:00Z', '70000000-0000-0000-0000-000000000011', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z', 'video/mp4', 'local-fixture-v1'),
  ('70000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000006/70000000-0000-0000-0000-000000000002/source', 'synthetic-star-loop.mp4', 4096, 4096, repeat('b', 64), 'video/mp4', 'completed', '2026-10-01T00:00:00Z', '2026-09-01T00:00:00Z', '70000000-0000-0000-0000-000000000012', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z', 'video/mp4', 'local-fixture-v1')
on conflict (id) do nothing;

insert into wali.wallpapers (
  id, creator_id, slug, title, description, primary_category_id, license_id,
  rights_holder_display, attribution_text, source_url, status, visibility, content_rating
) values
  ('30000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'synthetic-blue-drift', 'Synthetic Blue Drift', 'A generated blue gradient fixture with slow motion.', '10000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 'WALI Project', 'Generated locally for WALI testing.', 'https://example.invalid/wali-fixtures/blue-drift', 'draft', 'public', 'everyone'),
  ('30000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000006', 'synthetic-star-field', 'Synthetic Star Field', 'A generated star-field fixture used for stable pagination.', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', 'WALI Project', 'Generated locally for WALI testing.', 'https://example.invalid/wali-fixtures/star-field', 'draft', 'public', 'everyone')
on conflict (id) do nothing;

insert into wali.submissions (
  id, creator_id, wallpaper_id, proposed_title, proposed_description,
  primary_category_id, license_id, rights_holder, attribution_text, source_url,
  upload_session_id, status, generation, submitted_at, decided_at, created_at, updated_at
) values
  ('71000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000001', 'Synthetic Blue Drift', 'A generated blue gradient fixture with slow motion.', '10000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 'WALI Project', 'Generated locally for WALI testing.', 'https://example.invalid/wali-fixtures/blue-drift', '70000000-0000-0000-0000-000000000001', 'approved', 1, '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z'),
  ('71000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000006', '30000000-0000-0000-0000-000000000002', 'Synthetic Star Field', 'A generated star-field fixture used for stable pagination.', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', 'WALI Project', 'Generated locally for WALI testing.', 'https://example.invalid/wali-fixtures/star-field', '70000000-0000-0000-0000-000000000002', 'approved', 1, '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z')
on conflict (id) do nothing;

insert into wali.rights_declarations (
  id, submission_id, basis, rights_holder, license_id, source_url, attribution_text,
  attested_at, creator_terms_version, review_status, reviewed_by, reviewed_at
) values
  ('71100000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', 'original', 'WALI Project', '20000000-0000-0000-0000-000000000001', 'https://example.invalid/wali-fixtures/blue-drift', 'Generated locally for WALI testing.', '2026-09-01T00:00:00Z', '2026-09-01', 'approved', '00000000-0000-0000-0000-000000000004', '2026-09-01T00:00:00Z'),
  ('71100000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000002', 'original', 'WALI Project', '20000000-0000-0000-0000-000000000001', 'https://example.invalid/wali-fixtures/star-field', 'Generated locally for WALI testing.', '2026-09-01T00:00:00Z', '2026-09-01', 'approved', '00000000-0000-0000-0000-000000000004', '2026-09-01T00:00:00Z')
on conflict (id) do nothing;

insert into wali.processing_attempts (
  id, submission_id, generation, status, worker_build, media_image_digest,
  classifier_image_digest, started_at, finished_at, output_summary, created_at, updated_at
) values
  ('72000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', 1, 'completed', 'local-fixture-worker', repeat('c', 64), repeat('d', 64), '2026-09-01T00:00:00Z', '2026-09-01T00:01:00Z', '{"verified":true,"synthetic":true}', '2026-09-01T00:00:00Z', '2026-09-01T00:01:00Z'),
  ('72000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000002', 1, 'completed', 'local-fixture-worker', repeat('e', 64), repeat('f', 64), '2026-09-01T00:00:00Z', '2026-09-01T00:01:00Z', '{"verified":true,"synthetic":true}', '2026-09-01T00:00:00Z', '2026-09-01T00:01:00Z')
on conflict (id) do nothing;

with bodies(release_id, wallpaper_id, submission_id, body) as (
  values
    ('40000000-0000-0000-0000-000000000001'::uuid, '30000000-0000-0000-0000-000000000001'::uuid, '71000000-0000-0000-0000-000000000001'::uuid,
      convert_to('{"artifacts":[{"byte_count":8192,"height":1080,"media_type":"video/mp4","role":"video_default","sha256":"4444444444444444444444444444444444444444444444444444444444444444","url":"https://example.invalid/catalog/blue/default.mp4","width":1920}],"edition":1,"issued_at":"2026-09-01T00:00:00Z","key_id":"catalog-local-1","metadata_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","release_id":"40000000-0000-0000-0000-000000000001","schema":{"epoch":1,"revision":0},"wallpaper_id":"30000000-0000-0000-0000-000000000001"}', 'UTF8')),
    ('40000000-0000-0000-0000-000000000002'::uuid, '30000000-0000-0000-0000-000000000002'::uuid, '71000000-0000-0000-0000-000000000002'::uuid,
      convert_to('{"artifacts":[{"byte_count":8192,"height":1080,"media_type":"video/mp4","role":"video_default","sha256":"8888888888888888888888888888888888888888888888888888888888888888","url":"https://example.invalid/catalog/stars/default.mp4","width":1920}],"edition":1,"issued_at":"2026-09-01T00:00:00Z","key_id":"catalog-local-1","metadata_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","release_id":"40000000-0000-0000-0000-000000000002","schema":{"epoch":1,"revision":0},"wallpaper_id":"30000000-0000-0000-0000-000000000002"}', 'UTF8'))
)
insert into wali.wallpaper_releases (
  id, wallpaper_id, edition, source_submission_id, status, manifest_epoch,
  manifest_revision, manifest_body, manifest_digest, manifest_signature, signing_key_id
)
select release_id, wallpaper_id, 1, submission_id, 'approved', 1, 0, body,
  encode(digest(body, 'sha256'), 'hex'), decode(repeat('24', 64), 'hex'), 'catalog-local-1'
from bodies
on conflict (id) do nothing;

update wali.wallpaper_releases release set
  metadata_body = fixture.body,
  metadata_digest = encode(digest(fixture.body, 'sha256'), 'hex')
from (values
  (
    '40000000-0000-0000-0000-000000000001'::uuid,
    convert_to('{"schema":"wali.catalog.metadata.v1","wallpaper_id":"30000000-0000-0000-0000-000000000001","release_id":"40000000-0000-0000-0000-000000000001","edition":1,"title":"Synthetic Blue Drift","creator":{"id":"00000000-0000-0000-0000-000000000002","handle":"synthetic_studio","display_name":"Synthetic Studio"},"rights_holder":"WALI Project","attribution":{"text":"Generated locally for WALI testing.","source_url":"https://example.invalid/wali-fixtures/blue-drift","license_code":"wali-synthetic-fixture"}}', 'UTF8')
  ),
  (
    '40000000-0000-0000-0000-000000000002'::uuid,
    convert_to('{"schema":"wali.catalog.metadata.v1","wallpaper_id":"30000000-0000-0000-0000-000000000002","release_id":"40000000-0000-0000-0000-000000000002","edition":1,"title":"Synthetic Star Field","creator":{"id":"00000000-0000-0000-0000-000000000006","handle":"second_studio","display_name":"Second Studio"},"rights_holder":"WALI Project","attribution":{"text":"Generated locally for WALI testing.","source_url":"https://example.invalid/wali-fixtures/star-field","license_code":"wali-synthetic-fixture"}}', 'UTF8')
  )
) fixture(id, body)
where release.id = fixture.id;

with rebound as (
  select id,
    convert_to(
      replace(
        convert_from(manifest_body, 'UTF8'),
        case id
          when '40000000-0000-0000-0000-000000000001'::uuid then repeat('a', 64)
          else repeat('b', 64)
        end,
        metadata_digest
      ),
      'UTF8'
    ) as body
  from wali.wallpaper_releases
  where id in (
    '40000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000002'
  )
)
update wali.wallpaper_releases release set
  manifest_body = rebound.body,
  manifest_digest = encode(digest(rebound.body, 'sha256'), 'hex')
from rebound where release.id = rebound.id;

insert into wali.artifacts (
  digest, media_type, byte_count, storage_bucket, storage_path, width, height,
  duration_ms, frame_rate_numerator, frame_rate_denominator, codec, pixel_format,
  color_space, has_audio, verified_by_attempt_id, created_at
) values
  (repeat('1', 64), 'image/jpeg', 1024, 'catalog-public', 'sha256/11/11/' || repeat('1', 64) || '/thumbnail.jpg', 512, 512, null, null, null, 'jpeg', 'yuvj420p', 'sRGB', false, '72000000-0000-0000-0000-000000000001', '2026-09-01T00:00:00Z'),
  (repeat('2', 64), 'image/jpeg', 2048, 'catalog-public', 'sha256/22/22/' || repeat('2', 64) || '/poster.jpg', 1920, 1080, null, null, null, 'jpeg', 'yuvj420p', 'sRGB', false, '72000000-0000-0000-0000-000000000001', '2026-09-01T00:00:00Z'),
  (repeat('3', 64), 'video/mp4', 4096, 'catalog-public', 'sha256/33/33/' || repeat('3', 64) || '/preview.mp4', 960, 540, 5000, 30, 1, 'h264', 'yuv420p', 'bt709', false, '72000000-0000-0000-0000-000000000001', '2026-09-01T00:00:00Z'),
  (repeat('4', 64), 'video/mp4', 8192, 'catalog-public', 'sha256/44/44/' || repeat('4', 64) || '/default.mp4', 1920, 1080, 30000, 30, 1, 'h264', 'yuv420p', 'bt709', false, '72000000-0000-0000-0000-000000000001', '2026-09-01T00:00:00Z'),
  (repeat('5', 64), 'image/jpeg', 1024, 'catalog-public', 'sha256/55/55/' || repeat('5', 64) || '/thumbnail.jpg', 512, 512, null, null, null, 'jpeg', 'yuvj420p', 'sRGB', false, '72000000-0000-0000-0000-000000000002', '2026-09-01T00:00:00Z'),
  (repeat('6', 64), 'image/jpeg', 2048, 'catalog-public', 'sha256/66/66/' || repeat('6', 64) || '/poster.jpg', 1920, 1080, null, null, null, 'jpeg', 'yuvj420p', 'sRGB', false, '72000000-0000-0000-0000-000000000002', '2026-09-01T00:00:00Z'),
  (repeat('7', 64), 'video/mp4', 4096, 'catalog-public', 'sha256/77/77/' || repeat('7', 64) || '/preview.mp4', 960, 540, 5000, 30, 1, 'h264', 'yuv420p', 'bt709', false, '72000000-0000-0000-0000-000000000002', '2026-09-01T00:00:00Z'),
  (repeat('8', 64), 'video/mp4', 8192, 'catalog-public', 'sha256/88/88/' || repeat('8', 64) || '/default.mp4', 1920, 1080, 30000, 30, 1, 'h264', 'yuv420p', 'bt709', false, '72000000-0000-0000-0000-000000000002', '2026-09-01T00:00:00Z')
on conflict (digest) do nothing;

insert into wali.release_artifacts (release_id, role, artifact_digest, sort_order) values
  ('40000000-0000-0000-0000-000000000001', 'thumbnail', repeat('1', 64), 10),
  ('40000000-0000-0000-0000-000000000001', 'poster', repeat('2', 64), 20),
  ('40000000-0000-0000-0000-000000000001', 'preview', repeat('3', 64), 30),
  ('40000000-0000-0000-0000-000000000001', 'video_default', repeat('4', 64), 40),
  ('40000000-0000-0000-0000-000000000002', 'thumbnail', repeat('5', 64), 10),
  ('40000000-0000-0000-0000-000000000002', 'poster', repeat('6', 64), 20),
  ('40000000-0000-0000-0000-000000000002', 'preview', repeat('7', 64), 30),
  ('40000000-0000-0000-0000-000000000002', 'video_default', repeat('8', 64), 40)
on conflict (release_id, role) do nothing;

update wali.wallpaper_releases set status = 'published'
where id in ('40000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002');

update wali.wallpapers set
  current_release_id = case id
    when '30000000-0000-0000-0000-000000000001' then '40000000-0000-0000-0000-000000000001'::uuid
    else '40000000-0000-0000-0000-000000000002'::uuid
  end,
  status = 'published',
  published_at = case id
    when '30000000-0000-0000-0000-000000000001' then '2026-08-31T12:00:00Z'::timestamptz
    else '2026-08-30T12:00:00Z'::timestamptz
  end
where id in ('30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002');

insert into wali.wallpaper_tags (wallpaper_id, tag_id, source, status, decided_by, decided_at) values
  ('30000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000001', 'editorial', 'approved', '00000000-0000-0000-0000-000000000001', '2026-09-01T00:00:00Z'),
  ('30000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000003', 'editorial', 'approved', '00000000-0000-0000-0000-000000000001', '2026-09-01T00:00:00Z'),
  ('30000000-0000-0000-0000-000000000002', '11000000-0000-0000-0000-000000000005', 'editorial', 'approved', '00000000-0000-0000-0000-000000000001', '2026-09-01T00:00:00Z'),
  ('30000000-0000-0000-0000-000000000002', '11000000-0000-0000-0000-000000000006', 'editorial', 'approved', '00000000-0000-0000-0000-000000000001', '2026-09-01T00:00:00Z')
on conflict (wallpaper_id, tag_id, source) do nothing;

insert into wali.quality_assessments (
  release_id, formula_version, technical_completeness, variant_coverage,
  attribution_completeness, editorial_assessment, report_health, input_snapshot_digest,
  assessed_at
) values
  ('40000000-0000-0000-0000-000000000001', 'quality-v1', 1, 0.8, 1, 0.8, 1, repeat('a', 64), '2026-09-01T00:00:00Z'),
  ('40000000-0000-0000-0000-000000000002', 'quality-v1', 1, 0.8, 1, 0.7, 1, repeat('b', 64), '2026-09-01T00:00:00Z')
on conflict (release_id, formula_version) do nothing;

insert into wali.collections (
  id, slug, title, description, kind, status, active_from, editor_id
) values (
  '73000000-0000-0000-0000-000000000001', 'local-synthetic-picks',
  'Local Synthetic Picks', 'Generated fixtures for local UI and API development.',
  'editorial', 'published', '2026-01-01T00:00:00Z', '00000000-0000-0000-0000-000000000001'
) on conflict (id) do nothing;

insert into wali.collection_items (collection_id, wallpaper_id, ordinal, editorial_caption) values
  ('73000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 10, 'Generated blue motion fixture.'),
  ('73000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', 20, 'Generated star field fixture.')
on conflict (collection_id, wallpaper_id) do nothing;

-- Storage metadata rows exercise RLS and retention locally; no third-party or production bytes are included.
insert into storage.objects (bucket_id, name, owner_id, metadata)
select 'catalog-public', a.storage_path, null,
  jsonb_build_object('mimetype', a.media_type, 'size', a.byte_count, 'synthetic', true)
from wali.artifacts a
on conflict (bucket_id, name) do nothing;
