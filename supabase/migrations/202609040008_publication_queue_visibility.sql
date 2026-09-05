-- A published release is no longer a pending publication action.
create or replace function public.moderation_queue_v1(
  actor_id uuid, actor_aal text,
  queue_status text default 'pending', queue_sort text default 'oldest_submitted',
  cursor text default null, page_limit integer default 24
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare cursor_id uuid; cursor_time timestamptz; items jsonb; next_cursor text;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if actor_aal <> 'aal2' or not exists (select 1 from wali.profiles profile
       where profile.id = actor_id and profile.status = 'active')
     or not (wali.edge_actor_has_role(actor_id, 'moderator') or wali.edge_actor_has_role(actor_id, 'admin')) then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATOR_AAL2_REQUIRED';
  end if;
  if queue_status not in ('pending', 'under_review', 'approved') or queue_sort not in ('oldest_submitted', 'newest_submitted', 'risk_priority')
     or page_limit not between 1 and 50 then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  if cursor is not null then
    begin cursor_id := cursor::uuid; exception when others then
      raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end;
    select submission.submitted_at into cursor_time from wali.submissions submission where submission.id = cursor_id;
    if not found then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
  end if;
  with page as (
    select submission.* from wali.submissions submission
    where (case when queue_status = 'pending' then submission.status in ('submitted', 'under_review')
      else submission.status::text = queue_status end)
      and (queue_status <> 'approved' or exists (
        select 1 from wali.wallpaper_releases release
        where release.source_submission_id = submission.id and release.status = 'approved'
      ))
      and (cursor_id is null or case when queue_sort = 'newest_submitted'
        then (submission.submitted_at < cursor_time or
          (submission.submitted_at = cursor_time and submission.id > cursor_id))
        else (submission.submitted_at, submission.id) > (cursor_time, cursor_id) end)
    order by
      case when queue_sort = 'newest_submitted' then submission.submitted_at end desc,
      case when queue_sort <> 'newest_submitted' then submission.submitted_at end asc,
      submission.id asc limit page_limit
  ), projected as (
    select page.id, page.submitted_at, jsonb_build_object(
      'submission_id', page.id, 'revision', page.revision, 'generation', page.generation,
      'state', page.status, 'wallpaper_id', page.wallpaper_id, 'wallpaper_revision', wallpaper.revision,
      'creator', jsonb_build_object('id', creator.id, 'handle', creator.handle::text,
        'display_name', creator.display_name),
      'proposed_title', page.proposed_title, 'proposed_description', page.proposed_description,
      'primary_category_name', category.name,
      'tag_names', coalesce(tags.names, '[]'::jsonb),
      'content_rating', page.content_rating_warning,
      'attribution_text', page.attribution_text, 'source_url', page.source_url,
      'rights_summary', rights.basis::text || ' · ' || license.name,
      'proof_status', 'not_required',
      'canonical_artifacts', coalesce(artifacts.items, '[]'::jsonb),
      'media_facts', wali.creator_processing_projection(page.id, page.generation) -> 'media_facts',
      'findings', wali.creator_processing_projection(page.id, page.generation) -> 'findings',
      'model_suggestions', wali.creator_processing_projection(page.id, page.generation) -> 'suggestions',
      'submitted_at', to_char(page.submitted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ) as item
    from page join wali.wallpapers wallpaper on wallpaper.id = page.wallpaper_id
    join wali.profiles creator on creator.id = page.creator_id
    join wali.categories category on category.id = page.primary_category_id
    join wali.rights_declarations rights on rights.submission_id = page.id
    join wali.licenses license on license.id = rights.license_id
    left join lateral (select jsonb_agg(tag.label order by tag.slug) as names
      from wali.submission_tag_suggestions suggestion join wali.tags tag on tag.id = suggestion.tag_id
      where suggestion.submission_id = page.id and suggestion.source = 'creator') tags on true
    left join lateral (select jsonb_agg(jsonb_build_object(
      'role', link.role, 'storage_path', staged.storage_path,
      'sha256', staged.digest, 'byte_count', staged.byte_count,
      'media_type', staged.media_type, 'width', staged.width, 'height', staged.height,
      'duration_ms', coalesce(staged.duration_ms, 0)
    ) order by link.sort_order, link.role) as items
      from wali.wallpaper_releases release
      join wali.release_staged_artifacts link on link.release_id = release.id
      join wali.staged_artifacts staged on staged.digest = link.artifact_digest
      join wali.processing_attempts verified on verified.id = staged.verified_by_attempt_id
      where release.source_submission_id = page.id
        and link.role in ('poster', 'preview', 'video_default')
        and verified.submission_id = page.id and verified.generation = page.generation) artifacts on true
  ) select coalesce(jsonb_agg(item order by
        case when queue_sort = 'newest_submitted' then submitted_at end desc,
        case when queue_sort <> 'newest_submitted' then submitted_at end asc,
        id
      ), '[]'::jsonb),
      case when count(*) = page_limit then (array_agg(id order by
        case when queue_sort = 'newest_submitted' then submitted_at end desc,
        case when queue_sort <> 'newest_submitted' then submitted_at end asc,
        id
      ))[count(*)]::text else null end
    into items, next_cursor from projected;
  return jsonb_build_object('items', items, 'next_cursor', next_cursor);
end $$;
