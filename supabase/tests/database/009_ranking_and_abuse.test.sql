begin;

select plan(11);

select has_table('wali', 'engagement_events', 'engagement events exist');
select has_table('wali', 'wallpaper_stats_hourly', 'hourly stats exist');
select has_table('wali', 'wallpaper_stats_daily', 'daily stats exist');
select has_table('wali', 'ranking_snapshots', 'ranking snapshots exist');
select has_table('wali', 'quality_assessments', 'quality assessments exist');
select has_table('wali', 'user_interest_profiles', 'interest profiles exist');
select has_table('wali', 'rate_limit_buckets', 'rate limit buckets exist');

insert into wali.engagement_events (
  id, user_id, wallpaper_id, release_id, kind, occurred_at, client_request_id,
  coarse_source, contributes_to_ranking
) values (
  '50000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  '30000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  'install_succeeded', '2026-09-01T12:00:00Z',
  '50000000-0000-0000-0000-000000000011', 'macos', true
);

select results_eq(
  $$select contributes_to_ranking, exclusion_reason
      from wali.engagement_events
     where id = '50000000-0000-0000-0000-000000000001'$$,
  $$values (false, 'creator_self_interaction'::text)$$,
  'creator self-interaction is excluded even when caller requests eligibility'
);

insert into wali.engagement_events (
  id, user_id, wallpaper_id, release_id, kind, occurred_at, client_request_id,
  coarse_source, contributes_to_ranking
) values (
  '50000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000003',
  '30000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  'install_succeeded', '2026-09-01T12:00:00Z',
  '50000000-0000-0000-0000-000000000012', 'macos', true
);

select lives_ok(
  $$insert into wali.engagement_events (
      user_id, wallpaper_id, release_id, kind, occurred_at, client_request_id,
      coarse_source, contributes_to_ranking
    ) values (
      '00000000-0000-0000-0000-000000000003',
      '30000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      'install_succeeded', '2026-09-01T18:00:00Z',
      '50000000-0000-0000-0000-000000000013', 'macos', true
    )$$,
  'duplicate same-day contribution is recorded without affecting ranking'
);

select results_eq(
  $$select contributes_to_ranking, exclusion_reason from wali.engagement_events
    where client_request_id = '50000000-0000-0000-0000-000000000013'$$,
  $$values (false, 'duplicate_daily_contribution'::text)$$,
  'one account contributes only once per release, event kind, and UTC day'
);

select lives_ok(
  $$select wali.refresh_marketplace_aggregates('2026-09-02T00:00:00Z'::timestamptz)$$,
  'fixed-clock ranking refresh succeeds deterministically'
);

select * from finish();
rollback;
