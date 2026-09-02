-- WALI Marketplace foundation: allowlisted Data API views and bounded RPCs.

grant select on wali.favorites, wali.saved_wallpapers to anon;

create view public.catalog_wallpapers_v1
with (security_invoker = true, security_barrier = true) as
select w.id, w.slug::text as slug, w.title,
  jsonb_build_object(
    'id', p.id, 'handle', p.handle::text, 'display_name', p.display_name,
    'avatar_url', case when p.avatar_path is null then null else 'https://127.0.0.1/storage/v1/object/public/catalog-public/' || p.avatar_path end,
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
from wali.wallpapers w
join wali.profiles p on p.id = w.creator_id and p.status = 'active'
join wali.creator_profiles cp on cp.user_id = p.id
join wali.categories c on c.id = w.primary_category_id and c.active
join wali.licenses l on l.id = w.license_id and l.active and l.redistribution_allowed
join wali.wallpaper_releases r on r.id = w.current_release_id and r.status = 'published'
join lateral (
  select jsonb_build_object(
    'role', ra.role::text,
    'url', 'https://127.0.0.1/storage/v1/object/public/catalog-public/' || a.storage_path,
    'sha256', a.digest, 'byte_count', a.byte_count, 'media_type', a.media_type,
    'width', a.width, 'height', a.height, 'duration_ms', coalesce(a.duration_ms, 0)
  ) as artifact
  from wali.release_artifacts ra join wali.artifacts a on a.digest = ra.artifact_digest
  where ra.release_id = r.id and ra.role = 'poster'
) poster on true
join lateral (
  select jsonb_build_object(
    'role', ra.role::text,
    'url', 'https://127.0.0.1/storage/v1/object/public/catalog-public/' || a.storage_path,
    'sha256', a.digest, 'byte_count', a.byte_count, 'media_type', a.media_type,
    'width', a.width, 'height', a.height, 'duration_ms', a.duration_ms
  ) as artifact
  from wali.release_artifacts ra join wali.artifacts a on a.digest = ra.artifact_digest
  where ra.release_id = r.id and ra.role = 'preview'
) preview on true
left join lateral (
  select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.label, 'slug', t.slug) order by t.slug) as approved_tags
  from wali.wallpaper_tags wt join wali.tags t on t.id = wt.tag_id and t.active
  where wt.wallpaper_id = w.id and wt.status = 'approved'
) tags on true
left join lateral (
  select sum(s.unique_installers)::bigint as verified_install_count,
    sum(s.favorites)::bigint as favorite_count, sum(s.saves)::bigint as save_count
  from wali.wallpaper_stats_daily s where s.wallpaper_id = w.id
) stats on true
where w.status = 'published' and w.visibility = 'public';

create view public.catalog_wallpaper_details_v1
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
  coalesce(related.items, '[]'::jsonb) as related
from public.catalog_wallpapers_v1 summary
join wali.wallpapers w on w.id = summary.id
join wali.wallpaper_releases r on r.id = summary.current_release_id
join wali.licenses l on l.id = w.license_id
join lateral (
  select a.duration_ms, a.width, a.height, a.frame_rate_numerator, a.frame_rate_denominator
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

create view public.catalog_creators_v1
with (security_invoker = true, security_barrier = true) as
select p.id, p.handle::text as handle, p.display_name,
  case when p.avatar_path is null then null else 'https://127.0.0.1/storage/v1/object/public/catalog-public/' || p.avatar_path end as avatar_url,
  cp.bio, cp.website_url, cp.verification_status::text as verification_status,
  count(w.id)::bigint as published_wallpaper_count
from wali.profiles p join wali.creator_profiles cp on cp.user_id = p.id
left join wali.wallpapers w on w.creator_id = p.id and w.status = 'published' and w.visibility = 'public'
where p.status = 'active'
group by p.id, p.handle, p.display_name, p.avatar_path, cp.bio, cp.website_url, cp.verification_status;

create view public.catalog_categories_v1
with (security_invoker = true, security_barrier = true) as
select c.id, c.parent_id, c.slug, c.name, c.description, c.sort_order,
  count(w.id)::bigint as published_wallpaper_count
from wali.categories c
left join wali.wallpapers w on w.primary_category_id = c.id and w.status = 'published' and w.visibility = 'public'
where c.active group by c.id;

create view public.catalog_tags_v1
with (security_invoker = true, security_barrier = true) as
select t.id, t.slug, t.label as name, t.kind::text as kind,
  count(distinct w.id)::bigint as published_wallpaper_count
from wali.tags t
left join wali.wallpaper_tags wt on wt.tag_id = t.id and wt.status = 'approved'
left join wali.wallpapers w on w.id = wt.wallpaper_id and w.status = 'published' and w.visibility = 'public'
where t.active group by t.id;

create view public.catalog_collections_v1
with (security_invoker = true, security_barrier = true) as
select c.id, c.slug, c.title, c.description, c.kind::text as kind,
  c.artwork_path, c.active_from, c.active_until,
  coalesce(jsonb_agg(jsonb_build_object(
    'wallpaper_id', ci.wallpaper_id, 'ordinal', ci.ordinal, 'caption', ci.editorial_caption
  ) order by ci.ordinal) filter (where ci.wallpaper_id is not null), '[]'::jsonb) as items
from wali.collections c left join wali.collection_items ci on ci.collection_id = c.id
where c.status = 'published'
  and (c.active_from is null or c.active_from <= statement_timestamp())
  and (c.active_until is null or c.active_until > statement_timestamp())
group by c.id;

create view public.catalog_home_v1
with (security_invoker = true, security_barrier = true) as
select 'editorial-' || c.id::text as id, c.title, 'editorial'::text as kind,
  c.id as collection_id, row_number() over (order by c.active_from desc nulls last, c.id)::integer as sort_order
from wali.collections c
where c.status = 'published'
  and (c.active_from is null or c.active_from <= statement_timestamp())
  and (c.active_until is null or c.active_until > statement_timestamp())
union all select 'trending', 'Trending', 'trending', null::uuid, 10000
union all select 'new', 'New', 'new', null::uuid, 10001;

create view public.my_profile_v1
with (security_invoker = true, security_barrier = true) as
select p.id, p.handle::text as handle, p.display_name,
  case when p.avatar_path is null then null else 'https://127.0.0.1/storage/v1/object/public/catalog-public/' || p.avatar_path end as avatar_url,
  p.status::text as status, p.revision, pref.rating_ceiling::text as rating_ceiling,
  pref.locale, pref.personalization_opt_out, pref.marketing_opt_out, pref.revision as preferences_revision
from wali.profiles p join wali.user_preferences pref on pref.user_id = p.id
where p.id = auth.uid();

create view public.my_creator_submissions_v1
with (security_invoker = true, security_barrier = true) as
select s.id as submission_id, s.wallpaper_id, s.proposed_title, s.proposed_description,
  s.primary_category_id, s.license_id, s.rights_holder, s.attribution_text,
  s.source_url, s.content_rating_warning::text as content_rating_warning,
  s.status::text as status, s.generation, s.revision, s.submitted_at,
  s.decided_at, s.last_safe_error_code, s.created_at, s.updated_at
from wali.submissions s where s.creator_id = auth.uid();

create view public.my_favorites_v1
with (security_invoker = true, security_barrier = true) as
select to_jsonb(catalog) as wallpaper, f.revision, f.updated_at
from wali.favorites f join public.catalog_wallpapers_v1 catalog on catalog.id = f.wallpaper_id
where f.user_id = auth.uid() and f.active
  and exists (select 1 from wali.profiles p where p.id = auth.uid() and p.status = 'active');

create view public.my_saved_wallpapers_v1
with (security_invoker = true, security_barrier = true) as
select to_jsonb(catalog) as wallpaper, s.revision, s.updated_at
from wali.saved_wallpapers s join public.catalog_wallpapers_v1 catalog on catalog.id = s.wallpaper_id
where s.user_id = auth.uid() and s.active
  and exists (select 1 from wali.profiles p where p.id = auth.uid() and p.status = 'active');

create or replace function wali.encode_catalog_cursor(
  cursor_time timestamptz, cursor_wallpaper_id uuid, cursor_score numeric, cursor_sort text
) returns text language sql immutable set search_path = '' as $$
  select rtrim(translate(replace(replace(encode(convert_to(jsonb_build_object(
    'v', 1, 'time', to_char(cursor_time at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'wallpaper_id', cursor_wallpaper_id, 'score', cursor_score, 'sort', cursor_sort
  )::text, 'UTF8'), 'base64'), E'\n', ''), E'\r', ''), '+/', '-_'), '=')
$$;

create or replace function wali.decode_catalog_cursor(cursor_value text)
returns jsonb language plpgsql stable set search_path = '' as $$
declare padded text; raw bytea; decoded jsonb;
begin
  if cursor_value is null then return null; end if;
  if char_length(cursor_value) not between 8 and 1024 or cursor_value !~ '^[A-Za-z0-9_-]+$' then
    raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID';
  end if;
  padded := translate(cursor_value, '-_', '+/') || repeat('=', (4 - char_length(cursor_value) % 4) % 4);
  raw := decode(padded, 'base64');
  if octet_length(raw) > 768 then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
  decoded := convert_from(raw, 'UTF8')::jsonb;
  if decoded ->> 'v' <> '1' or not (decoded ?& array['time', 'wallpaper_id', 'score', 'sort'])
     or (select count(*) from jsonb_object_keys(decoded)) <> 5
     or char_length(decoded ->> 'sort') not between 1 and 32 then
    raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID';
  end if;
  perform (decoded ->> 'time')::timestamptz;
  perform (decoded ->> 'wallpaper_id')::uuid;
  if decoded -> 'score' <> 'null'::jsonb then perform (decoded ->> 'score')::numeric; end if;
  return decoded;
exception when others then
  if sqlerrm = 'WALI_CURSOR_INVALID' then raise; end if;
  raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID';
end $$;

create or replace function public.request_install_v1(
  wallpaper_id uuid, release_id uuid, expected_wallpaper_revision bigint, idempotency_key text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); wallpaper_row wali.wallpapers%rowtype; release_row wali.wallpaper_releases%rowtype;
  request_hash text; replay jsonb; receipt wali.install_receipts%rowtype; result jsonb;
begin
  if actor is null then raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED'; end if;
  if expected_wallpaper_revision not between 0 and 9007199254740991 or char_length(idempotency_key) not between 16 and 64
     or idempotency_key !~ '^[A-Za-z0-9_-]+$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  select * into wallpaper_row from wali.wallpapers w where w.id = wallpaper_id and w.status = 'published' for share;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_WALLPAPER_NOT_FOUND'; end if;
  if wallpaper_row.revision <> expected_wallpaper_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if wallpaper_row.current_release_id <> release_id then raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_CURRENT'; end if;
  select * into release_row from wali.wallpaper_releases r
  where r.id = request_install_v1.release_id
    and r.wallpaper_id = request_install_v1.wallpaper_id and r.status = 'published';
  if not found or exists (select 1 from wali.catalog_revocations cr where cr.release_id = request_install_v1.release_id) then
    raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_AVAILABLE';
  end if;
  request_hash := encode(extensions.digest(wallpaper_id::text || ':' || release_id::text || ':' || expected_wallpaper_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor, 'request_install', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  insert into wali.install_receipts (user_id, release_id, request_id, expires_at)
  values (actor, release_id, gen_random_uuid(), statement_timestamp() + interval '30 minutes') returning * into receipt;
  insert into wali.engagement_events (user_id, wallpaper_id, release_id, kind, client_request_id, coarse_source)
  values (actor, wallpaper_id, release_id, 'install_requested', gen_random_uuid(), 'macos');
  result := jsonb_build_object(
    'wallpaper_id', wallpaper_id, 'release_id', release_id,
    'manifest_body', rtrim(translate(replace(replace(encode(release_row.manifest_body, 'base64'), E'\n', ''), E'\r', ''), '+/', '-_'), '='),
    'signature', rtrim(translate(replace(replace(encode(release_row.manifest_signature, 'base64'), E'\n', ''), E'\r', ''), '+/', '-_'), '='),
    'key_id', release_row.signing_key_id, 'install_receipt', receipt.id::text,
    'expires_at', to_char(receipt.expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
  perform wali.complete_command(actor, 'request_install', idempotency_key, result); return result;
end $$;

create or replace function public.set_creator_follow_v1(
  creator_id uuid, desired boolean, expected_revision bigint, idempotency_key text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); existing wali.creator_follows%rowtype; next_revision bigint; aggregate_count bigint;
  request_hash text; replay jsonb; result jsonb;
begin
  if actor is null then raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED'; end if;
  if not exists (select 1 from wali.profiles p where p.id = actor and p.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  if not wali.take_interaction_quota(actor, 'set_creator_follow') then
    raise exception using errcode = 'P0001', message = 'WALI_RATE_LIMITED';
  end if;
  if creator_id = actor then raise exception using errcode = 'P0001', message = 'WALI_SELF_FOLLOW_FORBIDDEN'; end if;
  if expected_revision not between 0 and 9007199254740991 or char_length(idempotency_key) not between 16 and 64
     or idempotency_key !~ '^[A-Za-z0-9_-]+$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  if not exists (select 1 from wali.creator_profiles cp where cp.user_id = creator_id) then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_NOT_FOUND';
  end if;
  request_hash := encode(extensions.digest(creator_id::text || ':' || desired::text || ':' || expected_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor, 'set_creator_follow', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text || ':follow:' || creator_id::text, 0));
  select * into existing from wali.creator_follows f where f.user_id = actor and f.creator_id = set_creator_follow_v1.creator_id for update;
  if coalesce(existing.revision, 0) <> expected_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  next_revision := coalesce(existing.revision, 0);
  if existing.user_id is null and desired then
    insert into wali.creator_follows (user_id, creator_id, active, revision) values (actor, creator_id, true, 1); next_revision := 1;
  elsif existing.user_id is not null and existing.active <> desired then
    next_revision := existing.revision + 1;
    update wali.creator_follows set active = desired, revision = next_revision, updated_at = statement_timestamp()
    where user_id = actor and creator_follows.creator_id = set_creator_follow_v1.creator_id;
  end if;
  select count(*) into aggregate_count from wali.creator_follows f where f.creator_id = set_creator_follow_v1.creator_id and f.active;
  result := jsonb_build_object('desired', desired, 'revision', next_revision, 'aggregate_count', aggregate_count);
  perform wali.complete_command(actor, 'set_creator_follow', idempotency_key, result); return result;
end $$;

create or replace function public.catalog_creator_v1(handle text, cursor text, "limit" integer)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  creator_row public.catalog_creators_v1%rowtype;
  decoded jsonb := wali.decode_catalog_cursor(cursor);
  page_limit integer := least(greatest(coalesce("limit", 24), 1), 50);
  cursor_time timestamptz;
  cursor_id uuid;
  cursor_sort text;
  result jsonb;
begin
  if handle is null or handle !~ '^[a-z0-9][a-z0-9_]{2,31}$' then raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID'; end if;
  select * into creator_row from public.catalog_creators_v1 c where c.handle = catalog_creator_v1.handle;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_CREATOR_NOT_FOUND'; end if;
  cursor_sort := 'creator-v1-' || substring(md5(handle) from 1 for 12);
  if decoded is not null then
    if decoded ->> 'sort' <> cursor_sort then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
    cursor_time := (decoded ->> 'time')::timestamptz;
    cursor_id := (decoded ->> 'wallpaper_id')::uuid;
  end if;
  with page as (
    select c.* from public.catalog_wallpapers_v1 c
    where c.creator ->> 'handle' = handle
      and (decoded is null or (c.published_at, c.id) < (cursor_time, cursor_id))
    order by c.published_at desc, c.id desc
    limit page_limit
  )
  select jsonb_build_object(
    'creator', to_jsonb(creator_row),
    'items', coalesce(jsonb_agg(to_jsonb(p) order by p.published_at desc, p.id desc), '[]'::jsonb),
    'next_cursor', case when count(*) = page_limit then (
      select wali.encode_catalog_cursor(last_row.published_at, last_row.id, null, cursor_sort)
      from page last_row order by last_row.published_at, last_row.id limit 1
    ) else null end
  ) into result from page p;
  return result;
end $$;

create or replace function public.my_favorites_v1(cursor text, "limit" integer)
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
    if decoded ->> 'sort' <> 'favorites-v1' then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
    cursor_time := (decoded ->> 'time')::timestamptz;
    cursor_id := (decoded ->> 'wallpaper_id')::uuid;
  end if;
  with page as (
    select * from public.my_favorites_v1 v
    where decoded is null or (v.updated_at, (v.wallpaper ->> 'id')::uuid) < (cursor_time, cursor_id)
    order by v.updated_at desc, (v.wallpaper ->> 'id')::uuid desc limit page_limit
  )
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(v.wallpaper order by v.updated_at desc, (v.wallpaper ->> 'id')::uuid desc), '[]'::jsonb),
    'next_cursor', case when count(*) = page_limit then (
      select wali.encode_catalog_cursor(last_row.updated_at, (last_row.wallpaper ->> 'id')::uuid, null, 'favorites-v1')
      from page last_row order by last_row.updated_at, (last_row.wallpaper ->> 'id')::uuid limit 1
    ) else null end
  ) into result from page v;
  return result;
end $$;

create or replace function public.my_saved_wallpapers_v1(cursor text, "limit" integer)
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
    if decoded ->> 'sort' <> 'saved-v1' then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
    cursor_time := (decoded ->> 'time')::timestamptz;
    cursor_id := (decoded ->> 'wallpaper_id')::uuid;
  end if;
  with page as (
    select * from public.my_saved_wallpapers_v1 v
    where decoded is null or (v.updated_at, (v.wallpaper ->> 'id')::uuid) < (cursor_time, cursor_id)
    order by v.updated_at desc, (v.wallpaper ->> 'id')::uuid desc limit page_limit
  )
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(v.wallpaper order by v.updated_at desc, (v.wallpaper ->> 'id')::uuid desc), '[]'::jsonb),
    'next_cursor', case when count(*) = page_limit then (
      select wali.encode_catalog_cursor(last_row.updated_at, (last_row.wallpaper ->> 'id')::uuid, null, 'saved-v1')
      from page last_row order by last_row.updated_at, (last_row.wallpaper ->> 'id')::uuid limit 1
    ) else null end
  ) into result from page v;
  return result;
end $$;

create or replace function public.set_favorite_v1(
  wallpaper_id uuid, desired boolean, expected_revision bigint, idempotency_key text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); existing wali.favorites%rowtype; request_hash text; replay jsonb;
  result jsonb; current_release uuid; next_revision bigint; aggregate_count bigint;
begin
  if actor is null then raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED'; end if;
  if not exists (select 1 from wali.profiles p where p.id = actor and p.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  if not wali.take_interaction_quota(actor, 'set_favorite') then
    raise exception using errcode = 'P0001', message = 'WALI_RATE_LIMITED';
  end if;
  if expected_revision not between 0 and 9007199254740991 or char_length(idempotency_key) not between 16 and 64
     or idempotency_key !~ '^[A-Za-z0-9_-]+$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  select current_release_id into current_release from wali.wallpapers w where w.id = wallpaper_id and w.status = 'published';
  if current_release is null then raise exception using errcode = 'P0001', message = 'WALI_WALLPAPER_NOT_FOUND'; end if;
  request_hash := encode(extensions.digest(wallpaper_id::text || ':' || desired::text || ':' || expected_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor, 'set_favorite', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text || ':favorite:' || wallpaper_id::text, 0));
  select * into existing from wali.favorites f where f.user_id = actor and f.wallpaper_id = set_favorite_v1.wallpaper_id for update;
  if coalesce(existing.revision, 0) <> expected_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  next_revision := coalesce(existing.revision, 0);
  if existing.user_id is null and desired then
    insert into wali.favorites (user_id, wallpaper_id, active, revision) values (actor, wallpaper_id, true, 1); next_revision := 1;
  elsif existing.user_id is not null and existing.active <> desired then
    next_revision := existing.revision + 1;
    update wali.favorites set active = desired, revision = next_revision, updated_at = statement_timestamp()
    where user_id = actor and favorites.wallpaper_id = set_favorite_v1.wallpaper_id;
  end if;
  if coalesce(existing.active, false) <> desired then
    insert into wali.engagement_events (user_id, wallpaper_id, release_id, kind, client_request_id, coarse_source)
    values (actor, wallpaper_id, current_release,
      (case when desired then 'favorite_added' else 'favorite_removed' end)::wali.event_kind,
      gen_random_uuid(), 'macos');
  end if;
  select count(*) into aggregate_count from wali.favorites f where f.wallpaper_id = set_favorite_v1.wallpaper_id and f.active;
  result := jsonb_build_object('desired', desired, 'revision', next_revision, 'aggregate_count', aggregate_count);
  perform wali.complete_command(actor, 'set_favorite', idempotency_key, result); return result;
end $$;

create or replace function public.set_saved_v1(
  wallpaper_id uuid, desired boolean, expected_revision bigint, idempotency_key text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); existing wali.saved_wallpapers%rowtype; request_hash text; replay jsonb;
  result jsonb; current_release uuid; next_revision bigint; aggregate_count bigint;
begin
  if actor is null then raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED'; end if;
  if not exists (select 1 from wali.profiles p where p.id = actor and p.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  if not wali.take_interaction_quota(actor, 'set_saved') then
    raise exception using errcode = 'P0001', message = 'WALI_RATE_LIMITED';
  end if;
  if expected_revision not between 0 and 9007199254740991 or char_length(idempotency_key) not between 16 and 64
     or idempotency_key !~ '^[A-Za-z0-9_-]+$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  select current_release_id into current_release from wali.wallpapers w where w.id = wallpaper_id and w.status = 'published';
  if current_release is null then raise exception using errcode = 'P0001', message = 'WALI_WALLPAPER_NOT_FOUND'; end if;
  request_hash := encode(extensions.digest(wallpaper_id::text || ':' || desired::text || ':' || expected_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor, 'set_saved', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text || ':saved:' || wallpaper_id::text, 0));
  select * into existing from wali.saved_wallpapers s where s.user_id = actor and s.wallpaper_id = set_saved_v1.wallpaper_id for update;
  if coalesce(existing.revision, 0) <> expected_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  next_revision := coalesce(existing.revision, 0);
  if existing.user_id is null and desired then
    insert into wali.saved_wallpapers (user_id, wallpaper_id, active, revision) values (actor, wallpaper_id, true, 1); next_revision := 1;
  elsif existing.user_id is not null and existing.active <> desired then
    next_revision := existing.revision + 1;
    update wali.saved_wallpapers set active = desired, revision = next_revision, updated_at = statement_timestamp()
    where user_id = actor and saved_wallpapers.wallpaper_id = set_saved_v1.wallpaper_id;
  end if;
  if coalesce(existing.active, false) <> desired then
    insert into wali.engagement_events (user_id, wallpaper_id, release_id, kind, client_request_id, coarse_source)
    values (actor, wallpaper_id, current_release,
      (case when desired then 'saved' else 'unsaved' end)::wali.event_kind,
      gen_random_uuid(), 'macos');
  end if;
  select count(*) into aggregate_count from wali.saved_wallpapers s where s.wallpaper_id = set_saved_v1.wallpaper_id and s.active;
  result := jsonb_build_object('desired', desired, 'revision', next_revision, 'aggregate_count', aggregate_count);
  perform wali.complete_command(actor, 'set_saved', idempotency_key, result); return result;
end $$;

create or replace function public.catalog_browse_v1(
  category text, tags text[], sort text, cursor text, "limit" integer
) returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  decoded jsonb := wali.decode_catalog_cursor(cursor);
  page_limit integer := least(greatest(coalesce("limit", 24), 1), 50);
  cursor_time timestamptz; cursor_id uuid; cursor_score numeric; result jsonb;
begin
  if sort not in ('featured', 'trending', 'newest', 'most_installed')
     or coalesce(cardinality(tags), 0) > 10
     or category is not null and (char_length(category) > 80 or category !~ '^[a-z0-9-]+$')
     or exists (select 1 from unnest(coalesce(tags, '{}'::text[])) value where value !~ '^[a-z0-9-]{1,80}$') then
    raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID';
  end if;
  if decoded is not null then
    if decoded ->> 'sort' <> sort then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
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
      select wali.encode_catalog_cursor(last_row.published_at, last_row.id, last_row.sort_score, sort)
      from page last_row order by last_row.sort_score asc nulls first, last_row.published_at, last_row.id limit 1
    ) else null end
  ) into result from page p;
  return result;
end $$;

create or replace function public.catalog_search_v1(
  query text, filters jsonb, cursor text, "limit" integer
) returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  decoded jsonb := wali.decode_catalog_cursor(cursor);
  page_limit integer := least(greatest(coalesce("limit", 24), 1), 50);
  cursor_time timestamptz; cursor_id uuid; cursor_score numeric; result jsonb;
begin
  filters := coalesce(filters, '{}'::jsonb);
  if query is null or char_length(btrim(query)) not between 1 and 200 or jsonb_typeof(filters) <> 'object'
     or exists (select 1 from jsonb_object_keys(filters) key
       where key not in ('category_slug', 'tag_slugs', 'content_rating_ceiling', 'minimum_duration_ms', 'maximum_duration_ms'))
     or jsonb_array_length(coalesce(filters -> 'tag_slugs', '[]'::jsonb)) > 10 then
    raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID';
  end if;
  if decoded is not null then
    if decoded ->> 'sort' <> 'search-v1' then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
    cursor_time := (decoded ->> 'time')::timestamptz;
    cursor_id := (decoded ->> 'wallpaper_id')::uuid;
    cursor_score := (decoded ->> 'score')::numeric;
  end if;
  with scored as (
    select c.*, round((
      0.75 * least(1, ts_rank_cd(w.search_document, websearch_to_tsquery('simple', left(btrim(query), 200)), 32)) +
      0.15 * coalesce(q.total_score, 0.5) +
      0.10 * greatest(0, 1 - extract(epoch from (statement_timestamp() - c.published_at)) / 2592000.0)
    )::numeric, 8) as sort_score
    from public.catalog_wallpapers_v1 c
    join wali.wallpapers w on w.id = c.id
    left join wali.quality_assessments q on q.release_id = c.current_release_id and q.formula_version = 'quality-v1'
    join public.catalog_wallpaper_details_v1 detail on (detail.wallpaper ->> 'id')::uuid = c.id
    where w.search_document @@ websearch_to_tsquery('simple', left(btrim(query), 200))
      and (filters ->> 'category_slug' is null or c.primary_category ->> 'slug' = filters ->> 'category_slug')
      and (filters ->> 'minimum_duration_ms' is null or detail.duration_ms >= (filters ->> 'minimum_duration_ms')::bigint)
      and (filters ->> 'maximum_duration_ms' is null or detail.duration_ms <= (filters ->> 'maximum_duration_ms')::bigint)
      and (coalesce(jsonb_array_length(filters -> 'tag_slugs'), 0) = 0 or not exists (
        select 1 from jsonb_array_elements_text(filters -> 'tag_slugs') requested(slug) where not exists (
          select 1 from jsonb_array_elements(c.approved_tags) approved where approved ->> 'slug' = requested.slug
        )
      ))
  ), page as (
    select s.* from scored s
    where decoded is null or (s.sort_score, s.published_at, s.id) < (cursor_score, cursor_time, cursor_id)
    order by s.sort_score desc, s.published_at desc, s.id desc limit page_limit
  )
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(to_jsonb(p) - 'sort_score' order by p.sort_score desc, p.published_at desc, p.id desc), '[]'::jsonb),
    'next_cursor', case when count(*) = page_limit then (
      select wali.encode_catalog_cursor(last_row.published_at, last_row.id, last_row.sort_score, 'search-v1')
      from page last_row order by last_row.sort_score, last_row.published_at, last_row.id limit 1
    ) else null end,
    'ranking_explanation', jsonb_build_object('formula_revision', 'search-v1', 'model_revision', null)
  ) into result from page p;
  return result;
exception when invalid_text_representation then
  raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID';
end $$;

create or replace function public.catalog_wallpaper_detail_v1(wallpaper_id uuid)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare result jsonb;
begin
  select to_jsonb(detail) into result from public.catalog_wallpaper_details_v1 detail
  where (detail.wallpaper ->> 'id')::uuid = wallpaper_id;
  if result is null then raise exception using errcode = 'P0001', message = 'WALI_WALLPAPER_NOT_FOUND'; end if;
  return result;
end $$;

create or replace function public.catalog_home_v1(locale text, rating_ceiling text)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare result jsonb;
begin
  if locale is null or char_length(locale) > 35 or rating_ceiling not in ('everyone', 'teen', 'mature') then
    raise exception using errcode = 'P0001', message = 'WALI_FILTER_INVALID';
  end if;
  select jsonb_build_object('sections', coalesce(jsonb_agg(jsonb_build_object(
    'id', section.id, 'title', section.title, 'kind', section.kind,
    'cursor', null, 'items', section.items
  ) order by section.sort_order), '[]'::jsonb)) into result
  from (
    select h.id, h.title, h.kind, h.sort_order, coalesce((
      select jsonb_agg(to_jsonb(page_item) order by page_item.published_at desc, page_item.id desc) from (
        select catalog.* from public.catalog_wallpapers_v1 catalog
        where case catalog.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end
          <= case rating_ceiling when 'everyone' then 0 when 'teen' then 1 else 2 end
          and (h.collection_id is null or exists (
            select 1 from wali.collection_items ci where ci.collection_id = h.collection_id and ci.wallpaper_id = catalog.id
          ))
        order by catalog.published_at desc, catalog.id desc limit 24
      ) page_item
    ), '[]'::jsonb) as items
    from public.catalog_home_v1 h order by h.sort_order limit 8
  ) section;
  return result;
end $$;

revoke all on all tables in schema public from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

grant select on public.catalog_home_v1, public.catalog_wallpapers_v1,
  public.catalog_wallpaper_details_v1, public.catalog_creators_v1,
  public.catalog_categories_v1, public.catalog_tags_v1, public.catalog_collections_v1 to anon, authenticated;
grant select on public.my_profile_v1, public.my_creator_submissions_v1,
  public.my_favorites_v1, public.my_saved_wallpapers_v1 to authenticated;

grant execute on function public.catalog_browse_v1(text, text[], text, text, integer) to anon, authenticated;
grant execute on function public.catalog_search_v1(text, jsonb, text, integer) to anon, authenticated;
grant execute on function public.catalog_wallpaper_detail_v1(uuid) to anon, authenticated;
grant execute on function public.catalog_home_v1(text, text) to anon, authenticated;
grant execute on function public.catalog_creator_v1(text, text, integer) to anon, authenticated;
grant execute on function public.my_favorites_v1(text, integer) to authenticated;
grant execute on function public.my_saved_wallpapers_v1(text, integer) to authenticated;
grant execute on function public.set_favorite_v1(uuid, boolean, bigint, text) to authenticated;
grant execute on function public.set_saved_v1(uuid, boolean, bigint, text) to authenticated;
grant execute on function public.set_creator_follow_v1(uuid, boolean, bigint, text) to authenticated;
grant execute on function public.request_install_v1(uuid, uuid, bigint, text) to authenticated;
grant execute on function wali.encode_catalog_cursor(timestamptz, uuid, numeric, text) to anon, authenticated;
grant execute on function wali.decode_catalog_cursor(text) to anon, authenticated;
