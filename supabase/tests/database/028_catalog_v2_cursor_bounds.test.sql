-- Synthetic local seed only; every fixture and temporary helper rolls back.
begin;
set local search_path=public,extensions;
select no_plan();

create function pg_temp.assert_catalog_v2_pages(route text, selected_sort text)
returns void language plpgsql as $$
declare first_page jsonb; second_page jsonb; terminal_page jsonb; short_page jsonb;
  expected jsonb; actual jsonb; first_cursor text; second_cursor text;
begin
  if route = 'browse' then
    first_page := public.catalog_browse_v2(null,'{}',selected_sort,null,1);
    short_page := public.catalog_browse_v2(null,'{}',selected_sort,null,3);
  else
    first_page := public.catalog_search_v2('Synthetic',jsonb_build_object('sort',selected_sort),null,1);
    short_page := public.catalog_search_v2('Synthetic',jsonb_build_object('sort',selected_sort),null,3);
  end if;
  if jsonb_array_length(first_page->'items') <> 1 or jsonb_array_length(short_page->'items') <> 2
     or short_page->>'next_cursor' is not null then
    raise exception 'expected two visible seed wallpapers and terminal short page';
  end if;
  first_cursor := first_page->>'next_cursor';
  if first_cursor is null or char_length(wali.decode_catalog_cursor(first_cursor)->>'sort') > 32 then
    raise exception 'generated first cursor must satisfy the existing decoder';
  end if;
  if route = 'browse' then
    second_page := public.catalog_browse_v2(null,'{}',selected_sort,first_cursor,1);
  else
    second_page := public.catalog_search_v2('Synthetic',jsonb_build_object('sort',selected_sort),first_cursor,1);
  end if;
  second_cursor := second_page->>'next_cursor';
  if jsonb_array_length(second_page->'items') <> 1 or second_cursor is null then
    raise exception 'second page must advance to the remaining seed wallpaper';
  end if;
  if route = 'browse' then
    terminal_page := public.catalog_browse_v2(null,'{}',selected_sort,second_cursor,1);
  else
    terminal_page := public.catalog_search_v2('Synthetic',jsonb_build_object('sort',selected_sort),second_cursor,1);
  end if;
  if terminal_page->'items' <> '[]'::jsonb or terminal_page->>'next_cursor' is not null then
    raise exception 'full final page must lead to an empty terminal page without a cursor';
  end if;
  select jsonb_agg(item->>'id' order by ordinal) into expected
    from jsonb_array_elements(short_page->'items') with ordinality rows(item,ordinal);
  actual := jsonb_build_array(first_page#>>'{items,0,id}',second_page#>>'{items,0,id}');
  if actual <> expected or actual->>0 = actual->>1 then
    raise exception 'keyset pages must match the complete result order without duplicates';
  end if;
end $$;

select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claim.role','anon',true);
select set_config('request.jwt.claims','{"role":"anon"}',true);
set local role anon;
select lives_ok(format('select pg_temp.assert_catalog_v2_pages(%L,%L)','browse',sort),
  'anonymous V2 Browse advances and terminates: '||sort)
from unnest(array['featured','trending','newest','most_installed']) sort;
select lives_ok(format('select pg_temp.assert_catalog_v2_pages(%L,%L)','search',sort),
  'anonymous V2 Search advances and terminates: '||sort)
from unnest(array['relevance','featured','trending','newest','most_installed']) sort;

select throws_ok($$select wali.decode_catalog_cursor(wali.encode_catalog_cursor(
  '2026-09-01T00:00:00Z','30000000-0000-0000-0000-000000000001',null,repeat('x',33)))$$,
  'P0001','WALI_CURSOR_INVALID','shared decoder still rejects sort markers longer than 32');
select throws_ok($$select public.catalog_browse_v2('space','{}','newest',
  public.catalog_browse_v2(null,'{}','newest',null,1)->>'next_cursor',1)$$,
  'P0001','WALI_CURSOR_INVALID','Browse cursor cannot cross category filters');
select throws_ok($$select public.catalog_browse_v2(null,'{space}','newest',
  public.catalog_browse_v2(null,'{}','newest',null,1)->>'next_cursor',1)$$,
  'P0001','WALI_CURSOR_INVALID','Browse cursor cannot cross tag filters');
select throws_ok($$select public.catalog_browse_v2(null,'{}','trending',
  public.catalog_browse_v2(null,'{}','newest',null,1)->>'next_cursor',1)$$,
  'P0001','WALI_CURSOR_INVALID','Browse cursor cannot cross sort orders');
select throws_ok($$select public.catalog_search_v2('changed','{}',
  public.catalog_search_v2('Synthetic','{}',null,1)->>'next_cursor',1)$$,
  'P0001','WALI_CURSOR_INVALID','Search cursor cannot cross queries');
select throws_ok($$select public.catalog_search_v2('Synthetic','{"content_rating_ceiling":"everyone"}',
  public.catalog_search_v2('Synthetic','{}',null,1)->>'next_cursor',1)$$,
  'P0001','WALI_CURSOR_INVALID','Search cursor cannot cross effective filter inputs');
select throws_ok($$select public.catalog_search_v2('Synthetic','{}',
  public.catalog_browse_v2(null,'{}','newest',null,1)->>'next_cursor',1)$$,
  'P0001','WALI_CURSOR_INVALID','Browse cursor cannot enter Search');
select throws_ok($$select public.catalog_browse_v2(null,'{}','newest',
  public.catalog_search_v2('Synthetic','{}',null,1)->>'next_cursor',1)$$,
  'P0001','WALI_CURSOR_INVALID','Search cursor cannot enter Browse');
select throws_ok($$select public.catalog_browse_v1(null,'{}','newest',
  public.catalog_browse_v2(null,'{}','newest',null,1)->>'next_cursor',1)$$,
  'P0001','WALI_CURSOR_INVALID','V2 Browse cursor cannot enter V1');
select throws_ok($$select public.catalog_browse_v2(null,'{}','newest',
  public.catalog_browse_v1(null,'{}','newest',null,1)->>'next_cursor',1)$$,
  'P0001','WALI_CURSOR_INVALID','V1 Browse cursor cannot enter V2');

reset role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select lives_ok(format('select pg_temp.assert_catalog_v2_pages(%L,%L)','browse',sort),
  'authenticated V2 Browse advances and terminates: '||sort)
from unnest(array['featured','trending','newest','most_installed']) sort;
select lives_ok(format('select pg_temp.assert_catalog_v2_pages(%L,%L)','search',sort),
  'authenticated V2 Search advances and terminates: '||sort)
from unnest(array['relevance','featured','trending','newest','most_installed']) sort;

select * from finish();
rollback;
