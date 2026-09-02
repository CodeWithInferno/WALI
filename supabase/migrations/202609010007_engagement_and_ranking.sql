-- WALI Marketplace foundation: privacy-bounded engagement, aggregation, quality, and deterministic ranking.

create table wali.favorites (
  user_id uuid not null references wali.profiles(id) on delete cascade,
  wallpaper_id uuid not null references wali.wallpapers(id) on delete cascade,
  active boolean not null default true,
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  primary key (user_id, wallpaper_id)
);

create table wali.saved_wallpapers (
  user_id uuid not null references wali.profiles(id) on delete cascade,
  wallpaper_id uuid not null references wali.wallpapers(id) on delete cascade,
  active boolean not null default true,
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  primary key (user_id, wallpaper_id)
);

create table wali.creator_follows (
  user_id uuid not null references wali.profiles(id) on delete cascade,
  creator_id uuid not null references wali.profiles(id) on delete cascade,
  active boolean not null default true,
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  primary key (user_id, creator_id),
  constraint creator_follows_not_self check (user_id <> creator_id)
);

create table wali.install_receipts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references wali.profiles(id) on delete cascade,
  release_id uuid not null references wali.wallpaper_releases(id) on delete restrict,
  request_id uuid not null,
  issued_at timestamptz not null default statement_timestamp(),
  expires_at timestamptz not null default statement_timestamp() + interval '30 minutes',
  consumed_at timestamptz,
  unique (user_id, request_id),
  constraint install_receipts_expiry check (
    expires_at > issued_at and expires_at <= issued_at + interval '30 minutes'
  )
);

create table wali.engagement_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references wali.profiles(id) on delete set null,
  wallpaper_id uuid not null references wali.wallpapers(id) on delete restrict,
  release_id uuid references wali.wallpaper_releases(id) on delete restrict,
  kind wali.event_kind not null,
  occurred_at timestamptz not null default statement_timestamp(),
  ranking_day date not null default (timezone('UTC', statement_timestamp()))::date,
  client_request_id uuid not null,
  install_receipt_id uuid references wali.install_receipts(id) on delete restrict,
  coarse_source text not null,
  contributes_to_ranking boolean not null default false,
  exclusion_reason text,
  created_at timestamptz not null default statement_timestamp(),
  unique (user_id, client_request_id),
  constraint engagement_source check (coarse_source in ('macos', 'creator_studio', 'moderation', 'system')),
  constraint engagement_exclusion_reason check (
    exclusion_reason is null or exclusion_reason ~ '^[a-z][a-z0-9_.-]{2,95}$'
  ),
  constraint engagement_eligibility_reason check (contributes_to_ranking = (exclusion_reason is null)),
  constraint engagement_install_receipt_kind check (
    install_receipt_id is null or kind = 'install_succeeded'
  )
);

create unique index engagement_install_receipt_once
  on wali.engagement_events (install_receipt_id)
  where install_receipt_id is not null;
create unique index engagement_one_ranking_contribution_per_day
  on wali.engagement_events (user_id, release_id, kind, ranking_day)
  where contributes_to_ranking and user_id is not null and release_id is not null;
create index engagement_events_time_idx on wali.engagement_events (occurred_at, id);
create index engagement_events_wallpaper_time_idx on wali.engagement_events (wallpaper_id, occurred_at, id);

create table wali.wallpaper_stats_hourly (
  wallpaper_id uuid not null references wali.wallpapers(id) on delete cascade,
  bucket_start timestamptz not null,
  unique_installers bigint not null default 0 check (unique_installers >= 0),
  install_successes bigint not null default 0 check (install_successes >= 0),
  favorites bigint not null default 0 check (favorites >= 0),
  saves bigint not null default 0 check (saves >= 0),
  detail_views bigint not null default 0 check (detail_views >= 0),
  reports bigint not null default 0 check (reports >= 0),
  computed_at timestamptz not null default statement_timestamp(),
  primary key (wallpaper_id, bucket_start),
  constraint stats_hourly_bucket check (bucket_start = date_trunc('hour', bucket_start))
);

create table wali.wallpaper_stats_daily (
  wallpaper_id uuid not null references wali.wallpapers(id) on delete cascade,
  bucket_date date not null,
  unique_installers bigint not null default 0 check (unique_installers >= 0),
  install_successes bigint not null default 0 check (install_successes >= 0),
  favorites bigint not null default 0 check (favorites >= 0),
  saves bigint not null default 0 check (saves >= 0),
  detail_views bigint not null default 0 check (detail_views >= 0),
  reports bigint not null default 0 check (reports >= 0),
  computed_at timestamptz not null default statement_timestamp(),
  primary key (wallpaper_id, bucket_date)
);

create table wali.quality_assessments (
  id uuid primary key default gen_random_uuid(),
  release_id uuid not null references wali.wallpaper_releases(id) on delete restrict,
  formula_version text not null,
  technical_completeness numeric(6,5) not null check (technical_completeness between 0 and 1),
  variant_coverage numeric(6,5) not null check (variant_coverage between 0 and 1),
  attribution_completeness numeric(6,5) not null check (attribution_completeness between 0 and 1),
  editorial_assessment numeric(6,5) not null check (editorial_assessment between 0 and 1),
  report_health numeric(6,5) not null check (report_health between 0 and 1),
  total_score numeric(6,5) generated always as (
    round((technical_completeness * 0.30 + variant_coverage * 0.20 +
      attribution_completeness * 0.20 + editorial_assessment * 0.20 + report_health * 0.10)::numeric, 5)
  ) stored,
  input_snapshot_digest text not null,
  assessed_at timestamptz not null default statement_timestamp(),
  unique (release_id, formula_version),
  constraint quality_formula_version check (formula_version ~ '^quality-v[0-9]+$'),
  constraint quality_input_digest check (input_snapshot_digest ~ '^[0-9a-f]{64}$')
);

create table wali.ranking_snapshots (
  surface text not null,
  segment text not null default '',
  formula_version text not null,
  wallpaper_id uuid not null references wali.wallpapers(id) on delete cascade,
  score numeric(18,8) not null,
  ordinal integer not null check (ordinal > 0),
  feature_inputs jsonb not null,
  generated_at timestamptz not null,
  expires_at timestamptz not null,
  primary key (surface, segment, formula_version, generated_at, wallpaper_id),
  unique (surface, segment, formula_version, generated_at, ordinal),
  constraint ranking_surface check (surface in ('trending', 'new', 'related', 'discover', 'for_you')),
  constraint ranking_formula check (formula_version ~ '^[a-z_]+-v[0-9]+$'),
  constraint ranking_feature_inputs check (
    jsonb_typeof(feature_inputs) = 'object' and octet_length(feature_inputs::text) <= 16384
  ),
  constraint ranking_expiry check (expires_at > generated_at)
);

create index ranking_surface_current_idx
  on wali.ranking_snapshots (surface, segment, formula_version, generated_at desc, ordinal);

create table wali.user_interest_profiles (
  user_id uuid not null references wali.profiles(id) on delete cascade,
  model_id text not null,
  model_revision text not null,
  preference_vector extensions.vector(768) not null,
  interaction_cutoff timestamptz not null,
  generated_at timestamptz not null default statement_timestamp(),
  expires_at timestamptz not null,
  primary key (user_id, model_id, model_revision),
  foreign key (model_id, model_revision) references wali.model_registry(model_id, model_revision) on delete restrict,
  constraint interest_profile_dimension check (extensions.vector_dims(preference_vector) = 768),
  constraint interest_profile_expiry check (expires_at > generated_at)
);

create table wali.rate_limit_buckets (
  subject_hash text not null,
  operation text not null,
  window_start timestamptz not null,
  window_seconds integer not null check (window_seconds between 1 and 86400),
  counter integer not null check (counter >= 0),
  expires_at timestamptz not null,
  updated_at timestamptz not null default statement_timestamp(),
  primary key (subject_hash, operation, window_start),
  constraint rate_limit_subject_hash check (subject_hash ~ '^[0-9a-f]{64}$'),
  constraint rate_limit_operation check (operation ~ '^[a-z][a-z0-9_.]{2,95}$'),
  constraint rate_limit_window check (expires_at > window_start)
);

create index rate_limit_expiry_idx on wali.rate_limit_buckets (expires_at);

create or replace function wali.classify_engagement_eligibility()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  creator uuid;
  user_status wali.account_status;
begin
  new.ranking_day := (timezone('UTC', new.occurred_at))::date;
  new.contributes_to_ranking := new.kind in ('install_succeeded', 'favorite_added', 'saved');
  new.exclusion_reason := null;

  if new.user_id is null then
    new.contributes_to_ranking := false;
    new.exclusion_reason := 'unauthenticated';
    return new;
  end if;

  select status into user_status from wali.profiles where id = new.user_id;
  select creator_id into creator from wali.wallpapers where id = new.wallpaper_id;
  if user_status is distinct from 'active'::wali.account_status then
    new.contributes_to_ranking := false;
    new.exclusion_reason := 'inactive_account';
  elsif creator = new.user_id then
    new.contributes_to_ranking := false;
    new.exclusion_reason := 'creator_self_interaction';
  elsif new.occurred_at < statement_timestamp() - interval '90 days'
     or new.occurred_at > statement_timestamp() + interval '5 minutes' then
    new.contributes_to_ranking := false;
    new.exclusion_reason := 'event_time_out_of_bounds';
  elsif new.contributes_to_ranking and exists (
    select 1 from wali.engagement_events prior
    where prior.user_id = new.user_id
      and prior.release_id = new.release_id
      and prior.kind = new.kind
      and prior.ranking_day = new.ranking_day
      and prior.contributes_to_ranking
  ) then
    new.contributes_to_ranking := false;
    new.exclusion_reason := 'duplicate_daily_contribution';
  elsif not new.contributes_to_ranking then
    new.exclusion_reason := 'non_ranking_event';
  end if;
  return new;
end
$$;

create or replace function wali.take_interaction_quota(actor_id uuid, operation_name text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare bucket_start timestamptz := date_trunc('minute', statement_timestamp()); current_count integer;
begin
  if operation_name not in ('set_favorite', 'set_saved', 'set_creator_follow') then return false; end if;
  insert into wali.rate_limit_buckets (subject_hash, operation, window_start, window_seconds, counter, expires_at)
  values (encode(extensions.digest(actor_id::text, 'sha256'), 'hex'), operation_name,
    bucket_start, 60, 1, bucket_start + interval '2 minutes')
  on conflict (subject_hash, operation, window_start) do update set
    counter = wali.rate_limit_buckets.counter + 1, updated_at = statement_timestamp()
  returning counter into current_count;
  return current_count <= 120;
end $$;

create trigger engagement_events_classify before insert on wali.engagement_events
for each row execute function wali.classify_engagement_eligibility();
create trigger engagement_events_append_only before update or delete on wali.engagement_events
for each row execute function wali.reject_append_only_mutation();
create trigger quality_assessments_append_only before update or delete on wali.quality_assessments
for each row execute function wali.reject_append_only_mutation();

create or replace function wali.refresh_marketplace_aggregates(effective_clock timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  hourly_bucket timestamptz := date_trunc('hour', effective_clock - interval '1 hour');
  daily_bucket date := (timezone('UTC', effective_clock - interval '1 day'))::date;
begin
  insert into wali.wallpaper_stats_hourly (
    wallpaper_id, bucket_start, unique_installers, install_successes,
    favorites, saves, detail_views, reports, computed_at
  )
  select w.id, hourly_bucket,
    count(distinct e.user_id) filter (where e.kind = 'install_succeeded' and e.contributes_to_ranking),
    count(*) filter (where e.kind = 'install_succeeded' and e.contributes_to_ranking),
    count(*) filter (where e.kind = 'favorite_added' and e.contributes_to_ranking),
    count(*) filter (where e.kind = 'saved' and e.contributes_to_ranking),
    count(*) filter (where e.kind = 'detail_view'),
    count(*) filter (where e.kind = 'report_submitted'),
    effective_clock
  from wali.wallpapers w
  left join wali.engagement_events e on e.wallpaper_id = w.id
    and e.occurred_at >= hourly_bucket and e.occurred_at < hourly_bucket + interval '1 hour'
  group by w.id
  on conflict (wallpaper_id, bucket_start) do update set
    unique_installers = excluded.unique_installers,
    install_successes = excluded.install_successes,
    favorites = excluded.favorites,
    saves = excluded.saves,
    detail_views = excluded.detail_views,
    reports = excluded.reports,
    computed_at = excluded.computed_at;

  insert into wali.wallpaper_stats_daily (
    wallpaper_id, bucket_date, unique_installers, install_successes,
    favorites, saves, detail_views, reports, computed_at
  )
  select w.id, daily_bucket,
    count(distinct e.user_id) filter (where e.kind = 'install_succeeded' and e.contributes_to_ranking),
    count(*) filter (where e.kind = 'install_succeeded' and e.contributes_to_ranking),
    count(*) filter (where e.kind = 'favorite_added' and e.contributes_to_ranking),
    count(*) filter (where e.kind = 'saved' and e.contributes_to_ranking),
    count(*) filter (where e.kind = 'detail_view'),
    count(*) filter (where e.kind = 'report_submitted'),
    effective_clock
  from wali.wallpapers w
  left join wali.engagement_events e on e.wallpaper_id = w.id
    and (timezone('UTC', e.occurred_at))::date = daily_bucket
  group by w.id
  on conflict (wallpaper_id, bucket_date) do update set
    unique_installers = excluded.unique_installers,
    install_successes = excluded.install_successes,
    favorites = excluded.favorites,
    saves = excluded.saves,
    detail_views = excluded.detail_views,
    reports = excluded.reports,
    computed_at = excluded.computed_at;

  delete from wali.ranking_snapshots
   where surface = 'trending' and formula_version = 'trending-v1' and generated_at = effective_clock;

  insert into wali.ranking_snapshots (
    surface, segment, formula_version, wallpaper_id, score, ordinal,
    feature_inputs, generated_at, expires_at
  )
  with event_features as (
    select w.id as wallpaper_id,
      count(distinct e.user_id) filter (
        where e.kind = 'install_succeeded' and e.contributes_to_ranking
      ) as unique_installers,
      coalesce(sum(power(0.5, extract(epoch from (effective_clock - e.occurred_at)) / 129600.0)) filter (
        where e.kind = 'install_succeeded' and e.contributes_to_ranking
      ), 0) as install_weight,
      coalesce(sum(power(0.5, extract(epoch from (effective_clock - e.occurred_at)) / 129600.0)) filter (
        where e.kind = 'saved' and e.contributes_to_ranking
      ), 0) as save_weight,
      coalesce(sum(power(0.5, extract(epoch from (effective_clock - e.occurred_at)) / 129600.0)) filter (
        where e.kind = 'favorite_added' and e.contributes_to_ranking
      ), 0) as favorite_weight,
      count(*) filter (where e.kind = 'report_submitted' and e.occurred_at >= effective_clock - interval '30 days') as reports
    from wali.wallpapers w
    left join wali.engagement_events e on e.wallpaper_id = w.id
      and e.occurred_at >= effective_clock - interval '30 days' and e.occurred_at <= effective_clock
    where w.status = 'published' and w.visibility = 'public'
    group by w.id
  ), scored as (
    select w.id as wallpaper_id,
      round((
        0.45 * ln(1 + case when ef.unique_installers >= 2 then ef.install_weight else 0 end) +
        0.25 * ln(1 + ef.save_weight) +
        0.10 * ln(1 + ef.favorite_weight) +
        0.10 * coalesce(qa.total_score, 0.5) +
        0.10 * greatest(0, 1 - extract(epoch from (effective_clock - w.published_at)) / 2592000.0) -
        least(0.50, ef.reports * 0.05)
      )::numeric, 8) as score,
      jsonb_build_object(
        'unique_installers', ef.unique_installers,
        'install_weight', round(ef.install_weight::numeric, 8),
        'save_weight', round(ef.save_weight::numeric, 8),
        'favorite_weight', round(ef.favorite_weight::numeric, 8),
        'quality', coalesce(qa.total_score, 0.5),
        'reports', ef.reports,
        'half_life_hours', 36
      ) as inputs
    from wali.wallpapers w
    join event_features ef on ef.wallpaper_id = w.id
    left join lateral (
      select q.total_score from wali.quality_assessments q
       where q.release_id = w.current_release_id and q.formula_version = 'quality-v1'
       order by q.assessed_at desc limit 1
    ) qa on true
  ), ordered as (
    select *, row_number() over (order by score desc, wallpaper_id) as position from scored
  )
  select 'trending', '', 'trending-v1', wallpaper_id, score, position,
    inputs, effective_clock, effective_clock + interval '2 hours'
  from ordered;
end
$$;

alter table wali.favorites enable row level security;
alter table wali.saved_wallpapers enable row level security;
alter table wali.creator_follows enable row level security;
alter table wali.install_receipts enable row level security;
alter table wali.engagement_events enable row level security;
alter table wali.wallpaper_stats_hourly enable row level security;
alter table wali.wallpaper_stats_daily enable row level security;
alter table wali.quality_assessments enable row level security;
alter table wali.ranking_snapshots enable row level security;
alter table wali.user_interest_profiles enable row level security;
alter table wali.rate_limit_buckets enable row level security;

create policy favorites_owner_all on wali.favorites for all to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy saved_owner_all on wali.saved_wallpapers for all to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy follows_owner_all on wali.creator_follows for all to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy receipts_owner_read on wali.install_receipts for select to authenticated using (user_id = auth.uid());
create policy stats_hourly_public_read on wali.wallpaper_stats_hourly for select to anon, authenticated using (true);
create policy stats_daily_public_read on wali.wallpaper_stats_daily for select to anon, authenticated using (true);
create policy quality_public_read on wali.quality_assessments for select to anon, authenticated using (true);
create policy ranking_public_read on wali.ranking_snapshots for select to anon, authenticated
using (expires_at > statement_timestamp());
create policy interest_owner_read on wali.user_interest_profiles for select to authenticated using (user_id = auth.uid());

grant select on wali.favorites, wali.saved_wallpapers, wali.creator_follows to authenticated;
grant select on wali.install_receipts to authenticated;
grant select on wali.wallpaper_stats_hourly, wali.wallpaper_stats_daily,
  wali.quality_assessments, wali.ranking_snapshots to anon, authenticated;
grant select on wali.user_interest_profiles to authenticated;

grant all on wali.favorites, wali.saved_wallpapers, wali.creator_follows,
  wali.install_receipts, wali.engagement_events, wali.wallpaper_stats_hourly,
  wali.wallpaper_stats_daily, wali.quality_assessments, wali.ranking_snapshots,
  wali.user_interest_profiles, wali.rate_limit_buckets to service_role;
grant execute on function wali.refresh_marketplace_aggregates(timestamptz) to service_role;

revoke all on function wali.classify_engagement_eligibility() from public, anon, authenticated;
revoke all on function wali.refresh_marketplace_aggregates(timestamptz) from public, anon, authenticated;
revoke all on function wali.take_interaction_quota(uuid, text) from public, anon, authenticated;
