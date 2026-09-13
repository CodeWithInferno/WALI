-- Synthetic local accounts only. No fixture state or configuration survives.
begin;
select plan(13);

update wali.runtime_configuration set still_uploads_enabled=false, still_policy_digest=null where singleton;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000003","aal":"aal1"}',true);
set local role authenticated;

select is(public.creator_metadata_v1()->'supported_upload_media_types',
  '["video/mp4","video/quicktime"]'::jsonb,
  'disabled still intake advertises only supported video containers to an ordinary AAL1 account');
select is((select array_agg(key order by key) from jsonb_object_keys(public.creator_metadata_v1()) key),
  array['categories','current_creator_terms_version','licenses','rights_bases','supported_upload_media_types','tags'],
  'only the additive format-capability member joins the existing metadata shape');
do $$ begin
  perform set_config('wali_test.metadata_without_capability',(public.creator_metadata_v1()-'supported_upload_media_types')::text,true);
end $$;
reset role;
select ok(has_function_privilege('authenticated','public.creator_metadata_v1()','EXECUTE'),
  'existing authenticated metadata access remains');
select ok(not has_function_privilege('anon','public.creator_metadata_v1()','EXECUTE'),
  'format advertisement grants no anonymous metadata access');
select ok(not has_function_privilege('wali_worker','public.creator_metadata_v1()','EXECUTE'),
  'format advertisement grants no worker metadata access');

update wali.runtime_configuration set still_policy_digest=repeat('a',64), still_uploads_enabled=true where singleton;
set local role authenticated;
select is(public.creator_metadata_v1()->'supported_upload_media_types',
  '["video/mp4","video/quicktime","image/jpeg","image/png"]'::jsonb,
  'enabled still intake advertises exactly the four supported containers');
select is(public.creator_metadata_v1()-'supported_upload_media_types',
  current_setting('wali_test.metadata_without_capability')::jsonb,
  'enabling images changes no taxonomy, license, rights or terms metadata');
reset role;
update wali.runtime_configuration set still_uploads_enabled=false where singleton;
set local role authenticated;
select is(public.creator_metadata_v1()->'supported_upload_media_types',
  '["video/mp4","video/quicktime"]'::jsonb,
  'rollback is visible immediately without a cached positive image capability');
reset role;

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',true);
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000005","aal":"aal1"}',true);
set local role authenticated;
select throws_ok($$select public.creator_metadata_v1()$$,'P0001','WALI_ACCOUNT_INACTIVE',
  'suspended account still cannot read Creator metadata');
reset role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000099',true);
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000099","aal":"aal1"}',true);
set local role authenticated;
select throws_ok($$select public.creator_metadata_v1()$$,'P0001','WALI_ACCOUNT_INACTIVE',
  'unknown account cannot use the format capability');
reset role;
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claims','{"role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select public.creator_metadata_v1()$$,'P0001','WALI_ACCOUNT_INACTIVE',
  'missing actual subject remains rejected');
reset role;

update wali.runtime_configuration set still_policy_digest=repeat('a',64), still_uploads_enabled=true where singleton;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
select set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000002","aal":"aal1"}',true);
set local role authenticated;
select is(public.creator_metadata_v1()->'supported_upload_media_types',
  '["video/mp4","video/quicktime","image/jpeg","image/png"]'::jsonb,
  'a different active subject receives the current server capability');
select is(public.creator_metadata_v1()-'supported_upload_media_types',
  current_setting('wali_test.metadata_without_capability')::jsonb,
  'switching subjects leaves the existing public metadata projection unchanged');
reset role;
select * from finish();
rollback;
