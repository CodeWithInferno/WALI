begin;

select plan(13);

select results_eq(
  $$select queue_name::text from pgmq.list_queues()
     where queue_name like 'wali_%' order by queue_name$$,
  $$values
    ('wali_account_deletions'::text),
    ('wali_account_deletions_dlq'),
    ('wali_aggregation'),
    ('wali_aggregation_dlq'),
    ('wali_backup_verification'),
    ('wali_backup_verification_dlq'),
    ('wali_cleanup'),
    ('wali_cleanup_dlq'),
    ('wali_exports'),
    ('wali_exports_dlq'),
    ('wali_media_processing'),
    ('wali_media_processing_dlq'),
    ('wali_promotions'),
    ('wali_promotions_dlq')$$,
  'all bounded work and dead-letter queues exist'
);

select results_eq(
  $$select count(*)::bigint from wali.queue_policies where queue_name like 'wali_%'$$,
  array[7::bigint],
  'each primary queue has a retry policy'
);

select results_eq(
  $$select count(*)::bigint from cron.job where starts_with(jobname, 'wali_')$$,
  array[6::bigint],
  'six maintenance schedules are installed'
);

select has_table('wali', 'account_exports', 'account exports exist');
select has_table('wali', 'backup_verification_runs', 'backup verification records exist');
select has_table('wali', 'orphan_object_observations', 'orphan observations exist');

select results_eq(
  $$select count(*)::bigint
      from unnest(array[
        'wali.fail_queue_message(text,bigint,integer,jsonb,text)',
        'wali.recover_stale_processing_attempts(timestamptz)',
        'wali.expire_account_exports(timestamptz)',
        'wali.cleanup_expired_marketplace_objects(timestamptz)',
        'wali.observe_orphan_catalog_objects(timestamptz)',
        'wali.enqueue_backup_verification(timestamptz)'
      ]) function_signature
     where has_function_privilege('anon', function_signature, 'EXECUTE')
        or has_function_privilege('authenticated', function_signature, 'EXECUTE')$$,
  array[0::bigint],
  'Data API roles cannot execute privileged maintenance functions'
);

select lives_ok(
  $$select wali.recover_stale_processing_attempts('2026-09-03T00:00:00Z'::timestamptz)$$,
  'stale attempt recovery is idempotent'
);

select lives_ok(
  $$select wali.cleanup_expired_marketplace_objects('2026-09-03T00:00:00Z'::timestamptz)$$,
  'retention cleanup is idempotent'
);

select lives_ok(
  $$select wali.observe_orphan_catalog_objects('2026-09-03T00:00:00Z'::timestamptz)$$,
  'orphan reconciliation records observations without deleting catalog bytes'
);

select results_eq(
  $$select count(*)::bigint from storage.objects o
     join wali.artifacts a on a.storage_bucket = o.bucket_id and a.storage_path = o.name
     join wali.release_artifacts ra on ra.artifact_digest = a.digest
     join wali.wallpapers w on w.current_release_id = ra.release_id
     where o.bucket_id = 'catalog-public'$$,
  array[8::bigint],
  'cleanup preserves every current-release object'
);

select lives_ok(
  $$select wali.enqueue_backup_verification('2026-09-03T00:00:00Z'::timestamptz)$$,
  'backup verification can be queued without external credentials'
);

select results_eq(
  $$select count(*)::bigint from pgmq.q_wali_backup_verification message
     where message.message ->> 'run_id' = (
       select run.id::text from wali.backup_verification_runs run
        where run.scheduled_for = '2026-09-03T00:00:00Z'::timestamptz
     )$$,
  array[1::bigint],
  'backup verification queue receives one deterministic local job'
);

select * from finish();
rollback;
