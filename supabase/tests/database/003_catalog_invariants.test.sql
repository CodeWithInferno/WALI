begin;

select plan(14);

select has_table('wali', 'licenses', 'licenses table exists');
select has_table('wali', 'categories', 'categories table exists');
select has_table('wali', 'tags', 'tags table exists');
select has_table('wali', 'wallpapers', 'wallpapers table exists');
select has_table('wali', 'wallpaper_categories', 'wallpaper category provenance exists');
select has_table('wali', 'wallpaper_tags', 'wallpaper tag provenance exists');
select has_table('wali', 'wallpaper_embeddings', 'wallpaper embeddings exist');
select has_table('wali', 'collections', 'collections table exists');
select has_table('wali', 'collection_items', 'collection items exist');

select col_type_is('wali', 'wallpaper_embeddings', 'embedding', 'vector(768)', 'embeddings have the fixed v1 dimension');
select has_index('wali', 'wallpapers', 'wallpapers_search_document_gin', 'catalog has a GIN search index');

select throws_ok(
  $$insert into wali.categories (slug, name, description)
    values ('Unsafe Category', 'Unsafe', 'invalid slug')$$,
  '23514',
  null,
  'category slugs are normalized and bounded'
);

select throws_ok(
  $$insert into wali.licenses (
      code, name, terms_url, attribution_required, commercial_use_allowed,
      derivatives_allowed, redistribution_allowed, terms_revision
    ) values ('unsafe', 'Unsafe', 'http://example.invalid/terms', false, false, false, false, 1)$$,
  '23514',
  null,
  'license terms URL must use HTTPS'
);

select results_eq(
  $$select count(*)::bigint from information_schema.role_table_grants
     where table_schema = 'wali' and table_name = 'wallpapers'
       and grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE', 'DELETE')$$,
  array[0::bigint],
  'authenticated cannot mutate authoritative catalog rows'
);

select * from finish();
rollback;
