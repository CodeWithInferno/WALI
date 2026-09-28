-- Preserve the existing relevance formula and opaque cursor contract while
-- comparing every page against its anchor's score from the same read snapshot.
-- Missing/filtered anchors require a fresh first page through the existing
-- invalid-cursor result. No privileged lookup, data, grants or schema changes.

create or replace function public.catalog_search_v2(query text, filters jsonb, cursor text, "limit" integer)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare decoded jsonb := wali.decode_catalog_cursor(cursor);
  page_limit integer := least(greatest(coalesce("limit", 24), 1), 50);
  cursor_time timestamptz; cursor_id uuid; cursor_score numeric; result jsonb; cursor_sort text;
  selected_sort text; ceiling integer; relevance_anchor_missing boolean;
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
  cursor_sort := 'c2-search-' || substr(md5(jsonb_build_array(query, filters, ceiling)::text), 1, 22);
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
  ), cursor_anchor as (
    -- Relevance freshness changes on every request. Re-score the cursor row in
    -- this same caller-visible, filtered snapshot; never read a hidden anchor.
    select s.sort_score from scored s where s.id = cursor_id and s.published_at = cursor_time
  ), page as (
    select s.* from scored s where decoded is null or (s.sort_score, s.published_at, s.id) < (
      case when selected_sort = 'relevance' then (select a.sort_score from cursor_anchor a) else cursor_score end,
      cursor_time, cursor_id)
    order by s.sort_score desc, s.published_at desc, s.id desc limit page_limit
  ) select jsonb_build_object(
    'items', coalesce(jsonb_agg(to_jsonb(p) - 'sort_score' order by p.sort_score desc, p.published_at desc, p.id desc), '[]'::jsonb),
    'next_cursor', case when count(*) = page_limit then (select wali.encode_catalog_cursor(last_row.published_at, last_row.id, last_row.sort_score, cursor_sort)
      from page last_row order by last_row.sort_score, last_row.published_at, last_row.id limit 1) else null end,
    'ranking_explanation', jsonb_build_object('formula_revision', 'search-v2', 'model_revision', null)),
    decoded is not null and selected_sort = 'relevance' and not exists (select 1 from cursor_anchor)
    into result, relevance_anchor_missing from page p;
  if relevance_anchor_missing then
    raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID';
  end if;
  return result;
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID';
end $$;
