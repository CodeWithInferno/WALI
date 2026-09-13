-- ADR 0025: completed acknowledgements remain counted after their private
-- authorization receipts are retired. This stores no installer/event history.
begin;

-- Serialize backfill with receipt creation/consumption and retention. The
-- trigger is installed before this transaction releases the same write lock.
lock table wali.install_receipts in share row exclusive mode;

create table wali.wallpaper_download_totals (
  wallpaper_id uuid primary key references wali.wallpapers(id) on delete cascade,
  completed_downloads bigint not null default 0 check (completed_downloads >= 0)
);
alter table wali.wallpaper_download_totals enable row level security;
revoke all on wali.wallpaper_download_totals from public, anon, authenticated, service_role, wali_worker;

-- Only retained consumed receipts can prove historical completions. Never
-- infer missing history from ranking samples, requests or assumed downloads.
insert into wali.wallpaper_download_totals(wallpaper_id, completed_downloads)
select release.wallpaper_id, count(*)
  from wali.install_receipts receipt
  join wali.wallpaper_releases release on release.id = receipt.release_id
 where receipt.consumed_at is not null
 group by release.wallpaper_id;

create function wali.accumulate_completed_download()
returns trigger language plpgsql security definer set search_path = '' as $$
declare target_wallpaper_id uuid;
begin
  if tg_op = 'UPDATE' and old.consumed_at is not null then
    -- Account anonymization is permitted; completed receipt identity, release
    -- and consumption cannot be changed to count the same receipt twice.
    if new.id is distinct from old.id or new.release_id is distinct from old.release_id
       or new.consumed_at is distinct from old.consumed_at then
      raise exception using errcode = 'P0001', message = 'WALI_INSTALL_RECEIPT_IMMUTABLE';
    end if;
    return new;
  end if;
  if new.consumed_at is null then return new; end if;
  select release.wallpaper_id into strict target_wallpaper_id
    from wali.wallpaper_releases release where release.id = new.release_id;
  insert into wali.wallpaper_download_totals(wallpaper_id, completed_downloads)
    values (target_wallpaper_id, 1)
  on conflict(wallpaper_id) do update
    set completed_downloads = wali.wallpaper_download_totals.completed_downloads + 1;
  return new;
end $$;
revoke all on function wali.accumulate_completed_download() from public, anon, authenticated, service_role, wali_worker;
create trigger install_receipt_completed_download
  after insert or update of id, release_id, consumed_at on wali.install_receipts
  for each row execute function wali.accumulate_completed_download();

-- Public eligibility, ratings and active bookmark totals remain unchanged.
create or replace function wali.catalog_public_counts(target_wallpaper_id uuid)
returns table (verified_install_count bigint, favorite_count bigint, save_count bigint)
language sql stable security definer set search_path = '' as $$
  select
    coalesce((select totals.completed_downloads from wali.wallpaper_download_totals totals
      where totals.wallpaper_id = w.id), 0::bigint),
    (select count(*) from wali.favorites f where f.wallpaper_id = w.id and f.active),
    (select count(*) from wali.saved_wallpapers s where s.wallpaper_id = w.id and s.active)
  from wali.wallpapers w
  join wali.profiles p on p.id = w.creator_id and p.status = 'active'
  join wali.creator_profiles cp on cp.user_id = p.id
  join wali.categories c on c.id = w.primary_category_id and c.active
  join wali.licenses l on l.id = w.license_id and l.active and l.redistribution_allowed
  join wali.wallpaper_releases r on r.id = w.current_release_id and r.status = 'published'
  where w.id = target_wallpaper_id and w.status = 'published' and w.visibility = 'public'
    and case w.content_rating when 'everyone' then 0 when 'teen' then 1 else 2 end <= wali.catalog_rating_limit()
$$;

commit;
