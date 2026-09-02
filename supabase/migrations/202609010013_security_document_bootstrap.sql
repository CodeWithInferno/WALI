-- Allow the operator-only security document publisher to bootstrap the signed
-- revocation list as well as publish trust transitions. The original function
-- contained validation for revocations but rejected that kind before reaching it.

create or replace function public.wali_edge_publish_security_document_v1(
  actor_id uuid, actor_aal text, request_id uuid, document_kind text,
  document_revision bigint, canonical_body text, detached_signature text,
  signing_key_id text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare body_bytes bytea; signature_bytes bytea; document jsonb; prior_revision bigint; issued timestamptz;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if actor_aal <> 'aal2' or not wali.edge_actor_has_role(actor_id, 'admin') then
    raise exception using errcode = 'P0001', message = 'WALI_ADMIN_AAL2_REQUIRED';
  end if;
  if document_kind not in ('trust_transition', 'revocations')
     or document_revision not between 1 and 2147483647
     or canonical_body !~ '^[A-Za-z0-9_-]+$' or detached_signature !~ '^[A-Za-z0-9_-]{86}$' then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  begin
    body_bytes := decode(translate(canonical_body, '-_', '+/') || repeat('=', (4 - length(canonical_body) % 4) % 4), 'base64');
    signature_bytes := decode(translate(detached_signature, '-_', '+/') || repeat('=', (4 - length(detached_signature) % 4) % 4), 'base64');
    document := convert_from(body_bytes, 'UTF8')::jsonb;
  exception when others then
    raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_INVALID';
  end;
  if octet_length(signature_bytes) <> 64
     or octet_length(body_bytes) > (case when document_kind = 'trust_transition' then 32768 else 1048576 end)
     or document ->> 'revision' <> document_revision::text
     or document ->> 'issued_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' then
    raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_INVALID';
  end if;
  issued := (document ->> 'issued_at')::timestamptz;
  if document_kind = 'trust_transition' then
    if document ->> 'schema' <> 'wali.catalog.trust-transition.v1'
       or jsonb_typeof(document -> 'keys') <> 'array'
       or jsonb_array_length(document -> 'keys') not between 1 and 32
       or not exists (select 1 from wali.catalog_signing_keys k where k.key_id = signing_key_id
         and k.status = 'active' and k.rotated_from_key_id is null and issued between k.valid_from and coalesce(k.valid_until, 'infinity')) then
      raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_INVALID';
    end if;
  else
    if document -> 'schema' <> '{"epoch":1,"revision":0}'::jsonb
       or document ->> 'key_id' <> signing_key_id
       or jsonb_typeof(document -> 'revocations') <> 'array'
       or jsonb_array_length(document -> 'revocations') > 4096
       or not exists (select 1 from wali.catalog_signing_keys k where k.key_id = signing_key_id
         and k.status = 'active' and issued between k.valid_from and coalesce(k.valid_until, 'infinity')) then
      raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_INVALID';
    end if;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('wali.catalog_signed_documents:' || document_kind, 0));
  select coalesce(max(revision), 0) into prior_revision from wali.catalog_signed_documents where kind = document_kind;
  if document_revision <> prior_revision + 1 then
    raise exception using errcode = 'P0001', message = 'WALI_SIGNED_DOCUMENT_REVISION_INVALID';
  end if;
  insert into wali.catalog_signed_documents (kind, revision, issued_at, body, body_digest,
    signature, signing_key_id, created_by, request_id)
  values (document_kind, document_revision, issued, body_bytes,
    encode(extensions.digest(body_bytes, 'sha256'), 'hex'), signature_bytes,
    signing_key_id, actor_id, request_id);
  insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
  values (actor_id, 'catalog.security_document.published', 'signing_key', actor_id, request_id,
    jsonb_build_object('kind', document_kind, 'revision', document_revision, 'key_id', signing_key_id));
  return jsonb_build_object('kind', document_kind, 'revision', document_revision,
    'body_digest', encode(extensions.digest(body_bytes, 'sha256'), 'hex'));
end $$;

revoke all on function public.wali_edge_publish_security_document_v1(
  uuid, text, uuid, text, bigint, text, text, text
) from public, anon, authenticated;
grant execute on function public.wali_edge_publish_security_document_v1(
  uuid, text, uuid, text, bigint, text, text, text
) to service_role;
