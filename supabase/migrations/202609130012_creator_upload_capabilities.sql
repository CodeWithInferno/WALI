-- ADR0027: advertise only the formats admitted by the existing still-intake gate.
-- CREATE OR REPLACE preserves this authenticated function identity and grants.
begin;
create or replace function public.creator_metadata_v1()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor_id uuid := auth.uid(); response jsonb;
begin
  if actor_id is null or not exists (select 1 from wali.profiles profile
    where profile.id = actor_id and profile.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  select jsonb_build_object(
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', category.id, 'name', category.name, 'slug', category.slug
    ) order by category.sort_order, category.slug), '[]'::jsonb) from wali.categories category where category.active),
    'tags', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', tag.id, 'name', tag.label, 'slug', tag.slug
    ) order by tag.slug), '[]'::jsonb) from wali.tags tag where tag.active),
    'licenses', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', license.id, 'name', license.name, 'code', license.code, 'terms_url', license.terms_url,
      'requirements', jsonb_build_object(
        'requires_source_url', false,
        'requires_attribution', license.attribution_required,
        'requires_proof', false)
    ) order by license.code), '[]'::jsonb) from wali.licenses license
      where license.active and license.redistribution_allowed),
    'rights_bases', jsonb_build_array(
      jsonb_build_object('basis', 'original', 'available', true,
        'requires_source_url', false, 'requires_proof', false),
      jsonb_build_object('basis', 'public_domain', 'available', true,
        'requires_source_url', true, 'requires_proof', false),
      jsonb_build_object('basis', 'licensed', 'available', true,
        'requires_source_url', true, 'requires_proof', false),
      jsonb_build_object('basis', 'other', 'available', false,
        'requires_source_url', false, 'requires_proof', true)
    ),
    'supported_upload_media_types', (select case when config.still_uploads_enabled
      then jsonb_build_array('video/mp4', 'video/quicktime', 'image/jpeg', 'image/png')
      else jsonb_build_array('video/mp4', 'video/quicktime') end
      from wali.runtime_configuration config where config.singleton),
    'current_creator_terms_version', (select config.creator_terms_version
      from wali.runtime_configuration config where config.singleton)
  ) into response;
  return response;
end $$;
commit;
