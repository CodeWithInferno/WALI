-- ADR0019, accepted by the project owner on 2026-09-13.
-- Private viewer choices; existing media, grants and moderation stay unchanged.
begin;
create table wali.creator_blocks (
 user_id uuid not null references wali.profiles(id) on delete cascade,
 creator_id uuid not null references wali.profiles(id) on delete cascade,
 active boolean not null, revision bigint not null check(revision between 1 and 9007199254740991),
 created_at timestamptz not null default statement_timestamp(),
 updated_at timestamptz not null default statement_timestamp(),
 primary key(user_id,creator_id), check(user_id<>creator_id)
);
create index creator_blocks_active_viewer on wali.creator_blocks(user_id,creator_id) where active;
create index creator_blocks_deleted_creator on wali.creator_blocks(creator_id);
create table wali.creator_block_preferences (
 user_id uuid primary key references wali.profiles(id) on delete cascade,
 generation bigint not null check(generation between 1 and 9007199254740991),
 updated_at timestamptz not null default statement_timestamp()
);
alter table wali.creator_blocks enable row level security;
alter table wali.creator_block_preferences enable row level security;
create policy creator_blocks_outgoing_read on wali.creator_blocks for select to authenticated
 using(user_id=auth.uid() and exists(select 1 from wali.profiles p where p.id=auth.uid() and p.status='active'));
revoke all on wali.creator_blocks, wali.creator_block_preferences from public, anon, authenticated, service_role;
grant select(user_id,creator_id,active,revision,created_at,updated_at) on wali.creator_blocks to authenticated;

-- Per-viewer ordering precedes every action-specific lock. The common lock also
-- serializes the active-list cap and generation; no creator can read its users.
create function wali.lock_creator_preferences(actor_id uuid) returns void
 language sql volatile security definer set search_path='' as $$
 select pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('creator-privacy:'||actor_id::text,0))
$$;
revoke all on function wali.lock_creator_preferences(uuid) from public,anon,authenticated,service_role;
create function wali.creator_is_blocked(creator_id uuid) returns boolean
 language sql stable security definer set search_path='' as $$
 select exists(select 1 from wali.creator_blocks b where b.user_id=auth.uid() and b.creator_id=creator_is_blocked.creator_id and b.active)
$$;
revoke all on function wali.creator_is_blocked(uuid) from public;
grant execute on function wali.creator_is_blocked(uuid) to anon,authenticated;

create function public.set_creator_block_v1(creator_id uuid, desired boolean, expected_revision bigint, idempotency_key text)
 returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); existing wali.creator_blocks%rowtype; next_revision bigint;
 generation bigint; replay jsonb; result jsonb; request_hash text;
begin
 if actor is null then raise exception using errcode='P0001',message='WALI_AUTH_REQUIRED'; end if;
 perform p.id from wali.profiles p where p.id in (actor,creator_id) order by p.id for share;
 if not exists(select 1 from wali.profiles p where p.id=actor and p.status='active') then
  raise exception using errcode='P0001',message='WALI_ACCOUNT_INACTIVE'; end if;
 if creator_id is null or desired is null or expected_revision is null or idempotency_key is null
  or creator_id=actor or expected_revision not between 0 and 9007199254740991
  or char_length(idempotency_key) not between 16 and 64 or idempotency_key !~ '^[A-Za-z0-9_-]+$' then
  raise exception using errcode='P0001',message='WALI_REQUEST_INVALID'; end if;
 perform wali.lock_creator_preferences(actor);
 if not wali.take_interaction_quota(actor,'set_creator_block') then
  raise exception using errcode='P0001',message='WALI_RATE_LIMITED'; end if;
 request_hash:=encode(extensions.digest(creator_id::text||':'||desired::text||':'||expected_revision::text,'sha256'),'hex');
 replay:=wali.reserve_command(actor,'set_creator_block',idempotency_key,request_hash);
 if replay is not null then return replay; end if;
 select * into existing from wali.creator_blocks b where b.user_id=actor and b.creator_id=set_creator_block_v1.creator_id for update;
 if coalesce(existing.revision,0)<>expected_revision then
  raise exception using errcode='P0001',message='WALI_REVISION_MISMATCH'; end if;
 if (desired or existing.user_id is null) and not exists(select 1 from wali.profiles p
  join wali.creator_profiles cp on cp.user_id=p.id where p.id=creator_id and p.status='active') then
  raise exception using errcode='P0001',message='WALI_CREATOR_NOT_FOUND'; end if;
 next_revision:=coalesce(existing.revision,0);
 if coalesce(existing.active,false)<>desired then
  if desired and (select count(*) from wali.creator_blocks b where b.user_id=actor and b.active)>=10000 then
   raise exception using errcode='P0001',message='WALI_BLOCK_LIMIT_REACHED'; end if;
  if next_revision>=9007199254740991 then raise exception using errcode='P0001',message='WALI_REVISION_MISMATCH'; end if;
  next_revision:=next_revision+1;
  insert into wali.creator_blocks(user_id,creator_id,active,revision) values(actor,creator_id,desired,next_revision)
   on conflict on constraint creator_blocks_pkey do update set active=excluded.active,revision=excluded.revision,updated_at=statement_timestamp();
  insert into wali.creator_block_preferences(user_id,generation) values(actor,1)
   on conflict(user_id) do update set generation=wali.creator_block_preferences.generation+1,updated_at=statement_timestamp();
 end if;
 select coalesce((select p.generation from wali.creator_block_preferences p where p.user_id=actor),0) into generation;
 result:=jsonb_build_object('subject_id',actor,'creator_id',creator_id,'desired',desired,'revision',next_revision,'generation',generation);
 perform wali.complete_command(actor,'set_creator_block',idempotency_key,result); return result;
end $$;

-- Opaque, bounded cursors are tied to the subject, operation and current generation.
-- They carry no media or incoming relationship data.
create function wali.decode_creator_block_cursor(cursor text, actor_id uuid, generation bigint, kind text)
 returns jsonb language plpgsql immutable set search_path='' as $$
declare value jsonb;
begin
 if cursor is null then return null; end if;
 if length(cursor) not between 1 and 1024 or cursor !~ '^[A-Za-z0-9+/=]+$' then
  raise exception using errcode='P0001',message='WALI_CURSOR_INVALID'; end if;
 begin value:=convert_from(decode(cursor,'base64'),'UTF8')::jsonb;
  if jsonb_typeof(value)<>'object' or (select count(*) from jsonb_object_keys(value))<>5
   or value->>'subject_id' is distinct from actor_id::text or value->>'kind' is distinct from kind
   or value->>'generation' is distinct from generation::text
   or value->>'id' is null or (value->>'id')::uuid::text<>value->>'id'
   or value->>'interaction' is null then raise exception 'invalid'; end if;
 exception when others then raise exception using errcode='P0001',message='WALI_CURSOR_INVALID'; end;
 return value;
end $$;
revoke all on function wali.decode_creator_block_cursor(text,uuid,bigint,text) from public,anon,authenticated,service_role;

create function public.my_creator_blocks_v1(cursor text, "limit" integer, selected_creator_id uuid default null)
 returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); generation bigint; decoded jsonb; result jsonb;
begin
 if actor is null then raise exception using errcode='P0001',message='WALI_AUTH_REQUIRED'; end if;
 if not exists(select 1 from wali.profiles p where p.id=actor and p.status='active') then
  raise exception using errcode='P0001',message='WALI_ACCOUNT_INACTIVE'; end if;
 if "limit" is null or "limit" not between 1 and 100 then raise exception using errcode='P0001',message='WALI_REQUEST_INVALID'; end if;
 generation:=coalesce((select p.generation from wali.creator_block_preferences p where p.user_id=actor),0);
 if selected_creator_id is not null and (cursor is not null or selected_creator_id=actor) then raise exception using errcode='P0001',message='WALI_REQUEST_INVALID'; end if;
 decoded:=wali.decode_creator_block_cursor(cursor,actor,generation,'blocks');
 if decoded is not null and decoded->>'interaction'<>'block' then raise exception using errcode='P0001',message='WALI_CURSOR_INVALID'; end if;
 with page as (
  select b.creator_id,b.revision,b.active,
   case when p.status='active' and cp.user_id is not null then p.display_name else null end as display_name,
   case when p.status='active' and cp.user_id is not null then p.handle::text else null end as handle
  from wali.creator_blocks b join wali.profiles p on p.id=b.creator_id
  left join wali.creator_profiles cp on cp.user_id=p.id
  where b.user_id=actor and (case when selected_creator_id is null then b.active else b.creator_id=selected_creator_id end) and (decoded is null or b.creator_id>(decoded->>'id')::uuid)
  order by b.creator_id limit "limit"
 ) select jsonb_build_object('subject_id',actor,'generation',generation,
  'items',coalesce(jsonb_agg(to_jsonb(p) order by p.creator_id),'[]'),
  'next_cursor',case when selected_creator_id is null and count(*)="limit" then replace(encode(convert_to(jsonb_build_object(
   'subject_id',actor,'generation',generation,'kind','blocks','interaction','block','id',max(p.creator_id::text))::text,'UTF8'),'base64'),E'\n','') else null end)
 into result from page p;
 return result;
end $$;

create function public.my_hidden_interactions_v1(cursor text, "limit" integer)
 returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); generation bigint; decoded jsonb; result jsonb;
begin
 if actor is null then raise exception using errcode='P0001',message='WALI_AUTH_REQUIRED'; end if;
 if not exists(select 1 from wali.profiles p where p.id=actor and p.status='active') then
  raise exception using errcode='P0001',message='WALI_ACCOUNT_INACTIVE'; end if;
 if "limit" is null or "limit" not between 1 and 100 then raise exception using errcode='P0001',message='WALI_REQUEST_INVALID'; end if;
 generation:=coalesce((select p.generation from wali.creator_block_preferences p where p.user_id=actor),0);
 decoded:=wali.decode_creator_block_cursor(cursor,actor,generation,'hidden');
 if decoded is not null and decoded->>'interaction' not in ('favorite','saved','follow') then raise exception using errcode='P0001',message='WALI_CURSOR_INVALID'; end if;
 with hidden as (
  select f.wallpaper_id as target_id,'favorite'::text as kind,f.active,f.revision from wali.favorites f
   join wali.wallpapers w on w.id=f.wallpaper_id join wali.creator_blocks b on b.creator_id=w.creator_id and b.user_id=actor and b.active
   where f.user_id=actor and f.active
  union all
  select s.wallpaper_id,'saved',s.active,s.revision from wali.saved_wallpapers s
   join wali.wallpapers w on w.id=s.wallpaper_id join wali.creator_blocks b on b.creator_id=w.creator_id and b.user_id=actor and b.active
   where s.user_id=actor and s.active
  union all
  select f.creator_id,'follow',f.active,f.revision from wali.creator_follows f
   join wali.creator_blocks b on b.creator_id=f.creator_id and b.user_id=actor and b.active
   where f.user_id=actor and f.active
 ), page as (
  select * from hidden h where decoded is null or (h.kind,h.target_id)>(decoded->>'interaction',(decoded->>'id')::uuid)
   order by h.kind,h.target_id limit "limit"
 ) select jsonb_build_object('subject_id',actor,'generation',generation,
  'items',coalesce(jsonb_agg(to_jsonb(p) order by p.kind,p.target_id),'[]'),
  'next_cursor',case when count(*)="limit" then (select replace(encode(convert_to(jsonb_build_object(
   'subject_id',actor,'generation',generation,'kind','hidden','interaction',last.kind,'id',last.target_id)::text,'UTF8'),'base64'),E'\n','')
   from page last order by last.kind desc,last.target_id desc limit 1) else null end)
 into result from page p;
 return result;
end $$;
revoke all on function public.set_creator_block_v1(uuid,boolean,bigint,text),public.my_creator_blocks_v1(text,integer,uuid),public.my_hidden_interactions_v1(text,integer) from public,anon;
grant execute on function public.set_creator_block_v1(uuid,boolean,bigint,text),public.my_creator_blocks_v1(text,integer,uuid),public.my_hidden_interactions_v1(text,integer) to authenticated;


create or replace function wali.take_interaction_quota(actor_id uuid, operation_name text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare bucket_start timestamptz := date_trunc('minute', statement_timestamp()); current_count integer;
begin
  if operation_name not in ('set_favorite', 'set_saved', 'set_creator_follow', 'set_creator_block') then return false; end if;
  insert into wali.rate_limit_buckets (subject_hash, operation, window_start, window_seconds, counter, expires_at)
  values (encode(extensions.digest(actor_id::text, 'sha256'), 'hex'), operation_name,
    bucket_start, 60, 1, bucket_start + interval '2 minutes')
  on conflict (subject_hash, operation, window_start) do update set
    counter = wali.rate_limit_buckets.counter + 1, updated_at = statement_timestamp()
  returning counter into current_count;
  return current_count <= 120;
end $$;

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
  and case w.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= wali.catalog_rating_limit()
  and not wali.creator_is_blocked(w.creator_id);

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
  and case w.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= wali.catalog_rating_limit()
  and not wali.creator_is_blocked(w.creator_id);

create or replace view public.catalog_creators_v1
with (security_invoker = true, security_barrier = true) as
select p.id, p.handle::text as handle, p.display_name,
  case when p.avatar_path is null then null else cfg.catalog_public_base_url || '/' || p.avatar_path end as avatar_url,
  cp.bio, cp.website_url, cp.verification_status::text as verification_status,
  count(w.id)::bigint as published_wallpaper_count
from wali.runtime_configuration cfg
join wali.profiles p on true
join wali.creator_profiles cp on cp.user_id = p.id
left join public.catalog_wallpapers_v1 w on (w.creator->>'id')::uuid=p.id
where cfg.singleton and p.status = 'active' and not wali.creator_is_blocked(p.id)
group by p.id, p.handle, p.display_name, p.avatar_path, cp.bio, cp.website_url,
  cp.verification_status, cfg.catalog_public_base_url;

create or replace view public.catalog_categories_v1
with (security_invoker = true, security_barrier = true) as
select c.id, c.parent_id, c.slug, c.name, c.description, c.sort_order,
  count(w.id)::bigint as published_wallpaper_count
from wali.categories c
left join wali.wallpapers w on w.primary_category_id = c.id and w.status = 'published' and w.visibility = 'public' and not wali.creator_is_blocked(w.creator_id)
where c.active group by c.id;

create or replace view public.catalog_tags_v1
with (security_invoker = true, security_barrier = true) as
select t.id, t.slug, t.label as name, t.kind::text as kind,
  count(distinct w.id)::bigint as published_wallpaper_count
from wali.tags t
left join wali.wallpaper_tags wt on wt.tag_id = t.id and wt.status = 'approved'
left join wali.wallpapers w on w.id = wt.wallpaper_id and w.status = 'published' and w.visibility = 'public' and not wali.creator_is_blocked(w.creator_id)
where t.active group by t.id;

create or replace view public.catalog_collections_v1
with (security_invoker = true, security_barrier = true) as
select c.id, c.slug, c.title, c.description, c.kind::text as kind,
  c.artwork_path, c.active_from, c.active_until,
  coalesce(jsonb_agg(jsonb_build_object(
    'wallpaper_id', ci.wallpaper_id, 'ordinal', ci.ordinal, 'caption', ci.editorial_caption
  ) order by ci.ordinal) filter (where ci.wallpaper_id is not null), '[]'::jsonb) as items
from wali.collections c left join wali.collection_items ci on ci.collection_id = c.id and exists(select 1 from public.catalog_wallpapers_v1 w where w.id=ci.wallpaper_id)
where c.status = 'published'
  and (c.active_from is null or c.active_from <= statement_timestamp())
  and (c.active_until is null or c.active_until > statement_timestamp())
group by c.id;

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
  perform wali.lock_creator_preferences(actor);
  if not wali.take_interaction_quota(actor, 'set_favorite') then
    raise exception using errcode = 'P0001', message = 'WALI_RATE_LIMITED';
  end if;
  if desired is null or expected_revision is null or idempotency_key is null or expected_revision not between 0 and 9007199254740991 or char_length(idempotency_key) not between 16 and 64
     or idempotency_key !~ '^[A-Za-z0-9_-]+$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  select current_release_id into current_release from wali.wallpapers w where w.id = wallpaper_id and (w.status = 'published' or (desired=false and exists(select 1 from wali.favorites f where f.user_id=actor and f.wallpaper_id=set_favorite_v1.wallpaper_id)));
  if current_release is null and not (desired=false and exists(select 1 from wali.favorites f where f.user_id=actor and f.wallpaper_id=set_favorite_v1.wallpaper_id)) then raise exception using errcode = 'P0001', message = 'WALI_WALLPAPER_NOT_FOUND'; end if;
  request_hash := encode(extensions.digest(wallpaper_id::text || ':' || desired::text || ':' || expected_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor, 'set_favorite', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  if desired and exists(select 1 from wali.wallpapers w where w.id=set_favorite_v1.wallpaper_id and wali.creator_is_blocked(w.creator_id)) then raise exception using errcode='P0001',message='WALI_CREATOR_BLOCKED'; end if;
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
  perform wali.lock_creator_preferences(actor);
  if not wali.take_interaction_quota(actor, 'set_saved') then
    raise exception using errcode = 'P0001', message = 'WALI_RATE_LIMITED';
  end if;
  if desired is null or expected_revision is null or idempotency_key is null or expected_revision not between 0 and 9007199254740991 or char_length(idempotency_key) not between 16 and 64
     or idempotency_key !~ '^[A-Za-z0-9_-]+$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  select current_release_id into current_release from wali.wallpapers w where w.id = wallpaper_id and (w.status = 'published' or (desired=false and exists(select 1 from wali.saved_wallpapers f where f.user_id=actor and f.wallpaper_id=set_saved_v1.wallpaper_id)));
  if current_release is null and not (desired=false and exists(select 1 from wali.saved_wallpapers f where f.user_id=actor and f.wallpaper_id=set_saved_v1.wallpaper_id)) then raise exception using errcode = 'P0001', message = 'WALI_WALLPAPER_NOT_FOUND'; end if;
  request_hash := encode(extensions.digest(wallpaper_id::text || ':' || desired::text || ':' || expected_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor, 'set_saved', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  if desired and exists(select 1 from wali.wallpapers w where w.id=set_saved_v1.wallpaper_id and wali.creator_is_blocked(w.creator_id)) then raise exception using errcode='P0001',message='WALI_CREATOR_BLOCKED'; end if;
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
  perform wali.lock_creator_preferences(actor);
  if not wali.take_interaction_quota(actor, 'set_creator_follow') then
    raise exception using errcode = 'P0001', message = 'WALI_RATE_LIMITED';
  end if;
  if creator_id = actor then raise exception using errcode = 'P0001', message = 'WALI_SELF_FOLLOW_FORBIDDEN'; end if;
  if desired is null or expected_revision is null or idempotency_key is null or expected_revision not between 0 and 9007199254740991 or char_length(idempotency_key) not between 16 and 64
     or idempotency_key !~ '^[A-Za-z0-9_-]+$' then raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID'; end if;
  if not exists (select 1 from wali.creator_profiles cp where cp.user_id = creator_id) and not (desired=false and exists(select 1 from wali.creator_follows f where f.user_id=actor and f.creator_id=set_creator_follow_v1.creator_id)) then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_NOT_FOUND';
  end if;
  request_hash := encode(extensions.digest(creator_id::text || ':' || desired::text || ':' || expected_revision::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor, 'set_creator_follow', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  if desired and wali.creator_is_blocked(creator_id) then raise exception using errcode='P0001',message='WALI_CREATOR_BLOCKED'; end if;
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
  perform wali.lock_creator_preferences(actor_id);
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
  if exists(select 1 from wali.creator_blocks b join wali.wallpapers w on w.creator_id=b.creator_id where b.user_id=actor_id and b.active and w.id=wali_edge_request_install_v1.wallpaper_id) then raise exception using errcode='P0001',message='WALI_CREATOR_BLOCKED'; end if;
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
  perform wali.lock_creator_preferences(actor_id);
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
  if exists(select 1 from wali.creator_blocks b join wali.wallpapers w on w.creator_id=b.creator_id where b.user_id=actor_id and b.active and w.id=wali_edge_request_install_v2.wallpaper_id) then raise exception using errcode='P0001',message='WALI_CREATOR_BLOCKED'; end if;
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

create or replace function public.request_install_v1(
  wallpaper_id uuid, release_id uuid, expected_wallpaper_revision bigint, idempotency_key text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); wallpaper_row wali.wallpapers%rowtype; release_row wali.wallpaper_releases%rowtype;
  request_hash text; replay jsonb; receipt wali.install_receipts%rowtype; result jsonb;
begin
  if actor is null then raise exception using errcode = 'P0001', message = 'WALI_AUTH_REQUIRED'; end if;
  perform wali.lock_creator_preferences(actor);
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
  if exists(select 1 from wali.creator_blocks b join wali.wallpapers w on w.creator_id=b.creator_id where b.user_id=actor and b.active and w.id=request_install_v1.wallpaper_id) then raise exception using errcode='P0001',message='WALI_CREATOR_BLOCKED'; end if;
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
    'creator_blocks', coalesce((select jsonb_agg(to_jsonb(x) order by creator_id)
      from (select creator_id, active, revision, created_at, updated_at from wali.creator_blocks
        where user_id=worker_read_account_export.user_id) x), '[]'::jsonb),
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

commit;
