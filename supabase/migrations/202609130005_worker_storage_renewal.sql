-- ADR 0026: inert deployment-owned binding. No login, secret or enabled worker
-- is provisioned by this migration. Existing Storage path/lease RLS is unchanged.
begin;
create table wali.worker_storage_auth_bindings (
 login_role_oid oid primary key,
 login_role_name name not null unique,
 worker_id text not null check (worker_id ~ '^[a-z0-9][a-z0-9_-]{0,62}$'),
 storage_origin text not null check (length(storage_origin) <= 255 and storage_origin ~ '^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$'),
 issuer_secret_id uuid not null references vault.secrets(id),
 enabled boolean not null default false
);
create unique index worker_storage_auth_active_identity on wali.worker_storage_auth_bindings(worker_id) where enabled;
alter table wali.worker_storage_auth_bindings enable row level security;
revoke all on wali.worker_storage_auth_bindings from public,anon,authenticated,service_role,wali_worker,wali_storage_worker;
comment on table wali.worker_storage_auth_bindings is 'Deployment-only machine identity and Vault reference; contains no credential value or user activity.';

create function wali.renew_storage_worker_token()
returns table(access_token text,expires_at timestamptz,worker_id text)
language plpgsql security definer set search_path = '' as $$
declare
 binding wali.worker_storage_auth_bindings%rowtype;
 login_id oid;
 signing_secret text;
 issued_at bigint;
 header_part text;
 claims_part text;
 signature_part text;
begin
 -- SECURITY DEFINER changes current_user; session_user remains the authenticated
 -- connection identity. An API JWT or caller-selected GUC cannot replace it.
 if current_setting('role',true) is distinct from 'wali_worker' then
  raise exception 'WALI_STORAGE_CREDENTIAL_UNAVAILABLE';
 end if;
 select r.oid into login_id from pg_catalog.pg_roles r
 where r.rolname=session_user and r.rolcanlogin and not r.rolinherit
  and not r.rolsuper and not r.rolcreatedb and not r.rolcreaterole
  and not r.rolreplication and not r.rolbypassrls
  and r.rolname not in ('authenticator','postgres','supabase_admin','service_role','wali_worker');
 if login_id is null or not pg_catalog.pg_has_role(login_id,'wali_worker','MEMBER') or not exists(
  select 1 from pg_catalog.pg_roles r where r.rolname='wali_worker'
   and not r.rolcanlogin and not r.rolinherit and not r.rolsuper
   and not r.rolcreatedb and not r.rolcreaterole and not r.rolreplication and not r.rolbypassrls
 ) then raise exception 'WALI_STORAGE_CREDENTIAL_UNAVAILABLE'; end if;
 select b.* into binding from wali.worker_storage_auth_bindings b
 where b.login_role_oid=login_id and b.login_role_name=session_user and b.enabled for share;
 if not found then raise exception 'WALI_STORAGE_CREDENTIAL_UNAVAILABLE'; end if;
 select s.decrypted_secret into signing_secret from vault.decrypted_secrets s where s.id=binding.issuer_secret_id;
 if signing_secret is null or octet_length(signing_secret)<32 or octet_length(signing_secret)>4096 then
  raise exception 'WALI_STORAGE_CREDENTIAL_UNAVAILABLE';
 end if;
 issued_at:=floor(extract(epoch from clock_timestamp()))::bigint;
 header_part:=translate(rtrim(replace(encode(convert_to('{"alg":"HS256","typ":"JWT"}','utf8'),'base64'),E'\n',''),'='),'+/','-_');
 claims_part:=translate(rtrim(replace(encode(convert_to(jsonb_build_object(
  'role','wali_storage_worker','aud','authenticated','worker_id',binding.worker_id,
  'iss',binding.storage_origin||'/auth/v1','iat',issued_at,'exp',issued_at+900
 )::text,'utf8'),'base64'),E'\n',''),'='),'+/','-_');
 signature_part:=translate(rtrim(encode(extensions.hmac(header_part||'.'||claims_part,signing_secret,'sha256'),'base64'),'='),'+/','-_');
 return query select header_part||'.'||claims_part||'.'||signature_part,to_timestamp(issued_at+900),binding.worker_id;
exception when others then
 -- Never expose a Vault value, token, object path or raw database exception.
 raise exception using errcode='P0001',message='WALI_STORAGE_CREDENTIAL_UNAVAILABLE';
end;
$$;
revoke all on function wali.renew_storage_worker_token() from public,anon,authenticated,service_role,wali_storage_worker;
grant execute on function wali.renew_storage_worker_token() to wali_worker;
comment on function wali.renew_storage_worker_token() is 'No-argument private issuance; exact restricted session login binding and fixed 900-second scoped Storage claims.';
commit;
