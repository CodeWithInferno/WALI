-- Additive catalog detail playback artifact for marketplace heroes.
-- CREATE OR REPLACE VIEW may only append columns; video_default is last.
-- Public artifact URLs must use the environment Storage origin from
-- wali.runtime_configuration, matching catalog_wallpapers_v1.

create or replace view public.catalog_wallpaper_details_v1
with (security_invoker = true, security_barrier = true) as
select to_jsonb(summary) as wallpaper, w.description, r.edition,
  w.rights_holder_display as rights_holder, w.attribution_text, w.source_url,
  jsonb_build_object(
    'code', l.code, 'name', l.name, 'terms_url', l.terms_url,
    'attribution_required', l.attribution_required,
    'commercial_use_allowed', l.commercial_use_allowed,
    'derivatives_allowed', l.derivatives_allowed,
    'redistribution_allowed', l.redistribution_allowed,
    'terms_revision', l.terms_revision
  ) as license,
  video.duration_ms, video.width, video.height,
  video.frame_rate_numerator, video.frame_rate_denominator,
  coalesce(viewer_favorite.active, false) as is_favorite,
  coalesce(viewer_favorite.revision, 0) as favorite_revision,
  coalesce(viewer_saved.active, false) as is_saved,
  coalesce(viewer_saved.revision, 0) as saved_revision,
  coalesce(related.items, '[]'::jsonb) as related,
  video.artifact as video_default
from public.catalog_wallpapers_v1 summary
join wali.runtime_configuration cfg on cfg.singleton
join wali.wallpapers w on w.id = summary.id
join wali.wallpaper_releases r on r.id = summary.current_release_id
join wali.licenses l on l.id = w.license_id
join lateral (
  select a.duration_ms, a.width, a.height, a.frame_rate_numerator, a.frame_rate_denominator,
    jsonb_build_object(
      'role', ra.role::text,
      'url', cfg.catalog_public_base_url || '/' || a.storage_path,
      'sha256', a.digest, 'byte_count', a.byte_count, 'media_type', a.media_type,
      'width', a.width, 'height', a.height, 'duration_ms', a.duration_ms
    ) as artifact
  from wali.release_artifacts ra join wali.artifacts a on a.digest = ra.artifact_digest
  where ra.release_id = r.id and ra.role = 'video_default'
) video on true
left join wali.favorites viewer_favorite
  on viewer_favorite.wallpaper_id = w.id and viewer_favorite.user_id = auth.uid()
left join wali.saved_wallpapers viewer_saved
  on viewer_saved.wallpaper_id = w.id and viewer_saved.user_id = auth.uid()
left join lateral (
  select jsonb_agg(item order by published_at desc, id desc) as items from (
    select to_jsonb(candidate) as item, candidate.published_at, candidate.id
    from public.catalog_wallpapers_v1 candidate
    join wali.wallpapers related_wallpaper on related_wallpaper.id = candidate.id
    where related_wallpaper.primary_category_id = w.primary_category_id and candidate.id <> w.id
    order by candidate.published_at desc, candidate.id desc limit 24
  ) related_page
) related on true;

grant select on public.catalog_wallpaper_details_v1 to anon, authenticated;
