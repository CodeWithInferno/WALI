-- ADR0029: private, exact-account Apple revocation custody. No credentials or
-- backfill are introduced by this migration; provider material enters only via Edge.
create table wali.apple_authorizations (
  actor_id uuid not null references wali.profiles(id) on delete restrict,
  client_id text not null check(client_id in ('com.wali.store.WALI','com.wali.store.development.WALI')),
  apple_subject text not null check(apple_subject ~ '^[A-Za-z0-9._-]+$' and length(apple_subject)<=256),
  encrypted_refresh_token text check(encrypted_refresh_token ~ '^v1\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]+$' and length(encrypted_refresh_token) between 42 and 11020),
  encryption_key_version text check(encryption_key_version ~ '^[A-Za-z0-9_-]{1,32}$'),
  code_sha256 text check(code_sha256 ~ '^[0-9a-f]{64}$'),
  pending_code_sha256 text check(pending_code_sha256 ~ '^[0-9a-f]{64}$'),
  binding_lease_token uuid,
  binding_lease_expires_at timestamptz,
  revision bigint not null default 1 check(revision>0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  primary key(actor_id,client_id),
  constraint apple_ciphertext_metadata_pair check(
    (encrypted_refresh_token is null and encryption_key_version is null and code_sha256 is null)
    or (encrypted_refresh_token is not null and encryption_key_version is not null and code_sha256 is not null)),
  constraint apple_binding_lease_pair check(
    (pending_code_sha256 is null and binding_lease_token is null and binding_lease_expires_at is null)
    or (pending_code_sha256 is not null and binding_lease_token is not null and binding_lease_expires_at is not null))
);
alter table wali.apple_authorizations enable row level security;
revoke all on wali.apple_authorizations from public,anon,authenticated,service_role,wali_worker;

create function public.wali_edge_begin_apple_authorization_v1(
  actor_id uuid, client_id text, apple_subject text, code_sha256 text
) returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare binding wali.apple_authorizations%rowtype; profile_status wali.account_status;
begin
  if auth.role() <> 'service_role' then raise exception using errcode='P0001',message='WALI_SERVICE_ROLE_REQUIRED'; end if;
  if actor_id is null or client_id is null or client_id not in ('com.wali.store.WALI','com.wali.store.development.WALI')
    or apple_subject is null or (apple_subject !~ '^[A-Za-z0-9._-]+$' or length(apple_subject)>256)
    or code_sha256 is null or code_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='P0001',message='WALI_REQUEST_INVALID';
  end if;
  -- Same first lock as deletion admission. No binding can be acknowledged after freeze.
  select p.status into profile_status from wali.profiles p where p.id=actor_id for update;
  if not found or profile_status <> 'active' then raise exception using errcode='P0001',message='WALI_ACCOUNT_INACTIVE'; end if;
  perform 1 from auth.identities i where i.user_id=actor_id and i.provider='apple' and i.identity_data->>'sub'=apple_subject for share;
  if not found then raise exception using errcode='P0001',message='WALI_AUTH_SUBJECT_CHANGED'; end if;
  select * into binding from wali.apple_authorizations a where a.actor_id=wali_edge_begin_apple_authorization_v1.actor_id and a.client_id=wali_edge_begin_apple_authorization_v1.client_id for update;
  if found then
    if binding.apple_subject <> apple_subject then raise exception using errcode='P0001',message='WALI_AUTH_SUBJECT_CHANGED'; end if;
    if binding.code_sha256=code_sha256 and binding.encrypted_refresh_token is not null then
      return jsonb_build_object('status','bound','revision',binding.revision,'lease_token',null);
    end if;
    if binding.binding_lease_expires_at > clock_timestamp() then return jsonb_build_object('status','busy','revision',binding.revision,'lease_token',null); end if;
  end if;
  insert into wali.apple_authorizations(actor_id,client_id,apple_subject,pending_code_sha256,binding_lease_token,binding_lease_expires_at)
  values(actor_id,client_id,apple_subject,code_sha256,gen_random_uuid(),clock_timestamp()+interval '90 seconds')
  on conflict(actor_id,client_id) do update set pending_code_sha256=excluded.pending_code_sha256,
    binding_lease_token=excluded.binding_lease_token,binding_lease_expires_at=excluded.binding_lease_expires_at,
    revision=wali.apple_authorizations.revision+1,updated_at=statement_timestamp()
  returning * into binding;
  return jsonb_build_object('status','exchange','revision',binding.revision,'lease_token',binding.binding_lease_token);
end $$;

create function public.wali_edge_complete_apple_authorization_v1(
  actor_id uuid, client_id text, apple_subject text, code_sha256 text,
  lease_token uuid, encrypted_refresh_token text, encryption_key_version text
) returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare binding wali.apple_authorizations%rowtype; profile_status wali.account_status; linked boolean;
begin
  if auth.role() <> 'service_role' then raise exception using errcode='P0001',message='WALI_SERVICE_ROLE_REQUIRED'; end if;
  if actor_id is null or client_id is null or apple_subject is null or code_sha256 is null or lease_token is null
    or encrypted_refresh_token is null or (encrypted_refresh_token !~ '^v1\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]+$' or length(encrypted_refresh_token) not between 42 and 11020)
    or encryption_key_version is null or encryption_key_version !~ '^[A-Za-z0-9_-]{1,32}$' then
    raise exception using errcode='P0001',message='WALI_REQUEST_INVALID';
  end if;
  select p.status into profile_status from wali.profiles p where p.id=actor_id for update;
  perform 1 from auth.identities i where i.user_id=actor_id and i.provider='apple' and i.identity_data->>'sub'=apple_subject for share;
  linked := found;
  select * into binding from wali.apple_authorizations a where a.actor_id=wali_edge_complete_apple_authorization_v1.actor_id and a.client_id=wali_edge_complete_apple_authorization_v1.client_id for update;
  if not found then return jsonb_build_object('status','rejected'); end if;
  -- A lost successful reply replays the identical encrypted envelope, never another token.
  if binding.apple_subject=apple_subject and binding.code_sha256=code_sha256
    and binding.encrypted_refresh_token=encrypted_refresh_token and binding.encryption_key_version=encryption_key_version then
    -- The credential may already belong to deletion after an uncertain commit.
    -- Preserve custody without admitting a now-frozen account's sign-in.
    return jsonb_build_object('status',case when profile_status='active' and linked then 'bound' else 'retained' end);
  end if;
  if profile_status is distinct from 'active' or not linked or binding.apple_subject<>apple_subject
    or binding.pending_code_sha256 is distinct from code_sha256 or binding.binding_lease_token is distinct from lease_token
    or binding.binding_lease_expires_at <= clock_timestamp() then
    if binding.binding_lease_token=lease_token then
      update wali.apple_authorizations a set pending_code_sha256=null,binding_lease_token=null,binding_lease_expires_at=null,
        revision=a.revision+1,updated_at=statement_timestamp() where a.actor_id=wali_edge_complete_apple_authorization_v1.actor_id and a.client_id=wali_edge_complete_apple_authorization_v1.client_id;
    end if;
    return jsonb_build_object('status','rejected');
  end if;
  update wali.apple_authorizations a set encrypted_refresh_token=wali_edge_complete_apple_authorization_v1.encrypted_refresh_token,
    encryption_key_version=wali_edge_complete_apple_authorization_v1.encryption_key_version,
    code_sha256=wali_edge_complete_apple_authorization_v1.code_sha256,pending_code_sha256=null,
    binding_lease_token=null,binding_lease_expires_at=null,revision=a.revision+1,updated_at=statement_timestamp()
    where a.actor_id=wali_edge_complete_apple_authorization_v1.actor_id and a.client_id=wali_edge_complete_apple_authorization_v1.client_id;
  return jsonb_build_object('status','bound');
end $$;

create function public.wali_edge_cancel_apple_authorization_v1(actor_id uuid,client_id text,lease_token uuid)
returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
begin
  if auth.role() <> 'service_role' then raise exception using errcode='P0001',message='WALI_SERVICE_ROLE_REQUIRED'; end if;
  perform 1 from wali.profiles p where p.id=actor_id for update;
  update wali.apple_authorizations a set pending_code_sha256=null,binding_lease_token=null,binding_lease_expires_at=null,
    revision=a.revision+1,updated_at=statement_timestamp()
    where a.actor_id=wali_edge_cancel_apple_authorization_v1.actor_id and a.client_id=wali_edge_cancel_apple_authorization_v1.client_id and a.binding_lease_token=wali_edge_cancel_apple_authorization_v1.lease_token;
end $$;
revoke all on function public.wali_edge_begin_apple_authorization_v1(uuid,text,text,text),
  public.wali_edge_complete_apple_authorization_v1(uuid,text,text,text,uuid,text,text),
  public.wali_edge_cancel_apple_authorization_v1(uuid,text,uuid) from public,anon,authenticated,wali_worker;
grant execute on function public.wali_edge_begin_apple_authorization_v1(uuid,text,text,text),
  public.wali_edge_complete_apple_authorization_v1(uuid,text,text,text,uuid,text,text),
  public.wali_edge_cancel_apple_authorization_v1(uuid,text,uuid) to service_role;
