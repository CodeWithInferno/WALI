-- ADR 0025: explicit interests and truthful completion totals. Existing ranking
-- eligibility remains unchanged; requests and failed downloads never count.
alter table wali.user_preferences add column category_ids uuid[] not null default '{}';
alter table wali.user_preferences add constraint user_preferences_categories_bounded
  check (coalesce(array_ndims(category_ids), 1) = 1 and cardinality(category_ids) <= 12
    and array_position(category_ids, null) is null);
create index install_receipts_completed_release_idx on wali.install_receipts (release_id) where consumed_at is not null;
create index saved_wallpapers_active_wallpaper_idx on wali.saved_wallpapers (wallpaper_id) where active;
create index favorites_active_wallpaper_idx on wali.favorites (wallpaper_id) where active;

-- The only private information these definer projections reveal is the current
-- caller's ceiling and aggregate counts for otherwise public, eligible items.
create function wali.catalog_rating_limit() returns integer
language sql stable security definer set search_path = '' as $$
  select case coalesce((select p.rating_ceiling::text from wali.user_preferences p
    join wali.profiles account on account.id = p.user_id and account.status = 'active'
    where p.user_id = auth.uid() and coalesce(current_setting('role', true), 'none') <> 'anon'), 'teen') when 'everyone' then 0 when 'teen' then 1 else 2 end
$$;
create function wali.catalog_public_counts(target_wallpaper_id uuid)
returns table (verified_install_count bigint, favorite_count bigint, save_count bigint)
language sql stable security definer set search_path = '' as $$
  select
    (select count(*) from wali.install_receipts receipt join wali.wallpaper_releases release on release.id = receipt.release_id
      where release.wallpaper_id = w.id and receipt.consumed_at is not null),
    (select count(*) from wali.favorites f where f.wallpaper_id = w.id and f.active),
    (select count(*) from wali.saved_wallpapers s where s.wallpaper_id = w.id and s.active)
  from wali.wallpapers w
  join wali.profiles p on p.id = w.creator_id and p.status = 'active'
  join wali.creator_profiles cp on cp.user_id = p.id
  join wali.categories c on c.id = w.primary_category_id and c.active
  join wali.licenses l on l.id = w.license_id and l.active and l.redistribution_allowed
  join wali.wallpaper_releases r on r.id = w.current_release_id and r.status = 'published'
  where w.id = target_wallpaper_id and w.status = 'published' and w.visibility = 'public'
    and case w.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= wali.catalog_rating_limit()
$$;
revoke all on function wali.catalog_rating_limit(), wali.catalog_public_counts(uuid) from public, anon, authenticated;
grant execute on function wali.catalog_rating_limit(), wali.catalog_public_counts(uuid) to anon, authenticated;

create function public.catalog_preferences_v1() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if auth.uid() is null then raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED'; end if;
  if not exists (select 1 from wali.profiles where id = auth.uid() and status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_RESTRICTED'; end if;
  select jsonb_build_object('user_id', p.user_id, 'category_ids', p.category_ids,
    'rating_ceiling', p.rating_ceiling, 'personalization_opt_out', p.personalization_opt_out,
    'revision', p.revision) into result from wali.user_preferences p where p.user_id = auth.uid();
  if result is null then raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_PROFILE_UNAVAILABLE'; end if;
  return result;
end $$;

create function public.set_catalog_preferences_v1(category_ids uuid[], rating_ceiling text,
  personalization_opt_out boolean, expected_revision bigint, idempotency_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); ids uuid[]; current_revision bigint; result jsonb; replay jsonb; request_hash text;
begin
  if actor is null then raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED'; end if;
  if not exists (select 1 from wali.profiles where id = actor and status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_RESTRICTED'; end if;
  if category_ids is null or cardinality(category_ids) > 12 or coalesce(array_ndims(category_ids), 1) <> 1
     or array_position(category_ids, null) is not null
     or (select count(distinct x) from unnest(category_ids) x) <> cardinality(category_ids)
     or rating_ceiling is null or rating_ceiling not in ('everyone', 'teen', 'mature')
     or personalization_opt_out is null or expected_revision is null or expected_revision < 1
     or idempotency_key is null or idempotency_key !~ '^[A-Za-z0-9_-]{16,128}$'
     or exists (select 1 from unnest(category_ids) selected(id) where not exists (
       select 1 from wali.categories c where c.id = selected.id and c.active)) then
    raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID'; end if;
  select coalesce(array_agg(id order by id), '{}') into ids from unnest(category_ids) selected(id);
  request_hash := encode(extensions.digest(jsonb_build_array(ids, rating_ceiling, personalization_opt_out, expected_revision)::text, 'sha256'), 'hex');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text || ':catalog_preferences', 0));
  replay := wali.reserve_command(actor, 'set_catalog_preferences', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select p.revision into current_revision from wali.user_preferences p where p.user_id = actor for update;
  if current_revision is distinct from expected_revision then
    raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  update wali.user_preferences p set category_ids = ids,
    rating_ceiling = set_catalog_preferences_v1.rating_ceiling::wali.content_rating,
    personalization_opt_out = set_catalog_preferences_v1.personalization_opt_out where p.user_id = actor;
  result := public.catalog_preferences_v1();
  insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
    values (actor, 'catalog_preferences.updated', 'account', actor, gen_random_uuid(),
      jsonb_build_object('revision', result -> 'revision'));
  perform wali.complete_command(actor, 'set_catalog_preferences', idempotency_key, result);
  return result;
end $$;
revoke all on function public.catalog_preferences_v1(), public.set_catalog_preferences_v1(uuid[],text,boolean,bigint,text) from public, anon, authenticated;
grant execute on function public.catalog_preferences_v1(), public.set_catalog_preferences_v1(uuid[],text,boolean,bigint,text) to authenticated;

create or replace view public.catalog_wallpapers_v1
with (security_invoker = true, security_barrier = true) as
select w.id, w.slug::text as slug, w.title,
  jsonb_build_object(
    'id', p.id, 'handle', p.handle::text, 'display_name', p.display_name,
    'avatar_url', case when p.avatar_path is null then null else cfg.catalog_public_base_url || '/' || p.avatar_path end,
    'verification_status', cp.verification_status::text
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
join wali.creator_profiles cp on cp.user_id = p.id
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
where cfg.singleton and w.status = 'published' and w.visibility = 'public'
  and case w.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= wali.catalog_rating_limit();

create or replace function public.catalog_browse_v1(
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
  cursor_sort := 'browse-v2-' || substr(md5(jsonb_build_array(category, tags, sort, wali.catalog_rating_limit())::text), 1, 22);
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
    from public.catalog_wallpapers_v1 c
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

-- Search keeps its existing signature; sort is an optional exact filter key.
create or replace function public.catalog_search_v1(query text, filters jsonb, cursor text, "limit" integer)
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
  cursor_sort := 'search-v2-' || substr(md5(jsonb_build_array(query, filters, ceiling)::text), 1, 22);
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
    from public.catalog_wallpapers_v1 c join wali.wallpapers w on w.id = c.id
    left join wali.quality_assessments q on q.release_id = c.current_release_id and q.formula_version = 'quality-v1'
    left join latest_rank lr on lr.wallpaper_id = c.id
    join public.catalog_wallpaper_details_v1 detail on (detail.wallpaper ->> 'id')::uuid = c.id
    where w.search_document @@ websearch_to_tsquery('simple', btrim(query))
      and case c.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= ceiling
      and (filters ->> 'category_slug' is null or c.primary_category ->> 'slug' = filters ->> 'category_slug')
      and (filters ->> 'minimum_duration_ms' is null or detail.duration_ms >= (filters ->> 'minimum_duration_ms')::bigint)
      and (filters ->> 'maximum_duration_ms' is null or detail.duration_ms <= (filters ->> 'maximum_duration_ms')::bigint)
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

create or replace function public.catalog_home_v1(locale text, rating_ceiling text)
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
            from public.catalog_wallpapers_v1 catalog
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
      select catalog.*, ci.ordinal from wali.collection_items ci join public.catalog_wallpapers_v1 catalog on catalog.id = ci.wallpaper_id
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
    select catalog.*, latest.score from latest join public.catalog_wallpapers_v1 catalog on catalog.id = latest.wallpaper_id
    where case catalog.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= ceiling
    order by latest.score desc, catalog.published_at desc, catalog.id desc limit 24) c;
  if jsonb_array_length(items) > 0 then sections := sections || jsonb_build_array(jsonb_build_object(
    'id','trending','title','Trending','kind','trending','cursor',null,'items',items)); end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.published_at desc, c.id desc), '[]') into items from (
    select catalog.* from public.catalog_wallpapers_v1 catalog
    where case catalog.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= ceiling
    order by catalog.published_at desc, catalog.id desc limit 24) c;
  if jsonb_array_length(items) > 0 then sections := sections || jsonb_build_array(jsonb_build_object(
    'id','new','title','New','kind','new','cursor',null,'items',items)); end if;
  return jsonb_build_object('sections', sections);
end $$;

-- Owner export keeps its existing root shape for deployed worker compatibility.
-- Publication evidence is nested under the existing owner submission; snapshots
-- use whitelisted user-content keys, never raw private proof or lease fields.
create index automatic_publication_decisions_submission_idx
  on wali.automatic_publication_decisions(submission_id, created_at, id);
-- Include explicit interests in the existing authenticated account export.
create or replace function wali.worker_read_account_export(
  export_id uuid, user_id uuid, worker_identity text
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare document jsonb;
begin
  if not wali.worker_caller_authorized() then raise exception using errcode = 'P0001', message = 'WALI_WORKER_ROLE_REQUIRED'; end if;
  if not exists (select 1 from wali.account_exports e
    where e.id = worker_read_account_export.export_id and e.user_id = worker_read_account_export.user_id
      and e.status = 'processing' and e.lease_owner = worker_read_account_export.worker_identity
      and e.lease_expires_at > statement_timestamp()) then
    raise exception using errcode = 'P0001', message = 'WALI_WORKER_LEASE_INVALID';
  end if;
  select jsonb_build_object(
    'schema_version', 1, 'export_id', worker_read_account_export.export_id,
    'user_id', worker_read_account_export.user_id,
    'exported_at', (select to_char(date_trunc('second', e.created_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      from wali.account_exports e where e.id = worker_read_account_export.export_id),
    'account_identity', (select jsonb_build_object(
      'email', case when u.email is not null and char_length(u.email) between 1 and 320
        and u.email !~ '[[:cntrl:]]' then u.email else null end,
      'providers', coalesce((select jsonb_agg(provider order by provider) from (
        select distinct i.provider
        from auth.identities i
        where i.user_id = u.id and i.provider = any (array[
          'email', 'phone', 'anonymous', 'apple', 'azure', 'bitbucket', 'discord',
          'facebook', 'figma', 'fly', 'github', 'gitlab', 'google', 'kakao',
          'keycloak', 'linkedin', 'linkedin_oidc', 'notion', 'slack', 'spotify',
          'sso', 'twitch', 'twitter', 'workos', 'zoom'
        ]::text[])
        order by i.provider limit 8
      ) providers), '[]'::jsonb),
      'created_at', case when u.created_at is null then null else
        to_char(date_trunc('second', u.created_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') end,
      'last_sign_in_at', case when u.last_sign_in_at is null then null else
        to_char(date_trunc('second', u.last_sign_in_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') end
    ) from auth.users u where u.id = worker_read_account_export.user_id),
    'profile', (select jsonb_build_object('handle', p.handle::text, 'display_name', p.display_name,
      'status', p.status, 'created_at', p.created_at, 'updated_at', p.updated_at)
      from wali.profiles p where p.id = worker_read_account_export.user_id),
    'creator_profile', (select to_jsonb(x) from (select bio, website_url, verification_status,
      created_at, updated_at from wali.creator_profiles where user_id = worker_read_account_export.user_id) x),
    'preferences', (select to_jsonb(x) from (select category_ids, rating_ceiling, locale, personalization_opt_out,
      marketing_opt_out, revision, created_at, updated_at from wali.user_preferences where user_id = worker_read_account_export.user_id) x),
    'terms_acceptances', coalesce((select jsonb_agg(to_jsonb(x) order by accepted_at, document_kind, document_version)
      from (select document_kind, document_version, accepted_at from wali.terms_acceptances
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'favorites', coalesce((select jsonb_agg(to_jsonb(x) order by wallpaper_id)
      from (select wallpaper_id, active, revision, created_at, updated_at from wali.favorites
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'saved_wallpapers', coalesce((select jsonb_agg(to_jsonb(x) order by wallpaper_id)
      from (select wallpaper_id, active, revision, created_at, updated_at from wali.saved_wallpapers
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'creator_follows', coalesce((select jsonb_agg(to_jsonb(x) order by creator_id)
      from (select creator_id, active, revision, created_at, updated_at from wali.creator_follows
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'install_receipts', coalesce((select jsonb_agg(to_jsonb(x) order by issued_at, id)
      from (select id, release_id, issued_at, expires_at, consumed_at from wali.install_receipts
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'engagement_events', coalesce((select jsonb_agg(to_jsonb(x) order by occurred_at, id)
      from (select id, wallpaper_id, release_id, kind, occurred_at, coarse_source from wali.engagement_events
        where user_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'upload_sessions', coalesce((select jsonb_agg(to_jsonb(x) order by created_at, id)
      from (select id, original_filename, declared_byte_count, received_byte_count, detected_media_type,
        status, admission_kind, created_at, completed_at from wali.upload_sessions where creator_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'submissions', coalesce((select jsonb_agg(to_jsonb(x) order by created_at, id)
      from (select s.id, s.wallpaper_id, s.proposed_title, s.proposed_description, s.primary_category_id,
        s.license_id, s.rights_holder, s.attribution_text, s.source_url, s.content_rating_warning,
        s.status, s.generation, s.revision, s.submitted_at, s.decided_at, s.created_at, s.updated_at,
        coalesce((select jsonb_agg(jsonb_build_object(
          'id', d.id, 'generation', d.generation, 'submission_revision', d.submission_revision,
          'attempt_id', d.attempt_id, 'policy_version', d.policy_version, 'authority', d.authority,
          'artifact_set_digest', d.artifact_set_digest, 'created_at', d.created_at,
          'submission_snapshot', (select coalesce(jsonb_object_agg(k, v), '{}')
            from jsonb_each(d.submission_snapshot) item(k,v)
            where k in ('title','description','category','content_rating','tags')),
          'rights_snapshot', (select coalesce(jsonb_object_agg(k, v), '{}')
            from jsonb_each(d.rights_snapshot) item(k,v)
            where k in ('id','submission_id','basis','rights_holder','license_id','source_url','attribution_text',
              'attested_at','creator_terms_version','attestation_document_kind','review_status','reviewed_at','revision','created_at','updated_at'))
        ) order by d.created_at, d.id) from wali.automatic_publication_decisions d
          where d.submission_id = s.id), '[]'::jsonb) as automatic_publication_decisions,
        coalesce((select jsonb_agg(jsonb_build_object(
          'id', j.id, 'submission_id', j.submission_id, 'generation', j.generation,
          'status', j.status, 'attempts', j.attempts, 'safe_error_code', j.safe_error_code,
          'created_at', j.created_at, 'completed_at', j.completed_at
        ) order by j.created_at, j.id) from wali.automatic_publication_jobs j
          where j.submission_id = s.id), '[]'::jsonb) as automatic_publication_jobs
        from wali.submissions s where s.creator_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'rights_declarations', coalesce((select jsonb_agg(to_jsonb(x) order by submission_id)
      from (select r.submission_id, r.basis, r.rights_holder, r.license_id, r.source_url,
        r.attribution_text, r.attested_at, r.creator_terms_version, r.attestation_document_kind,
        r.creator_terms_version as attestation_version, r.review_status, r.revision
        from wali.rights_declarations r join wali.submissions s on s.id = r.submission_id
        where s.creator_id = worker_read_account_export.user_id) x), '[]'::jsonb),
    'reports', coalesce((select jsonb_agg(to_jsonb(x) order by created_at, id)
      from (select id, wallpaper_id, release_id, kind, detail, status, resolution_code, created_at, resolved_at
        from wali.reports where reporter_id = worker_read_account_export.user_id) x), '[]'::jsonb)
  ) into document;
  if octet_length(document::text) > 10485760 then raise exception using errcode = 'P0001', message = 'WALI_EXPORT_TOO_LARGE'; end if;
  return document;
end $$;
