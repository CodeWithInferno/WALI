drop function if exists public.wali_edge_accept_creator_terms_v1(uuid, uuid, text, text);

create function public.wali_edge_accept_creator_terms_v1(
  actor_id uuid,
  expected_subject_id uuid,
  request_id uuid,
  idempotency_key text,
  creator_terms_version text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; current_version text; latest_revision bigint;
  grant_row wali.role_grants%rowtype; response jsonb; enrolled boolean := false;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  if expected_subject_id is distinct from actor_id then
    raise exception using errcode = 'P0001', message = 'WALI_AUTH_SUBJECT_CHANGED';
  end if;
  if not exists (select 1 from wali.profiles p where p.id = actor_id and p.status = 'active') then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  select cfg.creator_terms_version into current_version from wali.runtime_configuration cfg where cfg.singleton;
  if creator_terms_version is distinct from current_version then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_TERMS_REQUIRED';
  end if;
  select * into grant_row from wali.role_grants role_grant
   where role_grant.user_id = actor_id and role_grant.role = 'creator'
   order by role_grant.revision desc limit 1 for update;
  if grant_row.id is not null and grant_row.revoked_at is not null then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_ROLE_REVOKED';
  end if;
  request_hash := encode(extensions.digest(actor_id::text || ':' || creator_terms_version, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'accept_creator_terms', idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  insert into wali.terms_acceptances (user_id, document_kind, document_version, request_id)
  values (actor_id, 'creator_terms', creator_terms_version, request_id)
  on conflict (user_id, document_kind, document_version) do nothing;
  insert into wali.creator_profiles (user_id) values (actor_id) on conflict (user_id) do nothing;

  if grant_row.id is null then
    select coalesce(max(role_grant.revision), 0) + 1 into latest_revision
      from wali.role_grants role_grant where role_grant.user_id = actor_id and role_grant.role = 'creator';
    insert into wali.role_grants (user_id, role, granted_by, reason, revision)
    values (actor_id, 'creator', actor_id, 'creator_terms_self_enrollment', latest_revision)
    returning * into grant_row;
    enrolled := true;
    insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
    values (actor_id, 'creator.self_enrolled', 'account', actor_id, request_id,
      jsonb_build_object('terms_version', creator_terms_version, 'grant_revision', grant_row.revision));
  end if;
  response := jsonb_build_object(
    'account_is_active', true, 'creator_enrolled', true, 'creator_grant_revision', grant_row.revision,
    'accepted_creator_terms_version', creator_terms_version, 'current_creator_terms_version', current_version,
    'newly_enrolled', enrolled
  );
  perform wali.complete_command(actor_id, 'accept_creator_terms', idempotency_key, response);
  return response;
end $$;

revoke execute on function public.wali_edge_accept_creator_terms_v1(uuid, uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.wali_edge_accept_creator_terms_v1(uuid, uuid, uuid, text, text)
  to service_role;
