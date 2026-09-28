-- Synthetic local seed only; current publication times keep freshness active.
-- Separate statements and bounded sleeps model separate HTTP request clocks.
begin;
set local search_path=public,extensions;
select no_plan();
update wali.wallpapers set published_at=statement_timestamp()-interval '1 day'
  where id='30000000-0000-0000-0000-000000000001';
update wali.wallpapers set published_at=statement_timestamp()-interval '2 days'
  where id='30000000-0000-0000-0000-000000000002';
create temporary table search_paging_receipts(name text primary key,payload jsonb);
grant all on search_paging_receipts to anon,authenticated;

select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claim.role','anon',true);
select set_config('request.jwt.claims','{"role":"anon"}',true);
set local role anon;
insert into search_paging_receipts values('anonymous_reference',public.catalog_search_v2('Synthetic','{}',null,50));
insert into search_paging_receipts values('anonymous_first',public.catalog_search_v2('Synthetic','{}',null,1));
select is(jsonb_array_length((select payload->'items' from search_paging_receipts where name='anonymous_reference')),2,'anonymous reference contains both visible fixtures');
select pg_sleep(0.6);
insert into search_paging_receipts values('anonymous_second',public.catalog_search_v2('Synthetic','{}',
  (select payload->>'next_cursor' from search_paging_receipts where name='anonymous_first'),1));
select isnt((select payload#>>'{items,0,id}' from search_paging_receipts where name='anonymous_second'),
  (select payload#>>'{items,0,id}' from search_paging_receipts where name='anonymous_first'),'anonymous second request never repeats its decayed relevance anchor');
select is(jsonb_build_array(
  (select payload#>>'{items,0,id}' from search_paging_receipts where name='anonymous_first'),
  (select payload#>>'{items,0,id}' from search_paging_receipts where name='anonymous_second')),
  (select jsonb_agg(item->>'id' order by ordinal) from search_paging_receipts,
    jsonb_array_elements(payload->'items') with ordinality rows(item,ordinal) where name='anonymous_reference'),
  'anonymous requests preserve complete relevance order');
select pg_sleep(0.6);
insert into search_paging_receipts values('anonymous_terminal',public.catalog_search_v2('Synthetic','{}',
  (select payload->>'next_cursor' from search_paging_receipts where name='anonymous_second'),1));
select is((select payload->'items' from search_paging_receipts where name='anonymous_terminal'),'[]'::jsonb,'anonymous delayed request reaches empty terminal page');
select is((select payload->>'next_cursor' from search_paging_receipts where name='anonymous_terminal'),null,'empty terminal page has no cursor');
select is(char_length(wali.decode_catalog_cursor((select payload->>'next_cursor' from search_paging_receipts where name='anonymous_first'))->>'sort'),32,'existing scope and decoder bound remain');

-- The anchor must still exist in the same caller-visible filtered scoring set.
reset role;
update wali.wallpapers set status='removed',removed_at=statement_timestamp()
  where id=(select (payload#>>'{items,0,id}')::uuid from search_paging_receipts where name='anonymous_first');
set local role anon;
select throws_ok($$select public.catalog_search_v2('Synthetic','{}',
  (select payload->>'next_cursor' from search_paging_receipts where name='anonymous_first'),1)$$,
  'P0001','WALI_CURSOR_INVALID','removed relevance anchor requires a fresh first page');
select is(jsonb_array_length(public.catalog_search_v2('Synthetic','{}',null,50)->'items'),1,'fresh search excludes removed anchor');
reset role;
update wali.wallpapers set status='published',removed_at=null
  where id=(select (payload#>>'{items,0,id}')::uuid from search_paging_receipts where name='anonymous_first');

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
insert into search_paging_receipts values('owner_reference',public.catalog_search_v2('Synthetic','{"sort":"relevance"}',null,50));
insert into search_paging_receipts values('owner_first',public.catalog_search_v2('Synthetic','{"sort":"relevance"}',null,1));
select pg_sleep(0.6);
insert into search_paging_receipts values('owner_second',public.catalog_search_v2('Synthetic','{"sort":"relevance"}',
  (select payload->>'next_cursor' from search_paging_receipts where name='owner_first'),1));
select isnt((select payload#>>'{items,0,id}' from search_paging_receipts where name='owner_second'),
  (select payload#>>'{items,0,id}' from search_paging_receipts where name='owner_first'),'authenticated second request never repeats its decayed anchor');
select is(jsonb_build_array(
  (select payload#>>'{items,0,id}' from search_paging_receipts where name='owner_first'),
  (select payload#>>'{items,0,id}' from search_paging_receipts where name='owner_second')),
  (select jsonb_agg(item->>'id' order by ordinal) from search_paging_receipts,
    jsonb_array_elements(payload->'items') with ordinality rows(item,ordinal) where name='owner_reference'),
  'authenticated requests preserve complete relevance order');
select pg_sleep(0.6);
insert into search_paging_receipts values('owner_terminal',public.catalog_search_v2('Synthetic','{"sort":"relevance"}',
  (select payload->>'next_cursor' from search_paging_receipts where name='owner_second'),1));
select is((select payload->'items' from search_paging_receipts where name='owner_terminal'),'[]'::jsonb,'authenticated delayed request reaches empty terminal page');
select is((select payload->>'next_cursor' from search_paging_receipts where name='owner_terminal'),null,'authenticated empty terminal page has no cursor');
select lives_ok($$select public.set_creator_block_v1(
  (select (payload#>>'{items,0,creator,id}')::uuid from search_paging_receipts where name='owner_first'),
  true,0,'search_cursor_block_01')$$,'owner blocks the first page creator between requests');
select throws_ok($$select public.catalog_search_v2('Synthetic','{"sort":"relevance"}',
  (select payload->>'next_cursor' from search_paging_receipts where name='owner_first'),1)$$,
  'P0001','WALI_CURSOR_INVALID','blocked anchor uses the same generic invalid cursor result');
select is(jsonb_array_length(public.catalog_search_v2('Synthetic','{"sort":"relevance"}',null,50)->'items'),1,'fresh owner search excludes the blocked creator');
select ok(public.catalog_search_v2('Synthetic','{"sort":"relevance"}',null,50)::text not like
  '%'||(select payload#>>'{items,0,id}' from search_paging_receipts where name='owner_first')||'%',
  'anchor lookup exposes no blocked summary');

select * from finish();
rollback;
