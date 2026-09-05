-- Submission publication history and current listing visibility are distinct.
-- Expose only the creator's own listing state; private report notes stay private.

create or replace function public.my_creator_submissions_v1(
  cursor text default null, page_limit integer default 24
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor_id uuid := auth.uid(); cursor_id uuid; cursor_time timestamptz;
  items jsonb; next_cursor text;
begin
  if page_limit not between 1 and 50
     or actor_id is null
     or not exists (select 1 from wali.profiles profile where profile.id = actor_id and profile.status = 'active')
     or not wali.has_active_role('creator') then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_ROLE_REQUIRED';
  end if;
  if cursor is not null then
    begin cursor_id := cursor::uuid; exception when others then
      raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end;
    select submission.updated_at into cursor_time from wali.submissions submission
      where submission.id = cursor_id and submission.creator_id = actor_id;
    if not found then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
  end if;
  with page as (
    select submission.* from wali.submissions submission
    where submission.creator_id = actor_id
      and (cursor_id is null or (submission.updated_at, submission.id) < (cursor_time, cursor_id))
    order by submission.updated_at desc, submission.id desc limit page_limit
  ), projected as (
    select page.id, page.updated_at, jsonb_build_object(
      'submission_id', page.id, 'wallpaper_id', page.wallpaper_id,
      'wallpaper_status', wallpaper.status,
      'revision', page.revision, 'generation', page.generation, 'state', page.status,
      'draft', case when rights.id is null then null else jsonb_build_object(
        'title', page.proposed_title, 'description', page.proposed_description,
        'primary_category_id', page.primary_category_id,
        'suggested_tag_ids', coalesce(tags.ids, '[]'::jsonb),
        'content_warning', page.content_warning,
        'rights', jsonb_build_object(
          'basis', rights.basis, 'rights_holder', rights.rights_holder,
          'license_id', rights.license_id, 'source_url', rights.source_url,
          'attribution_text', rights.attribution_text,
          'proof_object_ids', to_jsonb(rights.proof_object_ids), 'attests_rights', true,
          'requirements', jsonb_build_object(
            'requires_source_url', rights.basis = 'public_domain',
            'requires_attribution', license.attribution_required,
            'requires_proof', false)
        )) end,
      'processing', wali.creator_processing_projection(page.id, page.generation),
      'moderation_reason_codes', coalesce(review.reason_codes, '[]'::jsonb),
      'creator_facing_note', review.public_note,
      'created_at', to_char(page.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'updated_at', to_char(page.updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ) as item
    from page
    left join wali.wallpapers wallpaper on wallpaper.id = page.wallpaper_id
    left join wali.rights_declarations rights on rights.submission_id = page.id
    left join wali.licenses license on license.id = rights.license_id
    left join lateral (select jsonb_agg(suggestion.tag_id order by suggestion.tag_id) as ids
      from wali.submission_tag_suggestions suggestion
      where suggestion.submission_id = page.id and suggestion.source = 'creator') tags on true
    left join lateral (select to_jsonb(review_row.reason_codes) as reason_codes, review_row.public_note
      from wali.moderation_reviews review_row where review_row.submission_id = page.id
      order by review_row.created_at desc, review_row.id desc limit 1) review on true
  ) select coalesce(jsonb_agg(item order by updated_at desc, id desc), '[]'::jsonb),
      case when count(*) = page_limit then (array_agg(id order by updated_at desc, id desc))[count(*)]::text else null end
    into items, next_cursor from projected;
  return jsonb_build_object('items', items, 'next_cursor', next_cursor);
end $$;
