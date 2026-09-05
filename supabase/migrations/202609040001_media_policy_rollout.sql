-- Align newly issued jobs with the reviewed Main 10 media policy already used
-- by the worker image. Deploy the matching worker/image before this migration.
-- Existing queue messages retain their frozen policy and must never be rewritten.
update wali.runtime_configuration
set media_policy_digest = '9710d4e665b29989a0c6109c1f807ae5fb52ef009536194663b365ae06e28875',
    updated_at = statement_timestamp()
where singleton
  and media_policy_digest = 'eecd4f6911a2392b5286cd0c9ef09e78e5cc5c756ad39bca042832d70f48598e';
