-- WALI Marketplace foundation: durable queues, bounded retries, maintenance, and retention schedules.

create table wali.queue_policies (
  queue_name text primary key,
  max_attempts integer not null check (max_attempts between 1 and 20),
  visibility_timeout_seconds integer not null check (visibility_timeout_seconds between 10 and 3600),
  retry_delay_seconds integer not null check (retry_delay_seconds between 1 and 3600),
  message_retention interval not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint queue_policy_name check (queue_name ~ '^wali_[a-z_]{3,64}$'),
  constraint queue_policy_retention check (message_retention between interval '1 hour' and interval '30 days')
);

insert into wali.queue_policies (
  queue_name, max_attempts, visibility_timeout_seconds, retry_delay_seconds, message_retention
) values
  ('wali_media_processing', 5, 300, 60, interval '14 days'),
  ('wali_exports', 4, 180, 60, interval '7 days'),
  ('wali_aggregation', 3, 120, 30, interval '3 days'),
  ('wali_cleanup', 3, 300, 120, interval '7 days'),
  ('wali_backup_verification', 5, 600, 300, interval '30 days');

select pgmq.create('wali_media_processing');
select pgmq.create('wali_media_processing_dlq');
select pgmq.create('wali_exports');
select pgmq.create('wali_exports_dlq');
select pgmq.create('wali_aggregation');
select pgmq.create('wali_aggregation_dlq');
select pgmq.create('wali_cleanup');
select pgmq.create('wali_cleanup_dlq');
select pgmq.create('wali_backup_verification');
select pgmq.create('wali_backup_verification_dlq');

create table wali.backup_verification_runs (
  id uuid primary key default gen_random_uuid(),
  scheduled_for timestamptz not null unique,
  status text not null default 'queued',
  checked_object_count bigint check (checked_object_count >= 0),
  mismatch_count bigint check (mismatch_count >= 0),
  report_digest text,
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  constraint backup_status check (status in ('queued', 'running', 'passed', 'failed')),
  constraint backup_report_digest check (report_digest is null or report_digest ~ '^[0-9a-f]{64}$'),
  constraint backup_terminal_time check (status not in ('passed', 'failed') or finished_at is not null)
);

create table wali.orphan_object_observations (
  bucket_id text not null,
  storage_path text not null,
  first_seen_at timestamptz not null,
  last_seen_at timestamptz not null,
  observation_count bigint not null default 1 check (observation_count > 0),
  resolved_at timestamptz,
  primary key (bucket_id, storage_path),
  constraint orphan_observation_window check (last_seen_at >= first_seen_at)
);

alter table wali.queue_policies enable row level security;
alter table wali.backup_verification_runs enable row level security;
alter table wali.orphan_object_observations enable row level security;
grant all on wali.queue_policies, wali.backup_verification_runs, wali.orphan_object_observations to service_role;

create or replace function wali.fail_queue_message(
  target_queue text,
  message_id bigint,
  current_read_count integer,
  message_payload jsonb,
  safe_error_code text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  policy wali.queue_policies%rowtype;
begin
  select * into policy from wali.queue_policies where queue_name = target_queue;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_QUEUE_NOT_ALLOWED'; end if;
  if safe_error_code !~ '^WALI_[A-Z0-9_]{2,96}$'
     or jsonb_typeof(message_payload) <> 'object'
     or octet_length(message_payload::text) > 65536 then
    raise exception using errcode = 'P0001', message = 'WALI_QUEUE_FAILURE_INVALID';
  end if;

  if current_read_count >= policy.max_attempts then
    perform pgmq.send(
      target_queue || '_dlq',
      jsonb_build_object(
        'original_message_id', message_id,
        'read_count', current_read_count,
        'safe_error_code', safe_error_code,
        'payload', message_payload,
        'failed_at', statement_timestamp()
      )
    );
    perform pgmq.delete(target_queue, message_id);
    return 'dead_lettered';
  end if;

  perform pgmq.set_vt(target_queue, message_id, policy.retry_delay_seconds);
  return 'retry_scheduled';
end
$$;

create or replace function wali.recover_stale_processing_attempts(effective_clock timestamptz)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare affected bigint;
begin
  with stale as (
    update wali.processing_attempts pa
       set status = 'timed_out', lease_owner = null, lease_expires_at = null,
           safe_error_code = 'WALI_PROCESSING_LEASE_EXPIRED', finished_at = effective_clock
     where pa.status in ('leased', 'downloading', 'transcoding', 'verifying', 'classifying')
       and pa.lease_expires_at < effective_clock
    returning pa.submission_id, pa.generation
  )
  update wali.submissions s
     set status = 'processing_failed', last_safe_error_code = 'WALI_PROCESSING_LEASE_EXPIRED'
    from stale
   where s.id = stale.submission_id and s.generation = stale.generation and s.status = 'processing';
  get diagnostics affected = row_count;
  return affected;
end
$$;

create or replace function wali.expire_account_exports(effective_clock timestamptz)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare affected bigint;
begin
  perform pgmq.send('wali_cleanup', jsonb_build_object(
    'schema_version', 1, 'operation', 'delete_object',
    'bucket_id', 'exports-private', 'storage_path', e.storage_path
  ))
  from wali.account_exports e
  where e.expires_at <= effective_clock and e.status <> 'expired'
    and exists (select 1 from storage.objects o where o.bucket_id = 'exports-private' and o.name = e.storage_path);

  update wali.account_exports set status = 'expired'
   where expires_at <= effective_clock and status <> 'expired';
  get diagnostics affected = row_count;
  return affected;
end
$$;

create or replace function wali.cleanup_expired_marketplace_objects(effective_clock timestamptz)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare removed bigint;
begin
  perform pgmq.send('wali_cleanup', jsonb_build_object(
    'schema_version', 1, 'operation', 'delete_object',
    'bucket_id', 'uploads-private', 'storage_path', us.storage_path
  ))
  from wali.upload_sessions us
   where us.status in ('issued', 'uploading', 'completed')
     and (
       (us.status in ('issued', 'uploading') and us.expires_at <= effective_clock)
       or (us.status = 'completed' and us.updated_at <= effective_clock - interval '30 days')
     )
     and exists (select 1 from storage.objects o where o.bucket_id = 'uploads-private' and o.name = us.storage_path)
     and not exists (
       select 1 from wali.submissions s
       join wali.processing_attempts pa on pa.submission_id = s.id and pa.generation = s.generation
       where s.upload_session_id = us.id
         and pa.status in ('queued', 'leased', 'downloading', 'transcoding', 'verifying', 'classifying')
     )
     and not exists (
       select 1 from wali.submissions s
       join wali.copyright_cases cc on cc.target_wallpaper_id = s.wallpaper_id
       where s.upload_session_id = us.id and cc.status in ('open', 'triaged', 'appealed')
     );
  get diagnostics removed = row_count;

  update wali.upload_sessions set status = 'expired'
   where status in ('issued', 'uploading') and expires_at <= effective_clock;

  perform wali.expire_account_exports(effective_clock);
  return removed;
end
$$;

create or replace function wali.observe_orphan_catalog_objects(effective_clock timestamptz)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare observed bigint;
begin
  insert into wali.orphan_object_observations (
    bucket_id, storage_path, first_seen_at, last_seen_at, observation_count
  )
  select o.bucket_id, o.name, effective_clock, effective_clock, 1
    from storage.objects o
   where o.bucket_id = 'catalog-public'
     and not exists (
       select 1 from wali.artifacts a
        where a.storage_bucket = o.bucket_id and a.storage_path = o.name
     )
  on conflict (bucket_id, storage_path) do update set
    last_seen_at = excluded.last_seen_at,
    observation_count = wali.orphan_object_observations.observation_count + 1,
    resolved_at = null;
  get diagnostics observed = row_count;

  update wali.orphan_object_observations obs set resolved_at = effective_clock
   where resolved_at is null and not exists (
     select 1 from storage.objects o where o.bucket_id = obs.bucket_id and o.name = obs.storage_path
   );
  return observed;
end
$$;

create or replace function wali.enqueue_backup_verification(effective_clock timestamptz)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare run_id uuid;
begin
  insert into wali.backup_verification_runs (scheduled_for)
  values (date_trunc('hour', effective_clock))
  on conflict (scheduled_for) do nothing
  returning id into run_id;
  if run_id is not null then
    perform pgmq.send('wali_backup_verification', jsonb_build_object(
      'schema_version', 1,
      'run_id', run_id,
      'scheduled_for', date_trunc('hour', effective_clock)
    ));
  else
    select id into run_id from wali.backup_verification_runs
     where scheduled_for = date_trunc('hour', effective_clock);
  end if;
  return run_id;
end
$$;

select cron.schedule(
  'wali_stats_ranking_hourly', '7 * * * *',
  $$select wali.refresh_marketplace_aggregates(statement_timestamp())$$
);
select cron.schedule(
  'wali_stale_leases_every_five_minutes', '*/5 * * * *',
  $$select wali.recover_stale_processing_attempts(statement_timestamp())$$
);
select cron.schedule(
  'wali_abandoned_upload_cleanup_daily', '19 2 * * *',
  $$select wali.cleanup_expired_marketplace_objects(statement_timestamp())$$
);
select cron.schedule(
  'wali_export_expiry_hourly', '37 * * * *',
  $$select wali.expire_account_exports(statement_timestamp())$$
);
select cron.schedule(
  'wali_orphan_observation_daily', '41 2 * * *',
  $$select wali.observe_orphan_catalog_objects(statement_timestamp())$$
);
select cron.schedule(
  'wali_backup_verification_daily', '13 3 * * *',
  $$select wali.enqueue_backup_verification(statement_timestamp())$$
);

-- Functions are executable by PUBLIC when created unless that default is
-- explicitly removed. These maintenance commands bypass RLS by design for
-- pg_cron and the media worker, so never leave them callable through the Data
-- API roles.
revoke all on function wali.fail_queue_message(text, bigint, integer, jsonb, text) from public, anon, authenticated;
revoke all on function wali.recover_stale_processing_attempts(timestamptz) from public, anon, authenticated;
revoke all on function wali.expire_account_exports(timestamptz) from public, anon, authenticated;
revoke all on function wali.cleanup_expired_marketplace_objects(timestamptz) from public, anon, authenticated;
revoke all on function wali.observe_orphan_catalog_objects(timestamptz) from public, anon, authenticated;
revoke all on function wali.enqueue_backup_verification(timestamptz) from public, anon, authenticated;

grant execute on function wali.fail_queue_message(text, bigint, integer, jsonb, text) to service_role;
grant execute on function wali.recover_stale_processing_attempts(timestamptz) to service_role;
grant execute on function wali.expire_account_exports(timestamptz) to service_role;
grant execute on function wali.cleanup_expired_marketplace_objects(timestamptz) to service_role;
grant execute on function wali.observe_orphan_catalog_objects(timestamptz) to service_role;
grant execute on function wali.enqueue_backup_verification(timestamptz) to service_role;
