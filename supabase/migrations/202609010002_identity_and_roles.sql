-- WALI Marketplace foundation: identities, bounded role grants, terms, and preferences.

create table wali.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  handle extensions.citext not null unique,
  display_name text not null,
  avatar_path text,
  status wali.account_status not null default 'active',
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  deleted_at timestamptz,
  constraint profiles_handle_format check (handle::text ~ '^[a-z0-9][a-z0-9_]{2,31}$'),
  constraint profiles_display_name_plain check (wali.plain_text_is_valid(display_name, 1, 80)),
  constraint profiles_avatar_path_generated check (
    avatar_path is null or avatar_path ~ '^avatars/[0-9a-f-]{36}/[0-9a-f]{64}\.(png|jpe?g)$'
  ),
  constraint profiles_deleted_state check ((status = 'deleted') = (deleted_at is not null))
);

create table wali.role_grants (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references wali.profiles(id) on delete cascade,
  role wali.role_name not null,
  granted_by uuid not null references wali.profiles(id) on delete restrict,
  granted_at timestamptz not null default statement_timestamp(),
  revoked_by uuid references wali.profiles(id) on delete restrict,
  revoked_at timestamptz,
  reason text not null,
  constraint role_grants_reason_plain check (wali.plain_text_is_valid(reason, 1, 500)),
  constraint role_grants_revocation_pair check ((revoked_by is null) = (revoked_at is null))
);

create unique index role_grants_one_active_role
  on wali.role_grants (user_id, role)
  where revoked_at is null;

create table wali.creator_profiles (
  user_id uuid primary key references wali.profiles(id) on delete cascade,
  bio text not null default '',
  website_url text,
  verification_status wali.verification_status not null default 'unverified',
  verified_at timestamptz,
  verified_by uuid references wali.profiles(id) on delete restrict,
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint creator_profiles_bio_plain check (bio = '' or wali.plain_text_is_valid(bio, 1, 1000)),
  constraint creator_profiles_website_https check (wali.https_url_is_valid(website_url)),
  constraint creator_profiles_verified_pair check (
    (verification_status = 'verified') = (verified_at is not null and verified_by is not null)
  )
);

create table wali.terms_acceptances (
  user_id uuid not null references wali.profiles(id) on delete cascade,
  document_kind text not null,
  document_version text not null,
  accepted_at timestamptz not null default statement_timestamp(),
  request_id uuid not null,
  primary key (user_id, document_kind, document_version),
  constraint terms_kind_format check (document_kind ~ '^[a-z][a-z0-9_]{1,63}$'),
  constraint terms_version_format check (document_version ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}([.][0-9]+)?$')
);

create table wali.user_preferences (
  user_id uuid primary key references wali.profiles(id) on delete cascade,
  rating_ceiling wali.content_rating not null default 'teen',
  locale text not null default 'en-US',
  personalization_opt_out boolean not null default false,
  marketing_opt_out boolean not null default true,
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint user_preferences_locale_format check (locale ~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$')
);

create index profiles_status_idx on wali.profiles (status, created_at);
create index role_grants_user_active_idx on wali.role_grants (user_id, role) where revoked_at is null;

create trigger profiles_touch before update on wali.profiles
for each row execute function wali.touch_mutable_row();
create trigger creator_profiles_touch before update on wali.creator_profiles
for each row execute function wali.touch_mutable_row();
create trigger user_preferences_touch before update on wali.user_preferences
for each row execute function wali.touch_mutable_row();

create or replace function wali.current_user_id()
returns uuid
language sql
stable
security invoker
set search_path = ''
as $$ select auth.uid() $$;

create or replace function wali.current_aal()
returns text
language sql
stable
security invoker
set search_path = ''
as $$ select coalesce(auth.jwt() ->> 'aal', 'aal1') $$;

create or replace function wali.has_active_role(required_role wali.role_name)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from wali.profiles p
      join wali.role_grants rg on rg.user_id = p.id
     where p.id = auth.uid()
       and p.status = 'active'
       and rg.role = required_role
       and rg.revoked_at is null
  )
$$;

create or replace function wali.has_moderation_access()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select wali.current_aal() = 'aal2'
     and (wali.has_active_role('moderator') or wali.has_active_role('admin'))
$$;

create or replace function wali.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_name text;
begin
  requested_name := left(
    regexp_replace(
      coalesce(new.raw_user_meta_data ->> 'display_name', new.raw_user_meta_data ->> 'name', 'WALI User'),
      '[[:cntrl:]]', '', 'g'
    ),
    80
  );
  if char_length(btrim(requested_name)) = 0 then
    requested_name := 'WALI User';
  end if;

  insert into wali.profiles (id, handle, display_name)
  values (new.id, ('user_' || right(replace(new.id::text, '-', ''), 27))::extensions.citext, requested_name);

  insert into wali.user_preferences (user_id) values (new.id);
  return new;
end
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function wali.handle_new_auth_user();

alter table wali.profiles enable row level security;
alter table wali.role_grants enable row level security;
alter table wali.creator_profiles enable row level security;
alter table wali.terms_acceptances enable row level security;
alter table wali.user_preferences enable row level security;

create policy profiles_active_public_read on wali.profiles
for select to anon, authenticated
using (status = 'active' or id = auth.uid());

create policy profiles_owner_update on wali.profiles
for update to authenticated
using (id = auth.uid() and status = 'active')
with check (id = auth.uid() and status = 'active');

create policy role_grants_owner_read on wali.role_grants
for select to authenticated
using (user_id = auth.uid());

create policy creator_profiles_public_read on wali.creator_profiles
for select to anon, authenticated
using (verification_status = 'verified');

create policy creator_profiles_private_read on wali.creator_profiles
for select to authenticated
using (user_id = auth.uid() or wali.has_moderation_access());

create policy creator_profiles_owner_insert on wali.creator_profiles
for insert to authenticated
with check (user_id = auth.uid() and verification_status = 'unverified');

create policy creator_profiles_owner_update on wali.creator_profiles
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy terms_acceptances_owner_read on wali.terms_acceptances
for select to authenticated
using (user_id = auth.uid());

create policy preferences_owner_all on wali.user_preferences
for all to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

grant usage on schema wali to anon, authenticated;
grant select on wali.profiles, wali.creator_profiles to anon, authenticated;
grant select on wali.role_grants, wali.terms_acceptances, wali.user_preferences to authenticated;
grant update (handle, display_name, avatar_path) on wali.profiles to authenticated;
grant insert (user_id, bio, website_url) on wali.creator_profiles to authenticated;
grant update (bio, website_url) on wali.creator_profiles to authenticated;
grant update (rating_ceiling, locale, personalization_opt_out, marketing_opt_out) on wali.user_preferences to authenticated;

grant execute on function wali.current_user_id() to authenticated;
grant execute on function wali.current_aal() to authenticated;
grant execute on function wali.has_active_role(wali.role_name) to authenticated;
grant execute on function wali.has_moderation_access() to authenticated;

revoke execute on function wali.handle_new_auth_user() from public, anon, authenticated;
revoke execute on function wali.touch_mutable_row() from public, anon, authenticated;
revoke execute on function wali.plain_text_is_valid(text, integer, integer) from public, anon, authenticated;
revoke execute on function wali.https_url_is_valid(text) from public, anon, authenticated;
