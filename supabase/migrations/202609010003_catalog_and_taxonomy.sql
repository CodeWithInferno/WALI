-- WALI Marketplace foundation: rights, taxonomy, catalog, search, and editorial collections.

create table wali.licenses (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  spdx_expression text,
  terms_url text not null,
  attribution_required boolean not null,
  commercial_use_allowed boolean not null,
  derivatives_allowed boolean not null,
  redistribution_allowed boolean not null,
  active boolean not null default true,
  terms_revision integer not null check (terms_revision > 0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint licenses_code_format check (code ~ '^[a-z0-9][a-z0-9._-]{1,63}$'),
  constraint licenses_name_plain check (wali.plain_text_is_valid(name, 1, 120)),
  constraint licenses_spdx_format check (spdx_expression is null or spdx_expression ~ '^[A-Za-z0-9.+() -]{1,200}$'),
  constraint licenses_terms_https check (terms_url is not null and wali.https_url_is_valid(terms_url))
);

create table wali.categories (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references wali.categories(id) on delete restrict,
  slug text not null unique,
  name text not null,
  description text not null,
  sort_order integer not null default 0 check (sort_order between -100000 and 100000),
  active boolean not null default true,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint categories_slug_format check (slug ~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$'),
  constraint categories_name_plain check (wali.plain_text_is_valid(name, 1, 80)),
  constraint categories_description_plain check (wali.plain_text_is_valid(description, 1, 500)),
  constraint categories_not_self_parent check (parent_id is null or parent_id <> id)
);

create table wali.tags (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  label text not null,
  kind wali.tag_kind not null,
  active boolean not null default true,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint tags_slug_format check (slug ~ '^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$'),
  constraint tags_label_plain check (wali.plain_text_is_valid(label, 1, 80))
);

create table wali.wallpapers (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references wali.profiles(id) on delete restrict,
  slug extensions.citext not null unique,
  title text not null,
  description text not null,
  status wali.wallpaper_status not null default 'draft',
  visibility wali.visibility not null default 'public',
  content_rating wali.content_rating not null default 'everyone',
  primary_category_id uuid not null references wali.categories(id) on delete restrict,
  license_id uuid not null references wali.licenses(id) on delete restrict,
  rights_holder_display text not null,
  attribution_text text,
  source_url text,
  current_release_id uuid,
  search_document tsvector not null default ''::tsvector,
  revision bigint not null default 1 check (revision > 0),
  published_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  removed_at timestamptz,
  constraint wallpapers_slug_format check (slug::text ~ '^[a-z0-9][a-z0-9-]{1,118}[a-z0-9]$'),
  constraint wallpapers_title_plain check (wali.plain_text_is_valid(title, 1, 120)),
  constraint wallpapers_description_plain check (wali.plain_text_is_valid(description, 1, 2000)),
  constraint wallpapers_rights_holder_plain check (wali.plain_text_is_valid(rights_holder_display, 1, 160)),
  constraint wallpapers_attribution_plain check (
    attribution_text is null or wali.plain_text_is_valid(attribution_text, 1, 500)
  ),
  constraint wallpapers_source_https check (wali.https_url_is_valid(source_url)),
  constraint wallpapers_publish_fields check (
    status <> 'published' or (published_at is not null and current_release_id is not null)
  ),
  constraint wallpapers_removed_pair check ((status = 'removed') = (removed_at is not null))
);

create table wali.wallpaper_categories (
  wallpaper_id uuid not null references wali.wallpapers(id) on delete cascade,
  category_id uuid not null references wali.categories(id) on delete restrict,
  source wali.taxonomy_source not null,
  confidence numeric(5,4),
  model_run_id uuid,
  approved_by uuid references wali.profiles(id) on delete restrict,
  approved_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  primary key (wallpaper_id, category_id, source),
  constraint wallpaper_categories_confidence check (confidence is null or confidence between 0 and 1),
  constraint wallpaper_categories_approval_pair check ((approved_by is null) = (approved_at is null)),
  constraint wallpaper_categories_model_source check ((source = 'classifier') = (model_run_id is not null))
);

create table wali.wallpaper_tags (
  wallpaper_id uuid not null references wali.wallpapers(id) on delete cascade,
  tag_id uuid not null references wali.tags(id) on delete restrict,
  source wali.taxonomy_source not null,
  confidence numeric(5,4),
  status wali.suggestion_status not null default 'suggested',
  model_run_id uuid,
  decided_by uuid references wali.profiles(id) on delete restrict,
  decided_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  primary key (wallpaper_id, tag_id, source),
  constraint wallpaper_tags_confidence check (confidence is null or confidence between 0 and 1),
  constraint wallpaper_tags_decision_pair check ((decided_by is null) = (decided_at is null)),
  constraint wallpaper_tags_model_source check ((source = 'classifier') = (model_run_id is not null)),
  constraint wallpaper_tags_approved_actor check (status = 'suggested' or decided_by is not null)
);

create table wali.wallpaper_embeddings (
  wallpaper_id uuid not null references wali.wallpapers(id) on delete cascade,
  release_id uuid not null,
  modality wali.embedding_modality not null,
  model_id text not null,
  model_revision text not null,
  embedding extensions.vector(768) not null,
  input_digest text not null,
  created_at timestamptz not null default statement_timestamp(),
  primary key (wallpaper_id, release_id, modality, model_id, model_revision),
  constraint wallpaper_embeddings_model_id check (model_id ~ '^[a-z0-9][a-z0-9._/-]{1,127}$'),
  constraint wallpaper_embeddings_model_revision check (char_length(model_revision) between 1 and 128),
  constraint wallpaper_embeddings_digest check (input_digest ~ '^[0-9a-f]{64}$'),
  constraint wallpaper_embeddings_dimension check (extensions.vector_dims(embedding) = 768)
);

create table wali.collections (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  description text not null,
  kind wali.collection_kind not null,
  status wali.collection_status not null default 'draft',
  artwork_path text,
  active_from timestamptz,
  active_until timestamptz,
  editor_id uuid not null references wali.profiles(id) on delete restrict,
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint collections_slug_format check (slug ~ '^[a-z0-9][a-z0-9-]{1,118}[a-z0-9]$'),
  constraint collections_title_plain check (wali.plain_text_is_valid(title, 1, 120)),
  constraint collections_description_plain check (wali.plain_text_is_valid(description, 1, 1000)),
  constraint collections_artwork_generated check (
    artwork_path is null or artwork_path ~ '^sha256/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{64}/artwork\.(png|jpe?g)$'
  ),
  constraint collections_window_valid check (active_until is null or active_from is null or active_until > active_from)
);

create table wali.collection_items (
  collection_id uuid not null references wali.collections(id) on delete cascade,
  wallpaper_id uuid not null references wali.wallpapers(id) on delete restrict,
  ordinal integer not null check (ordinal between 0 and 10000),
  editorial_caption text,
  created_at timestamptz not null default statement_timestamp(),
  primary key (collection_id, wallpaper_id),
  unique (collection_id, ordinal),
  constraint collection_items_caption_plain check (
    editorial_caption is null or wali.plain_text_is_valid(editorial_caption, 1, 280)
  )
);

create index wallpapers_creator_status_updated_idx on wali.wallpapers (creator_id, status, updated_at desc, id);
create index wallpapers_category_published_idx on wali.wallpapers (primary_category_id, published_at desc, id)
  where status = 'published';
create index wallpapers_published_idx on wali.wallpapers (published_at desc, id)
  where status = 'published';
create index wallpapers_search_document_gin on wali.wallpapers using gin (search_document);
create index wallpaper_tags_approved_idx on wali.wallpaper_tags (tag_id, wallpaper_id)
  where status = 'approved';
create index wallpaper_categories_approved_idx on wali.wallpaper_categories (category_id, wallpaper_id)
  where approved_at is not null;
create index wallpaper_embeddings_combined_hnsw on wali.wallpaper_embeddings
  using hnsw (embedding extensions.vector_cosine_ops)
  where modality = 'combined' and model_id = 'google/siglip-base-patch16-224';
create index collections_published_window_idx on wali.collections (active_from, active_until, id)
  where status = 'published';

create or replace function wali.refresh_wallpaper_search(target_wallpaper_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update wali.wallpapers w
     set search_document =
       setweight(to_tsvector('simple', coalesce(w.title, '')), 'A') ||
       setweight(to_tsvector('simple', coalesce(p.display_name, '')), 'A') ||
       setweight(to_tsvector('simple', coalesce(c.name, '')), 'B') ||
       setweight(to_tsvector('simple', coalesce((
         select string_agg(t.label, ' ' order by t.label)
           from wali.wallpaper_tags wt
           join wali.tags t on t.id = wt.tag_id
          where wt.wallpaper_id = w.id and wt.status = 'approved' and t.active
       ), '')), 'B') ||
       setweight(to_tsvector('simple', coalesce(w.description, '')), 'C')
    from wali.profiles p, wali.categories c
   where w.id = target_wallpaper_id
     and p.id = w.creator_id
     and c.id = w.primary_category_id
$$;

create or replace function wali.wallpaper_search_row_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform wali.refresh_wallpaper_search(coalesce(new.id, old.id));
  return coalesce(new, old);
end
$$;

create or replace function wali.wallpaper_search_taxonomy_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform wali.refresh_wallpaper_search(coalesce(new.wallpaper_id, old.wallpaper_id));
  return coalesce(new, old);
end
$$;

create trigger wallpapers_touch before update on wali.wallpapers
for each row execute function wali.touch_mutable_row();
create trigger licenses_touch before update on wali.licenses
for each row execute function wali.touch_mutable_row();
create trigger categories_touch before update on wali.categories
for each row execute function wali.touch_mutable_row();
create trigger tags_touch before update on wali.tags
for each row execute function wali.touch_mutable_row();
create trigger collections_touch before update on wali.collections
for each row execute function wali.touch_mutable_row();

create trigger wallpapers_search_after_row
after insert or update of title, description, creator_id, primary_category_id on wali.wallpapers
for each row execute function wali.wallpaper_search_row_trigger();
create trigger wallpaper_tags_search_after_row
after insert or update or delete on wali.wallpaper_tags
for each row execute function wali.wallpaper_search_taxonomy_trigger();

alter table wali.licenses enable row level security;
alter table wali.categories enable row level security;
alter table wali.tags enable row level security;
alter table wali.wallpapers enable row level security;
alter table wali.wallpaper_categories enable row level security;
alter table wali.wallpaper_tags enable row level security;
alter table wali.wallpaper_embeddings enable row level security;
alter table wali.collections enable row level security;
alter table wali.collection_items enable row level security;

create policy licenses_public_read on wali.licenses for select to anon, authenticated using (active);
create policy categories_public_read on wali.categories for select to anon, authenticated using (active);
create policy tags_public_read on wali.tags for select to anon, authenticated using (active);
create policy wallpapers_public_read on wali.wallpapers for select to anon, authenticated
using (status = 'published');
create policy wallpapers_private_read on wali.wallpapers for select to authenticated
using (creator_id = auth.uid() or wali.has_moderation_access());
create policy wallpaper_categories_public_read on wali.wallpaper_categories for select to anon, authenticated
using (exists (select 1 from wali.wallpapers w where w.id = wallpaper_id and w.status = 'published'));
create policy wallpaper_tags_public_read on wali.wallpaper_tags for select to anon, authenticated
using (
  status = 'approved'
  and exists (select 1 from wali.wallpapers w where w.id = wallpaper_id and w.status = 'published')
);
create policy collections_public_read on wali.collections for select to anon, authenticated
using (
  status = 'published'
  and (active_from is null or active_from <= statement_timestamp())
  and (active_until is null or active_until > statement_timestamp())
);
create policy collection_items_public_read on wali.collection_items for select to anon, authenticated
using (
  exists (select 1 from wali.collections c where c.id = collection_id and c.status = 'published')
  and exists (select 1 from wali.wallpapers w where w.id = wallpaper_id and w.status = 'published')
);

grant select on wali.licenses, wali.categories, wali.tags, wali.wallpapers,
  wali.wallpaper_categories, wali.wallpaper_tags, wali.collections, wali.collection_items
to anon, authenticated;

revoke all on function wali.refresh_wallpaper_search(uuid) from public, anon, authenticated;
revoke all on function wali.wallpaper_search_row_trigger() from public, anon, authenticated;
revoke all on function wali.wallpaper_search_taxonomy_trigger() from public, anon, authenticated;
