-- WALI Marketplace foundation: isolated Storage buckets and exact-path RLS.

create table wali.account_exports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references wali.profiles(id) on delete cascade,
  storage_path text not null unique,
  status text not null default 'queued',
  expires_at timestamptz not null,
  completed_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint account_exports_path check (storage_path = 'exports/' || user_id::text || '/' || id::text || '/account.json'),
  constraint account_exports_status check (status in ('queued', 'processing', 'ready', 'expired', 'failed')),
  constraint account_exports_expiry check (expires_at > created_at),
  constraint account_exports_completion check (status <> 'ready' or completed_at is not null)
);

create trigger account_exports_touch before update on wali.account_exports
for each row execute function wali.touch_mutable_row();

alter table wali.account_exports enable row level security;
create policy account_exports_owner_read on wali.account_exports for select to authenticated
using (user_id = auth.uid());
grant select on wali.account_exports to authenticated;
grant all on wali.account_exports to service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('uploads-private', 'uploads-private', false, 1073741824, array['video/mp4', 'video/quicktime']),
  ('moderation-private', 'moderation-private', false, 52428800, array['application/pdf', 'image/jpeg', 'image/png', 'text/plain']),
  ('catalog-public', 'catalog-public', true, 1073741824, array['application/json', 'image/jpeg', 'image/png', 'video/mp4']),
  ('exports-private', 'exports-private', false, 104857600, array['application/json'])
on conflict (id) do update set
  name = excluded.name,
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function wali.can_insert_rights_proof(object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from wali.rights_declarations rd
    join wali.submissions s on s.id = rd.submission_id
    where s.creator_id = auth.uid()
      and rd.proof_storage_path = object_name
      and s.status in ('draft', 'uploading', 'uploaded', 'processing_failed', 'changes_requested')
  )
$$;

create policy wali_upload_insert_exact_path
on storage.objects for insert to authenticated
with check (
  bucket_id = 'uploads-private'
  and exists (
    select 1 from wali.upload_sessions us
     where us.creator_id = auth.uid()
       and us.storage_path = name
       and us.status in ('issued', 'uploading')
       and us.expires_at > statement_timestamp()
  )
);

create policy wali_rights_proof_insert_exact_path
on storage.objects for insert to authenticated
with check (
  bucket_id = 'moderation-private'
  and wali.can_insert_rights_proof(name)
);

create policy wali_catalog_public_read
on storage.objects for select to public
using (bucket_id = 'catalog-public');

create policy wali_export_owner_read
on storage.objects for select to authenticated
using (
  bucket_id = 'exports-private'
  and exists (
    select 1 from wali.account_exports e
     where e.user_id = auth.uid() and e.storage_path = name
       and e.status = 'ready' and e.expires_at > statement_timestamp()
  )
);

grant execute on function wali.can_insert_rights_proof(text) to authenticated;
