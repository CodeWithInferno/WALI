begin;

select plan(29);

select has_view('public', 'catalog_home_v1', 'public home projection exists');
select has_view('public', 'catalog_wallpapers_v1', 'public catalog view exists');
select has_view('public', 'catalog_wallpaper_details_v1', 'public detail view exists');
select has_view('public', 'catalog_creators_v1', 'public creator view exists');
select has_view('public', 'catalog_categories_v1', 'public category view exists');
select has_view('public', 'catalog_tags_v1', 'public tag view exists');
select has_view('public', 'catalog_collections_v1', 'public collection view exists');
select has_view('public', 'my_profile_v1', 'self profile view exists');
select has_view('public', 'my_creator_submissions_v1', 'self submission view exists');
select has_view('public', 'my_favorites_v1', 'self favorites view exists');
select has_view('public', 'my_saved_wallpapers_v1', 'self saved view exists');

select results_eq(
  $$select count(*)::bigint
      from information_schema.columns
     where table_schema = 'public'
       and table_name like 'catalog_%_v1'
       and column_name in (
         'original_filename', 'proof_storage_path', 'private_note', 'claimant_email',
         'lease_owner', 'lease_expires_at', 'raw_result'
       )$$,
  array[0::bigint],
  'public catalog views expose no private workflow fields'
);

select ok(
  exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'catalog_wallpapers_v1' and column_name = 'revision'
  ) and exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'catalog_wallpaper_details_v1'
       and column_name in ('favorite_revision', 'saved_revision')
    group by table_schema, table_name having count(*) = 2
  ),
  'catalog outputs expose install and viewer interaction revisions'
);

select has_function(
  'public', 'catalog_creator_v1', array['text', 'text', 'integer'],
  'bounded creator RPC exists'
);
select has_function(
  'public', 'my_favorites_v1', array['text', 'integer'],
  'bounded favorites RPC exists'
);
select has_function(
  'public', 'my_saved_wallpapers_v1', array['text', 'integer'],
  'bounded saved-wallpapers RPC exists'
);
select has_function(
  'public', 'set_favorite_v1', array['uuid', 'boolean', 'bigint', 'text'],
  'favorite mutation accepts a bounded text idempotency key'
);
select has_function(
  'public', 'set_saved_v1', array['uuid', 'boolean', 'bigint', 'text'],
  'saved mutation accepts a bounded text idempotency key'
);
select has_function(
  'public', 'request_install_v1', array['uuid', 'uuid', 'bigint', 'text'],
  'install request binds wallpaper, release, logical revision, and idempotency key'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;

select throws_ok(
  $$select public.request_install_v1(
    '30000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000001',
    (select revision from public.catalog_wallpapers_v1
      where id = '30000000-0000-0000-0000-000000000001'),
    'install_request_0000000000000001'
  )$$,
  '42501', 'permission denied for function request_install_v1',
  'install grant issuance is available only through the bounded Edge command'
);

select is(
  (public.set_favorite_v1(
    '30000000-0000-0000-0000-000000000001', true, 0,
    'favorite_command_0000000000001'
  ) ->> 'revision')::bigint,
  1::bigint,
  'first favorite transition starts its monotonic revision at one'
);
select is(
  (public.set_favorite_v1(
    '30000000-0000-0000-0000-000000000001', false, 1,
    'favorite_command_0000000000002'
  ) ->> 'revision')::bigint,
  2::bigint,
  'favorite removal retains a false tombstone and increments revision'
);
select is(
  (public.set_favorite_v1(
    '30000000-0000-0000-0000-000000000001', true, 2,
    'favorite_command_0000000000003'
  ) ->> 'revision')::bigint,
  3::bigint,
  'favorite reactivation cannot reuse never-seen revision zero'
);

reset role;

set local role anon;
select ok(
  jsonb_array_length(public.catalog_home_v1('en', 'mature') -> 'sections') between 1 and 8,
  'home RPC returns a bounded sections envelope'
);
select is(
  public.catalog_wallpaper_detail_v1('30000000-0000-0000-0000-000000000001')
    -> 'wallpaper' ->> 'id',
  '30000000-0000-0000-0000-000000000001',
  'detail RPC returns the canonical nested wallpaper shape'
);
select is(
  public.catalog_creator_v1('synthetic_studio', null, 24) -> 'creator' ->> 'handle',
  'synthetic_studio',
  'creator RPC accepts the canonical underscore handle format'
);
select results_eq(
  $$select count(*)::bigint from public.catalog_wallpapers_v1 c
      join wali.wallpapers w on w.id = c.id where w.status <> 'published'$$,
  array[0::bigint],
  'anonymous catalog contains only published wallpapers'
);
select results_eq(
  $$select count(*)::bigint from public.catalog_wallpapers_v1 c
      join wali.wallpapers w on w.id = c.id where w.visibility <> 'public'$$,
  array[0::bigint],
  'anonymous browse contains only public visibility'
);
select ok(
  has_table_privilege('anon', 'public.catalog_wallpapers_v1', 'SELECT'),
  'anonymous role can read only the safe catalog view'
);

select * from finish();
rollback;
