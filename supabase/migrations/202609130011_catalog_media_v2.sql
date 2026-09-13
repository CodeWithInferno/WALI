-- ADR 0027: V2 catalog readers select tagged video/still media.
-- V1 exclusions are inside the base view, before all paging and aggregation.
begin;

create or replace view public.catalog_wallpapers_v1
with (security_invoker = true, security_barrier = true) as
select w.id, w.slug::text as slug, w.title,
  jsonb_build_object(
    'id', p.id, 'handle', p.handle::text, 'display_name', p.display_name,
    'avatar_url', case when p.avatar_path is null then null else cfg.catalog_public_base_url || '/' || p.avatar_path end,
    'verification_status', coalesce(cp.verification_status::text,'unverified')
  ) as creator,
  w.content_rating::text as content_rating,
  jsonb_build_object('id', c.id, 'name', c.name, 'slug', c.slug) as primary_category,
  coalesce(tags.approved_tags, '[]'::jsonb) as approved_tags,
  poster.artifact as poster, preview.artifact as preview,
  w.current_release_id, w.revision, w.published_at,
  coalesce(stats.verified_install_count, 0) as verified_install_count,
  coalesce(stats.favorite_count, 0) as favorite_count,
  coalesce(stats.save_count, 0) as save_count
from wali.runtime_configuration cfg
join wali.wallpapers w on true
join wali.profiles p on p.id = w.creator_id and p.status = 'active'
left join wali.creator_profiles cp on cp.user_id = p.id
join wali.categories c on c.id = w.primary_category_id and c.active
join wali.licenses l on l.id = w.license_id and l.active and l.redistribution_allowed
join wali.wallpaper_releases r on r.id = w.current_release_id and r.status = 'published'
join lateral (
  select jsonb_build_object(
    'role', ra.role::text, 'url', cfg.catalog_public_base_url || '/' || a.storage_path,
    'sha256', a.digest, 'byte_count', a.byte_count, 'media_type', a.media_type,
    'width', a.width, 'height', a.height, 'duration_ms', coalesce(a.duration_ms, 0)
  ) as artifact from wali.release_artifacts ra join wali.artifacts a on a.digest = ra.artifact_digest
  where ra.release_id = r.id and ra.role = 'poster'
) poster on true
join lateral (
  select jsonb_build_object(
    'role', ra.role::text, 'url', cfg.catalog_public_base_url || '/' || a.storage_path,
    'sha256', a.digest, 'byte_count', a.byte_count, 'media_type', a.media_type,
    'width', a.width, 'height', a.height, 'duration_ms', a.duration_ms
  ) as artifact from wali.release_artifacts ra join wali.artifacts a on a.digest = ra.artifact_digest
  where ra.release_id = r.id and ra.role = 'preview'
) preview on true
left join lateral (
  select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.label, 'slug', t.slug) order by t.slug) as approved_tags
  from wali.wallpaper_tags wt join wali.tags t on t.id = wt.tag_id and t.active
  where wt.wallpaper_id = w.id and wt.status = 'approved'
) tags on true
left join lateral wali.catalog_public_counts(w.id) stats on true
where r.media_kind='video' and cfg.singleton and w.status = 'published' and w.visibility = 'public'
  and case w.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= wali.catalog_rating_limit();

create or replace view public.catalog_wallpapers_v2
with (security_invoker = true, security_barrier = true) as
select w.id, w.slug::text as slug, w.title,
  jsonb_build_object(
    'id', p.id, 'handle', p.handle::text, 'display_name', p.display_name,
    'avatar_url', case when p.avatar_path is null then null else cfg.catalog_public_base_url || '/' || p.avatar_path end,
    'verification_status', coalesce(cp.verification_status::text,'unverified')
  ) as creator,
  w.content_rating::text as content_rating,
  jsonb_build_object('id', c.id, 'name', c.name, 'slug', c.slug) as primary_category,
  coalesce(tags.approved_tags, '[]'::jsonb) as approved_tags,
  poster.artifact as poster, preview.artifact as preview,
  w.current_release_id, w.revision, w.published_at,
  coalesce(stats.verified_install_count, 0) as verified_install_count,
  coalesce(stats.favorite_count, 0) as favorite_count,
  coalesce(stats.save_count, 0) as save_count, r.media_kind
from wali.runtime_configuration cfg
join wali.wallpapers w on true
join wali.profiles p on p.id = w.creator_id and p.status = 'active'
left join wali.creator_profiles cp on cp.user_id = p.id
join wali.categories c on c.id = w.primary_category_id and c.active
join wali.licenses l on l.id = w.license_id and l.active and l.redistribution_allowed
join wali.wallpaper_releases r on r.id = w.current_release_id and r.status = 'published'
join lateral (
  select jsonb_build_object(
    'role', ra.role::text, 'url', cfg.catalog_public_base_url || '/' || a.storage_path,
    'sha256', a.digest, 'byte_count', a.byte_count, 'media_type', a.media_type,
    'width', a.width, 'height', a.height, 'duration_ms', coalesce(a.duration_ms, 0)
  ) as artifact from wali.release_artifacts ra join wali.artifacts a on a.digest = ra.artifact_digest
  where ra.release_id = r.id and ra.role = 'poster'
) poster on true
left join lateral (
  select jsonb_build_object(
    'role', ra.role::text, 'url', cfg.catalog_public_base_url || '/' || a.storage_path,
    'sha256', a.digest, 'byte_count', a.byte_count, 'media_type', a.media_type,
    'width', a.width, 'height', a.height, 'duration_ms', a.duration_ms
  ) as artifact from wali.release_artifacts ra join wali.artifacts a on a.digest = ra.artifact_digest
  where ra.release_id = r.id and ra.role = 'preview'
) preview on true
left join lateral (
  select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.label, 'slug', t.slug) order by t.slug) as approved_tags
  from wali.wallpaper_tags wt join wali.tags t on t.id = wt.tag_id and t.active
  where wt.wallpaper_id = w.id and wt.status = 'approved'
) tags on true
left join lateral wali.catalog_public_counts(w.id) stats on true
where exists(select 1 from wali.release_artifacts ra where ra.release_id=r.id and ra.role=case r.media_kind when 'still' then 'image_default'::wali.artifact_role else 'video_default'::wali.artifact_role end)
  and (r.media_kind='still' or preview.artifact is not null) and cfg.singleton and w.status = 'published' and w.visibility = 'public'
  and case w.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= wali.catalog_rating_limit();

create or replace view public.catalog_wallpaper_details_v2
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
  case r.media_kind when 'still' then jsonb_build_object('kind','still','width',master.width,'height',master.height,'artifact',master.artifact)
   else jsonb_build_object('kind','video','width',master.width,'height',master.height,'duration_ms',master.duration_ms,
    'frame_rate_numerator',master.frame_rate_numerator,'frame_rate_denominator',master.frame_rate_denominator,'artifact',master.artifact) end as media,
  coalesce(viewer_favorite.active, false) as is_favorite,
  coalesce(viewer_favorite.revision, 0) as favorite_revision,
  coalesce(viewer_saved.active, false) as is_saved,
  coalesce(viewer_saved.revision, 0) as saved_revision,
  coalesce(related.items, '[]'::jsonb) as related
from public.catalog_wallpapers_v2 summary
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
      'width', a.width, 'height', a.height, 'duration_ms', coalesce(a.duration_ms,0)
    ) as artifact
  from wali.release_artifacts ra join wali.artifacts a on a.digest = ra.artifact_digest
  where ra.release_id = r.id and ra.role = case r.media_kind when 'still' then 'image_default'::wali.artifact_role else 'video_default'::wali.artifact_role end
) master on true
left join wali.favorites viewer_favorite
  on viewer_favorite.wallpaper_id = w.id and viewer_favorite.user_id = auth.uid()
left join wali.saved_wallpapers viewer_saved
  on viewer_saved.wallpaper_id = w.id and viewer_saved.user_id = auth.uid()
left join lateral (
  select jsonb_agg(item order by published_at desc, id desc) as items from (
    select to_jsonb(candidate) as item, candidate.published_at, candidate.id
    from public.catalog_wallpapers_v2 candidate
    join wali.wallpapers related_wallpaper on related_wallpaper.id = candidate.id
    where related_wallpaper.primary_category_id = w.primary_category_id and candidate.id <> w.id
    order by candidate.published_at desc, candidate.id desc limit 24
  ) related_page
) related on true;

create or replace view public.my_favorites_v2
with (security_invoker = true, security_barrier = true) as
select to_jsonb(catalog) as wallpaper, f.revision, f.updated_at
from wali.favorites f join public.catalog_wallpapers_v2 catalog on catalog.id = f.wallpaper_id
where f.user_id = auth.uid() and f.active
  and exists (select 1 from wali.profiles p where p.id = auth.uid() and p.status = 'active');

create or replace view public.my_saved_wallpapers_v2
with (security_invoker = true, security_barrier = true) as
select to_jsonb(catalog) as wallpaper, s.revision, s.updated_at
from wali.saved_wallpapers s join public.catalog_wallpapers_v2 catalog on catalog.id = s.wallpaper_id
where s.user_id = auth.uid() and s.active
  and exists (select 1 from wali.profiles p where p.id = auth.uid() and p.status = 'active');

create or replace function public.catalog_browse_v2(
  category text, tags text[], sort text, cursor text, "limit" integer
) returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  decoded jsonb := wali.decode_catalog_cursor(cursor);
  page_limit integer := least(greatest(coalesce("limit", 24), 1), 50);
  cursor_time timestamptz; cursor_id uuid; cursor_score numeric; result jsonb; cursor_sort text;
begin
  if sort is null or sort not in ('featured', 'trending', 'newest', 'most_installed')
     or coalesce(cardinality(tags), 0) > 10
     or category is not null and (char_length(category) > 80 or category !~ '^[a-z0-9-]+$')
     or exists (select 1 from unnest(coalesce(tags, '{}'::text[])) value where value !~ '^[a-z0-9-]{1,80}$') then
    raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID';
  end if;
  cursor_sort := 'catalog2-browse-' || substr(md5(jsonb_build_array(category, tags, sort, wali.catalog_rating_limit())::text), 1, 22);
  if decoded is not null then
    if decoded ->> 'sort' <> cursor_sort then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
    cursor_time := (decoded ->> 'time')::timestamptz;
    cursor_id := (decoded ->> 'wallpaper_id')::uuid;
    cursor_score := nullif(decoded ->> 'score', '')::numeric;
  end if;
  with latest_rank as (
    select distinct on (rs.wallpaper_id) rs.wallpaper_id, rs.score
    from wali.ranking_snapshots rs
    where rs.surface = 'trending' and rs.formula_version = 'trending-v1' and rs.expires_at > statement_timestamp()
    order by rs.wallpaper_id, rs.generated_at desc
  ), candidates as (
    select c.*, case sort
      when 'trending' then coalesce(lr.score, 0)
      when 'most_installed' then c.verified_install_count::numeric
      when 'featured' then coalesce(q.total_score, 0.5)
      else null::numeric end as sort_score
    from public.catalog_wallpapers_v2 c
    left join latest_rank lr on lr.wallpaper_id = c.id
    left join wali.quality_assessments q on q.release_id = c.current_release_id and q.formula_version = 'quality-v1'
    where (category is null or c.primary_category ->> 'slug' = category)
      and (coalesce(cardinality(tags), 0) = 0 or not exists (
        select 1 from unnest(tags) requested(slug) where not exists (
          select 1 from jsonb_array_elements(c.approved_tags) approved where approved ->> 'slug' = requested.slug
        )
      ))
  ), page as (
    select c.* from candidates c
    where decoded is null
      or (sort = 'newest' and (c.published_at, c.id) < (cursor_time, cursor_id))
      or (sort <> 'newest' and (c.sort_score, c.published_at, c.id) < (cursor_score, cursor_time, cursor_id))
    order by c.sort_score desc nulls last, c.published_at desc, c.id desc limit page_limit
  )
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(to_jsonb(p) - 'sort_score' order by p.sort_score desc nulls last, p.published_at desc, p.id desc), '[]'::jsonb),
    'next_cursor', case when count(*) = page_limit then (
      select wali.encode_catalog_cursor(last_row.published_at, last_row.id, last_row.sort_score, cursor_sort)
      from page last_row order by last_row.sort_score asc nulls first, last_row.published_at, last_row.id limit 1
    ) else null end
  ) into result from page p;
  return result;
end $$;

create or replace function public.catalog_search_v2(query text, filters jsonb, cursor text, "limit" integer)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare decoded jsonb := wali.decode_catalog_cursor(cursor);
  page_limit integer := least(greatest(coalesce("limit", 24), 1), 50);
  cursor_time timestamptz; cursor_id uuid; cursor_score numeric; result jsonb; cursor_sort text;
  selected_sort text; ceiling integer;
begin
  filters := coalesce(filters, '{}'::jsonb);
  if query is null or char_length(btrim(query)) not between 1 and 200 or jsonb_typeof(filters) <> 'object' then
    raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID'; end if;
  selected_sort := coalesce(filters ->> 'sort', 'relevance');
  if exists (select 1 from jsonb_object_keys(filters) key where key not in
      ('category_slug', 'tag_slugs', 'content_rating_ceiling', 'minimum_duration_ms', 'maximum_duration_ms', 'sort'))
    or selected_sort not in ('relevance', 'featured', 'trending', 'newest', 'most_installed')
    or (filters ->> 'category_slug' is not null and filters ->> 'category_slug' !~ '^[a-z0-9-]{1,80}$')
    or (filters ->> 'content_rating_ceiling' is not null and filters ->> 'content_rating_ceiling' not in ('everyone','teen','mature'))
    or (filters ? 'tag_slugs' and jsonb_typeof(filters -> 'tag_slugs') <> 'array') then
    raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID'; end if;
  if coalesce(jsonb_array_length(filters -> 'tag_slugs'), 0) > 10
    or exists (select 1 from jsonb_array_elements_text(filters -> 'tag_slugs') tag where tag is null or tag !~ '^[a-z0-9-]{1,80}$')
    or (filters ->> 'minimum_duration_ms' is not null and (filters ->> 'minimum_duration_ms')::bigint not between 1 and 600000)
    or (filters ->> 'maximum_duration_ms' is not null and (filters ->> 'maximum_duration_ms')::bigint not between 1 and 600000)
    or (filters ->> 'minimum_duration_ms')::bigint > (filters ->> 'maximum_duration_ms')::bigint then
    raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID'; end if;
  ceiling := least(wali.catalog_rating_limit(), case coalesce(filters ->> 'content_rating_ceiling', 'mature') when 'everyone' then 0 when 'teen' then 1 else 2 end);
  cursor_sort := 'catalog2-search-' || substr(md5(jsonb_build_array(query, filters, ceiling)::text), 1, 22);
  if decoded is not null then
    if decoded ->> 'sort' <> cursor_sort then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
    cursor_time := (decoded ->> 'time')::timestamptz; cursor_id := (decoded ->> 'wallpaper_id')::uuid;
    cursor_score := (decoded ->> 'score')::numeric;
  end if;
  with latest_rank as (
    select distinct on (rs.wallpaper_id) rs.wallpaper_id, rs.score from wali.ranking_snapshots rs
    where rs.surface = 'trending' and rs.formula_version = 'trending-v1' and rs.expires_at > statement_timestamp()
    order by rs.wallpaper_id, rs.generated_at desc
  ), scored as (
    select c.*, case selected_sort
      when 'newest' then 0::numeric when 'featured' then coalesce(q.total_score, 0.5)
      when 'trending' then coalesce(lr.score, 0) when 'most_installed' then c.verified_install_count::numeric
      else round((0.75 * least(1, ts_rank_cd(w.search_document, websearch_to_tsquery('simple', btrim(query)), 32)) +
        0.15 * coalesce(q.total_score, 0.5) + 0.10 * greatest(0, 1 - extract(epoch from (statement_timestamp() - c.published_at)) / 2592000.0))::numeric, 8)
      end as sort_score
    from public.catalog_wallpapers_v2 c join wali.wallpapers w on w.id = c.id
    left join wali.quality_assessments q on q.release_id = c.current_release_id and q.formula_version = 'quality-v1'
    left join latest_rank lr on lr.wallpaper_id = c.id
    join public.catalog_wallpaper_details_v2 detail on (detail.wallpaper ->> 'id')::uuid = c.id
    where w.search_document @@ websearch_to_tsquery('simple', btrim(query))
      and case c.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= ceiling
      and (filters ->> 'category_slug' is null or c.primary_category ->> 'slug' = filters ->> 'category_slug')
      and (filters ->> 'minimum_duration_ms' is null or (detail.media->>'duration_ms')::bigint >= (filters ->> 'minimum_duration_ms')::bigint)
      and (filters ->> 'maximum_duration_ms' is null or (detail.media->>'duration_ms')::bigint <= (filters ->> 'maximum_duration_ms')::bigint)
      and not exists (select 1 from jsonb_array_elements_text(filters -> 'tag_slugs') requested(slug)
        where not exists (select 1 from jsonb_array_elements(c.approved_tags) approved where approved ->> 'slug' = requested.slug))
  ), page as (
    select s.* from scored s where decoded is null or (s.sort_score, s.published_at, s.id) < (cursor_score, cursor_time, cursor_id)
    order by s.sort_score desc, s.published_at desc, s.id desc limit page_limit
  ) select jsonb_build_object(
    'items', coalesce(jsonb_agg(to_jsonb(p) - 'sort_score' order by p.sort_score desc, p.published_at desc, p.id desc), '[]'::jsonb),
    'next_cursor', case when count(*) = page_limit then (select wali.encode_catalog_cursor(last_row.published_at, last_row.id, last_row.sort_score, cursor_sort)
      from page last_row order by last_row.sort_score, last_row.published_at, last_row.id limit 1) else null end,
    'ranking_explanation', jsonb_build_object('formula_revision', 'search-v2', 'model_revision', null)) into result from page p;
  return result;
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID';
end $$;

create or replace function public.catalog_home_v2(locale text, rating_ceiling text)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare sections jsonb := '[]'; items jsonb; section record; ceiling integer;
  explicit_ids uuid[] := '{}'; opted_out boolean := true; affinity jsonb := '{}';
begin
  if locale is null or char_length(locale) > 35 or rating_ceiling is null or rating_ceiling not in ('everyone','teen','mature') then
    raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID'; end if;
  ceiling := least(wali.catalog_rating_limit(), case rating_ceiling when 'everyone' then 0 when 'teen' then 1 else 2 end);
  if current_user <> 'anon' and auth.uid() is not null then
    select p.category_ids, p.personalization_opt_out into explicit_ids, opted_out
      from wali.user_preferences p where p.user_id = auth.uid();
    if not coalesce(opted_out, true) then
      if cardinality(explicit_ids) > 0 then
        select jsonb_object_agg(id::text, 1) into affinity from unnest(explicit_ids) chosen(id);
      else
        -- Existing active bookmarks and completed receipts only. One contribution
        -- per wallpaper/source, bounded to the most recent 100 of each source.
        with signals as (
          (select w.primary_category_id, 1 as weight from wali.saved_wallpapers s
            join wali.wallpapers w on w.id = s.wallpaper_id where s.user_id = auth.uid() and s.active
            order by s.updated_at desc, s.wallpaper_id limit 100)
          union all
          (select w.primary_category_id, 2 from (select r.wallpaper_id, max(i.consumed_at) as completed_at
            from wali.install_receipts i join wali.wallpaper_releases r on r.id = i.release_id
            where i.user_id = auth.uid() and i.consumed_at > statement_timestamp() - interval '90 days'
            group by r.wallpaper_id order by completed_at desc, r.wallpaper_id limit 100) receipt
            join wali.wallpapers w on w.id = receipt.wallpaper_id)
        ), weights as (select primary_category_id, least(sum(weight), 20) as weight from signals group by primary_category_id)
        select coalesce(jsonb_object_agg(primary_category_id::text, weight), '{}') into affinity from weights;
      end if;
      if coalesce(affinity, '{}') <> '{}' then
        select coalesce(jsonb_agg(to_jsonb(c) - 'affinity_score' order by c.affinity_score desc, c.published_at desc, c.id desc), '[]') into items
          from (select catalog.*, (affinity ->> (catalog.primary_category ->> 'id'))::integer as affinity_score
            from public.catalog_wallpapers_v2 catalog
            where affinity ? (catalog.primary_category ->> 'id')
              and case catalog.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= ceiling
            order by affinity_score desc, catalog.published_at desc, catalog.id desc limit 24) c;
        if jsonb_array_length(items) > 0 then sections := sections || jsonb_build_array(jsonb_build_object(
          'id','for-you','title','For You','kind','for_you','cursor',null,'items',items)); end if;
      end if;
    end if;
  end if;
  for section in select h.* from public.catalog_home_v1 h where h.kind = 'editorial' order by h.sort_order limit 5 loop
    select coalesce(jsonb_agg(to_jsonb(c) - 'ordinal' order by c.ordinal, c.id), '[]') into items from (
      select catalog.*, ci.ordinal from wali.collection_items ci join public.catalog_wallpapers_v2 catalog on catalog.id = ci.wallpaper_id
      where ci.collection_id = section.collection_id
        and case catalog.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= ceiling
      order by ci.ordinal, catalog.id limit 24) c;
    if jsonb_array_length(items) > 0 then sections := sections || jsonb_build_array(jsonb_build_object(
      'id',section.id,'title',section.title,'kind','editorial','cursor',null,'items',items)); end if;
  end loop;
  with latest as (select distinct on (rs.wallpaper_id) rs.wallpaper_id, rs.score from wali.ranking_snapshots rs
    where rs.surface = 'trending' and rs.formula_version = 'trending-v1' and rs.expires_at > statement_timestamp()
    order by rs.wallpaper_id, rs.generated_at desc)
  select coalesce(jsonb_agg(to_jsonb(c) - 'score' order by c.score desc, c.published_at desc, c.id desc), '[]') into items from (
    select catalog.*, latest.score from latest join public.catalog_wallpapers_v2 catalog on catalog.id = latest.wallpaper_id
    where case catalog.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= ceiling
    order by latest.score desc, catalog.published_at desc, catalog.id desc limit 24) c;
  if jsonb_array_length(items) > 0 then sections := sections || jsonb_build_array(jsonb_build_object(
    'id','trending','title','Trending','kind','trending','cursor',null,'items',items)); end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.published_at desc, c.id desc), '[]') into items from (
    select catalog.* from public.catalog_wallpapers_v2 catalog
    where case catalog.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= ceiling
    order by catalog.published_at desc, catalog.id desc limit 24) c;
  if jsonb_array_length(items) > 0 then sections := sections || jsonb_build_array(jsonb_build_object(
    'id','new','title','New','kind','new','cursor',null,'items',items)); end if;
  return jsonb_build_object('sections', sections);
end $$;

create or replace function public.catalog_wallpaper_detail_v2(wallpaper_id uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare result jsonb;
begin
  select to_jsonb(detail) into result from public.catalog_wallpaper_details_v2 detail
  where (detail.wallpaper ->> 'id')::uuid = wallpaper_id;
  if result is null then raise exception using errcode = 'P0001', message = 'WALI_WALLPAPER_NOT_FOUND'; end if;
  return result;
end $$;

create or replace function public.wali_edge_request_install_v1(
  actor_id uuid, request_id uuid, idempotency_key text,
  wallpaper_id uuid, release_id uuid, expected_wallpaper_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  wallpaper_row wali.wallpapers%rowtype;
  release_row wali.wallpaper_releases%rowtype;
  request_hash text;
  replay jsonb;
  receipt_id uuid;
  expiry timestamptz;
  response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not exists (select 1 from wali.profiles p where p.id = actor_id and p.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  if expected_wallpaper_revision not between 0 and 9007199254740991
     or char_length(idempotency_key) not between 16 and 64 or idempotency_key !~ '^[A-Za-z0-9_-]+$' then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  if not exists(select 1 from wali.wallpapers w join wali.wallpaper_releases r on r.id=w.current_release_id
    join wali.profiles p on p.id=w.creator_id and p.status='active'
    join wali.categories c on c.id=w.primary_category_id and c.active
    join wali.licenses l on l.id=w.license_id and l.active and l.redistribution_allowed
    where w.id=wali_edge_request_install_v1.wallpaper_id and w.status='published' and w.visibility='public' and r.status in ('published','revoked')
      and case w.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <=
        coalesce((select case pref.rating_ceiling when 'everyone' then 0 when 'teen' then 1 else 2 end from wali.user_preferences pref where pref.user_id=actor_id),2)
      and r.media_kind='video') then raise exception using errcode='P0001',message='WALI_WALLPAPER_NOT_FOUND'; end if;
  request_hash := encode(extensions.digest(
    wallpaper_id::text || ':' || release_id::text || ':' || expected_wallpaper_revision::text,
    'sha256'
  ), 'hex');
  replay := wali.reserve_command(actor_id, 'request_install_edge', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select * into wallpaper_row from wali.wallpapers w where w.id = wallpaper_id and w.status = 'published' for share;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_WALLPAPER_NOT_FOUND'; end if;
  if wallpaper_row.revision <> expected_wallpaper_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if wallpaper_row.current_release_id <> release_id then raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_CURRENT'; end if;
  select * into release_row from wali.wallpaper_releases release
   where release.id = wali_edge_request_install_v1.release_id
     and release.wallpaper_id = wali_edge_request_install_v1.wallpaper_id
     and release.status = 'published';
  if not found or release_row.manifest_body is null or release_row.metadata_body is null
     or exists (select 1 from wali.catalog_revocations r where r.release_id = wali_edge_request_install_v1.release_id) then
    raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_AVAILABLE';
  end if;
  expiry := statement_timestamp() + interval '30 minutes';
  insert into wali.install_receipts (user_id, release_id, request_id, expires_at)
  values (actor_id, release_id, request_id, expiry) returning id into receipt_id;
  insert into wali.engagement_events (user_id, wallpaper_id, release_id, kind, client_request_id, coarse_source)
  values (actor_id, wallpaper_id, release_id, 'install_requested', request_id, 'macos');
  response := jsonb_build_object(
    'wallpaper_id', wallpaper_id, 'release_id', release_id,
    'manifest_body', translate(encode(release_row.manifest_body, 'base64'), E'+/=\n\r', '-_'),
    'metadata_body', translate(encode(release_row.metadata_body, 'base64'), E'+/=\n\r', '-_'),
    'signature', translate(encode(release_row.manifest_signature, 'base64'), E'+/=\n\r', '-_'),
    'key_id', release_row.signing_key_id, 'install_receipt', receipt_id::text,
    'expires_at', to_char(expiry at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
  perform wali.complete_command(actor_id, 'request_install_edge', idempotency_key, response);
  return response;
end $$;

create or replace function public.wali_edge_request_install_v2(
  actor_id uuid, request_id uuid, idempotency_key text,
  wallpaper_id uuid, release_id uuid, expected_wallpaper_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  wallpaper_row wali.wallpapers%rowtype;
  release_row wali.wallpaper_releases%rowtype;
  request_hash text;
  replay jsonb;
  receipt_id uuid;
  expiry timestamptz;
  response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not exists (select 1 from wali.profiles p where p.id = actor_id and p.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  if expected_wallpaper_revision not between 0 and 9007199254740991
     or char_length(idempotency_key) not between 16 and 64 or idempotency_key !~ '^[A-Za-z0-9_-]+$' then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  if not exists(select 1 from wali.wallpapers w join wali.wallpaper_releases r on r.id=w.current_release_id
    join wali.profiles p on p.id=w.creator_id and p.status='active'
    join wali.categories c on c.id=w.primary_category_id and c.active
    join wali.licenses l on l.id=w.license_id and l.active and l.redistribution_allowed
    where w.id=wali_edge_request_install_v2.wallpaper_id and w.status='published' and w.visibility='public' and r.status in ('published','revoked')
      and case w.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <=
        coalesce((select case pref.rating_ceiling when 'everyone' then 0 when 'teen' then 1 else 2 end from wali.user_preferences pref where pref.user_id=actor_id),2)
      ) then raise exception using errcode='P0001',message='WALI_WALLPAPER_NOT_FOUND'; end if;
  request_hash := encode(extensions.digest(
    wallpaper_id::text || ':' || release_id::text || ':' || expected_wallpaper_revision::text,
    'sha256'
  ), 'hex');
  replay := wali.reserve_command(actor_id, 'request_install_edge_v2', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select * into wallpaper_row from wali.wallpapers w where w.id = wallpaper_id and w.status = 'published' for share;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_WALLPAPER_NOT_FOUND'; end if;
  if wallpaper_row.revision <> expected_wallpaper_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if wallpaper_row.current_release_id <> release_id then raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_CURRENT'; end if;
  select * into release_row from wali.wallpaper_releases release
   where release.id = wali_edge_request_install_v2.release_id
     and release.wallpaper_id = wali_edge_request_install_v2.wallpaper_id
     and release.status = 'published';
  if not found or release_row.manifest_body is null or release_row.metadata_body is null
     or exists (select 1 from wali.catalog_revocations r where r.release_id = wali_edge_request_install_v2.release_id) then
    raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_AVAILABLE';
  end if;
  expiry := statement_timestamp() + interval '30 minutes';
  insert into wali.install_receipts (user_id, release_id, request_id, expires_at)
  values (actor_id, release_id, request_id, expiry) returning id into receipt_id;
  insert into wali.engagement_events (user_id, wallpaper_id, release_id, kind, client_request_id, coarse_source)
  values (actor_id, wallpaper_id, release_id, 'install_requested', request_id, 'macos');
  response := jsonb_build_object(
    'wallpaper_id', wallpaper_id, 'release_id', release_id, 'media_kind',release_row.media_kind,
    'manifest_body', translate(encode(release_row.manifest_body, 'base64'), E'+/=\n\r', '-_'),
    'metadata_body', translate(encode(release_row.metadata_body, 'base64'), E'+/=\n\r', '-_'),
    'signature', translate(encode(release_row.manifest_signature, 'base64'), E'+/=\n\r', '-_'),
    'key_id', release_row.signing_key_id, 'install_receipt', receipt_id::text,
    'expires_at', to_char(expiry at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
  perform wali.complete_command(actor_id, 'request_install_edge_v2', idempotency_key, response);
  return response;
end $$;

revoke all on function public.wali_edge_request_install_v2(uuid,uuid,text,uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.wali_edge_request_install_v2(uuid,uuid,text,uuid,uuid,bigint) to service_role;
grant select on public.catalog_wallpapers_v2,public.catalog_wallpaper_details_v2 to anon,authenticated;
grant select on public.my_favorites_v2,public.my_saved_wallpapers_v2 to authenticated;
revoke all on function public.catalog_browse_v2(text,text[],text,text,integer),public.catalog_search_v2(text,jsonb,text,integer),
 public.catalog_home_v2(text,text),public.catalog_wallpaper_detail_v2(uuid) from public;
grant execute on function public.catalog_browse_v2(text,text[],text,text,integer),public.catalog_search_v2(text,jsonb,text,integer),
 public.catalog_home_v2(text,text),public.catalog_wallpaper_detail_v2(uuid) to anon,authenticated;
commit;
