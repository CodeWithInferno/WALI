-- WALI Marketplace foundation: constrained Edge commands and explicit function privileges.

create or replace function public.record_install_v1(
  actor_id uuid,
  request_id uuid,
  idempotency_key text,
  install_receipt uuid,
  release_id uuid,
  manifest_digest text,
  result text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_hash text;
  replay jsonb;
  receipt_row wali.install_receipts%rowtype;
  release_row wali.wallpaper_releases%rowtype;
  response jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if request_id is null
     or idempotency_key is null
     or char_length(idempotency_key) not between 16 and 64
     or idempotency_key !~ '^[A-Za-z0-9_-]+$'
     or manifest_digest !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  if result <> 'verified_installed' then
    raise exception using errcode = 'P0001', message = 'WALI_INSTALL_RESULT_INVALID';
  end if;
  if not exists (
    select 1 from wali.profiles p where p.id = actor_id and p.status = 'active'
  ) then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;

  request_hash := encode(extensions.digest(
    install_receipt::text || ':' || release_id::text || ':' ||
    manifest_digest || ':' || result,
    'sha256'
  ), 'hex');
  replay := wali.reserve_command(actor_id, 'record_install', idempotency_key, request_hash);
  if replay is not null then
    return replay;
  end if;

  select * into receipt_row
    from wali.install_receipts receipt
   where receipt.id = install_receipt
     and receipt.user_id = actor_id
     and receipt.release_id = record_install_v1.release_id
   for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'WALI_INSTALL_RECEIPT_INVALID';
  end if;
  if receipt_row.expires_at <= statement_timestamp() then
    raise exception using errcode = 'P0001', message = 'WALI_INSTALL_RECEIPT_EXPIRED';
  end if;
  if receipt_row.consumed_at is not null then
    raise exception using errcode = 'P0001', message = 'WALI_INSTALL_RECEIPT_CONSUMED';
  end if;

  select * into release_row
    from wali.wallpaper_releases release
   where release.id = record_install_v1.release_id
     and release.status = 'published';
  if not found
     or release_row.manifest_digest <> record_install_v1.manifest_digest
     or exists (
       select 1 from wali.catalog_revocations revocation
        where revocation.release_id = record_install_v1.release_id
     ) then
    raise exception using errcode = 'P0001', message = 'WALI_MANIFEST_INVALID';
  end if;

  update wali.install_receipts set consumed_at = statement_timestamp()
   where id = receipt_row.id;

  insert into wali.engagement_events (
    user_id, wallpaper_id, release_id, kind, client_request_id,
    install_receipt_id, coarse_source
  ) values (
    actor_id, release_row.wallpaper_id, release_row.id, 'install_succeeded', request_id,
    receipt_row.id, 'macos'
  );

  response := jsonb_build_object(
    'release_id', release_row.id,
    'result', 'verified_installed',
    'recorded', true
  );
  perform wali.complete_command(actor_id, 'record_install', idempotency_key, response);
  return response;
end
$$;

-- PostgreSQL grants EXECUTE to PUBLIC on new functions unless explicitly
-- revoked. Keep the authoritative schema private and regrant only deliberate
-- Data API helpers. Trigger and queue functions never need caller EXECUTE.
do $privileges$
declare
  function_row record;
begin
  for function_row in
    select p.oid::regprocedure as signature
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'wali'
  loop
    execute format(
      'revoke execute on function %s from public, anon, authenticated',
      function_row.signature
    );
  end loop;
end
$privileges$;

grant execute on function wali.current_user_id() to authenticated;
grant execute on function wali.current_aal() to authenticated;
grant execute on function wali.has_active_role(wali.role_name) to authenticated;
grant execute on function wali.has_moderation_access() to authenticated;
grant execute on function wali.transition_submission(uuid, wali.submission_status, bigint, uuid)
  to service_role;
grant execute on function wali.record_moderation_decision(
  uuid, wali.review_decision, bigint, uuid, text, text, text[]
) to service_role;
grant execute on function wali.can_insert_rights_proof(text) to authenticated;

revoke execute on function public.record_install_v1(uuid, uuid, text, uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.record_install_v1(uuid, uuid, text, uuid, uuid, text, text)
  to service_role;
