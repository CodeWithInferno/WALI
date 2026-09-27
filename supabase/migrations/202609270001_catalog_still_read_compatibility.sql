-- Complete ADR0027's read adapters for the already supported still format.
-- Stored verified artifacts, signed bytes, identity and RLS policies are unchanged.
begin;

-- Creator container is a format name (mp4/png), not an HTTP MIME type. The
-- canonical still master remains image/png in the immutable artifact record.
create or replace function wali.creator_processing_projection(
  target_submission_id uuid, target_generation integer
) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'submission_id', submission.id,
    'revision', submission.revision,
    'generation', submission.generation,
    'state', submission.status,
    'progress', case attempt.status
      when 'queued' then 0.05 when 'leased' then 0.1 when 'downloading' then 0.2
      when 'transcoding' then 0.45 when 'verifying' then 0.7
      when 'classifying' then 0.85 when 'completed' then 1.0 else null end,
    'safe_error_code', coalesce(attempt.safe_error_code, submission.last_safe_error_code),
    'media_facts', case when media.digest is null then null when submission.media_kind='still' then jsonb_build_object(
      'media_kind','still','container',case media.media_type when 'image/png' then 'png' else media.media_type end,'codec',media.codec,'width',media.width,'height',media.height) else jsonb_build_object(
      'container', case media.media_type when 'video/mp4' then 'mp4' else media.media_type end,
      'codec', media.codec, 'width', media.width, 'height', media.height,
      'frame_rate', case when media.frame_rate_denominator > 0
        then media.frame_rate_numerator::numeric / media.frame_rate_denominator else null end,
      'duration_ms', media.duration_ms
    ) end,
    'generated_variants', coalesce(variants.items, '[]'::jsonb),
    'duplicate_warning', false,
    'suggestions', coalesce(suggestions.items, '[]'::jsonb),
    'findings', case when coalesce(attempt.safe_error_code, submission.last_safe_error_code) is null
      then '[]'::jsonb else jsonb_build_array(jsonb_build_object(
        'code', coalesce(attempt.safe_error_code, submission.last_safe_error_code),
        'message', 'Processing could not complete safely.', 'severity', 'blocking')) end
  )
  from wali.submissions submission
  left join wali.processing_attempts attempt
    on attempt.submission_id = submission.id and attempt.generation = target_generation
  left join wali.wallpaper_releases release
    on release.source_submission_id = submission.id
  left join lateral (
    select staged.* from wali.release_staged_artifacts link
    join wali.staged_artifacts staged on staged.digest = link.artifact_digest
    join wali.processing_attempts verified on
      (submission.media_kind='video' and verified.id=staged.verified_by_attempt_id) or
      (submission.media_kind='still' and verified.submission_id=submission.id and verified.generation=target_generation
       and verified.status='completed' and verified.output_summary->>'media_kind'='still'
       and exists(select 1 from jsonb_array_elements(verified.output_summary->'artifacts') claim
        where claim->>'role'=link.role::text and claim->>'digest'=staged.digest))
    where link.release_id = release.id and link.role = case submission.media_kind when 'still' then 'image_default'::wali.artifact_role else 'video_default'::wali.artifact_role end
      and verified.submission_id = submission.id and verified.generation = target_generation limit 1
  ) media on true
  left join lateral (
    select jsonb_agg(jsonb_build_object('role', link.role, 'width', staged.width,
      'height', staged.height) order by link.sort_order, link.role) as items
    from wali.release_staged_artifacts link
    join wali.staged_artifacts staged on staged.digest = link.artifact_digest
    join wali.processing_attempts verified on
      (submission.media_kind='video' and verified.id=staged.verified_by_attempt_id) or
      (submission.media_kind='still' and verified.submission_id=submission.id and verified.generation=target_generation
       and verified.status='completed' and verified.output_summary->>'media_kind'='still'
       and exists(select 1 from jsonb_array_elements(verified.output_summary->'artifacts') claim
        where claim->>'role'=link.role::text and claim->>'digest'=staged.digest))
    where link.release_id = release.id
      and verified.submission_id = submission.id and verified.generation = target_generation
  ) variants on true
  left join lateral (
    select jsonb_agg(jsonb_build_object(
      'kind', 'tag', 'value', tag.label, 'confidence', suggestion.confidence,
      'model_id', suggestion.model_id, 'model_revision', suggestion.model_revision
    ) order by suggestion.confidence desc nulls last, tag.slug) as items
    from wali.submission_tag_suggestions suggestion
    join wali.tags tag on tag.id = suggestion.tag_id
    where suggestion.submission_id = submission.id and suggestion.source = 'classifier'
  ) suggestions on true
  where submission.id = target_submission_id and submission.generation = target_generation
$$;

create or replace function public.my_favorites_v2(cursor text, "limit" integer)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  decoded jsonb := wali.decode_catalog_cursor(cursor);
  page_limit integer := least(greatest(coalesce("limit", 24), 1), 50);
  cursor_time timestamptz;
  cursor_id uuid;
  result jsonb;
begin
  if auth.uid() is null then raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED'; end if;
  if decoded is not null then
    if decoded ->> 'sort' <> 'favorites-v2' then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
    cursor_time := (decoded ->> 'time')::timestamptz;
    cursor_id := (decoded ->> 'wallpaper_id')::uuid;
  end if;
  with page as (
    select * from public.my_favorites_v2 v
    where decoded is null or (v.updated_at, (v.wallpaper ->> 'id')::uuid) < (cursor_time, cursor_id)
    order by v.updated_at desc, (v.wallpaper ->> 'id')::uuid desc limit page_limit
  )
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(v.wallpaper order by v.updated_at desc, (v.wallpaper ->> 'id')::uuid desc), '[]'::jsonb),
    'next_cursor', case when count(*) = page_limit then (
      select wali.encode_catalog_cursor(last_row.updated_at, (last_row.wallpaper ->> 'id')::uuid, null, 'favorites-v2')
      from page last_row order by last_row.updated_at, (last_row.wallpaper ->> 'id')::uuid limit 1
    ) else null end
  ) into result from page v;
  return result;
end $$;

create or replace function public.my_saved_wallpapers_v2(cursor text, "limit" integer)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  decoded jsonb := wali.decode_catalog_cursor(cursor);
  page_limit integer := least(greatest(coalesce("limit", 24), 1), 50);
  cursor_time timestamptz;
  cursor_id uuid;
  result jsonb;
begin
  if auth.uid() is null then raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED'; end if;
  if decoded is not null then
    if decoded ->> 'sort' <> 'saved-v2' then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
    cursor_time := (decoded ->> 'time')::timestamptz;
    cursor_id := (decoded ->> 'wallpaper_id')::uuid;
  end if;
  with page as (
    select * from public.my_saved_wallpapers_v2 v
    where decoded is null or (v.updated_at, (v.wallpaper ->> 'id')::uuid) < (cursor_time, cursor_id)
    order by v.updated_at desc, (v.wallpaper ->> 'id')::uuid desc limit page_limit
  )
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(v.wallpaper order by v.updated_at desc, (v.wallpaper ->> 'id')::uuid desc), '[]'::jsonb),
    'next_cursor', case when count(*) = page_limit then (
      select wali.encode_catalog_cursor(last_row.updated_at, (last_row.wallpaper ->> 'id')::uuid, null, 'saved-v2')
      from page last_row order by last_row.updated_at, (last_row.wallpaper ->> 'id')::uuid limit 1
    ) else null end
  ) into result from page v;
  return result;
end $$;

-- These owner-only readers retain the V1 invoker and existing V2 view policies.
revoke all on function public.my_favorites_v2(text,integer),public.my_saved_wallpapers_v2(text,integer)
 from public,anon,service_role;
grant execute on function public.my_favorites_v2(text,integer),public.my_saved_wallpapers_v2(text,integer)
 to authenticated;
commit;
