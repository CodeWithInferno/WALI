begin;

select plan(9);

select has_function(
  'public', 'catalog_browse_v1',
  array['text', 'text[]', 'text', 'text', 'integer'],
  'bounded browse RPC exists'
);
select has_function(
  'public', 'catalog_search_v1',
  array['text', 'jsonb', 'text', 'integer'],
  'bounded search RPC exists'
);

create temporary table first_page as
select public.catalog_browse_v1(null, '{}'::text[], 'newest', null, 1) as body;
create temporary table repeat_page as
select public.catalog_browse_v1(null, '{}'::text[], 'newest', null, 1) as body;

select results_eq(
  $$select body -> 'items' -> 0 ->> 'id' from first_page$$,
  $$select body -> 'items' -> 0 ->> 'id' from repeat_page$$,
  'fixed data produces the same first browse row'
);
select results_eq(
  $$select body ->> 'next_cursor' from first_page$$,
  $$select body ->> 'next_cursor' from repeat_page$$,
  'fixed data produces the same opaque cursor'
);

select lives_ok(
  $$select public.catalog_browse_v1(
      null, '{}'::text[], 'newest', (select body ->> 'next_cursor' from first_page), 1
    )$$,
  'valid cursor advances without offset pagination'
);

select throws_ok(
  $$select public.catalog_browse_v1(null, '{}'::text[], 'newest', 'not-a-cursor', 1)$$,
  'P0001', 'WALI_CURSOR_INVALID', 'malformed cursor fails with a stable error'
);

create temporary table creator_page as
select public.catalog_creator_v1('synthetic_studio', null, 1) as body;

select results_eq(
  $$select body -> 'items' -> 0 ->> 'id' from creator_page$$,
  $$values ('30000000-0000-0000-0000-000000000001'::text)$$,
  'creator pagination is scoped before limiting the page'
);

select lives_ok(
  $$select public.catalog_creator_v1(
      'synthetic_studio', (select body ->> 'next_cursor' from creator_page), 1
    )$$,
  'creator cursor advances within the same creator scope'
);

select throws_ok(
  $$select public.catalog_creator_v1(
      'synthetic_studio', (select body ->> 'next_cursor' from first_page), 1
    )$$,
  'P0001', 'WALI_CURSOR_INVALID', 'a browse cursor cannot be replayed on a creator feed'
);

select * from finish();
rollback;
