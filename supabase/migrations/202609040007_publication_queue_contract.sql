-- Queue the complete immutable promotion snapshot required by the worker.
-- The worker still validates every artifact and compares this intent with its
-- database lease before reading or publishing any bytes.
create or replace function public.wali_edge_prepare_publication_v1(
  actor_id uuid, actor_aal text, request_id uuid, idempotency_key text,
  submission_id uuid, expected_revision bigint, expected_generation bigint,
  expected_wallpaper_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare submission_row wali.submissions%rowtype; wallpaper_row wali.wallpapers%rowtype;
  release_row wali.wallpaper_releases%rowtype; key_row wali.catalog_signing_keys%rowtype;
  rights_row wali.rights_declarations%rowtype; intent wali.publication_intents%rowtype;
  artifact_digest text; metadata_set_digest text; promotion_id uuid;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if actor_aal <> 'aal2' or not (wali.edge_actor_has_role(actor_id, 'moderator') or wali.edge_actor_has_role(actor_id, 'admin')) then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATOR_AAL2_REQUIRED';
  end if;
  select * into intent from wali.publication_intents publication_intent
   where publication_intent.actor_id = wali_edge_prepare_publication_v1.actor_id
     and publication_intent.idempotency_key = wali_edge_prepare_publication_v1.idempotency_key
   for update;
  if found and intent.consumed_at is not null then
    if intent.submission_id <> wali_edge_prepare_publication_v1.submission_id
       or intent.submission_revision <> expected_revision
       or intent.generation <> expected_generation
       or intent.wallpaper_revision <> expected_wallpaper_revision then
      raise exception using errcode = 'P0001', message = 'WALI_IDEMPOTENCY_CONFLICT';
    end if;
    return jsonb_build_object('replayed', true, 'response', intent.response);
  end if;
  select * into submission_row from wali.submissions s where s.id = submission_id for update;
  if not found or submission_row.status <> 'approved' then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_READY'; end if;
  if submission_row.revision <> expected_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if submission_row.generation <> expected_generation then raise exception using errcode = 'P0001', message = 'WALI_STALE_PROCESSING_GENERATION'; end if;
  select * into wallpaper_row from wali.wallpapers w where w.id = submission_row.wallpaper_id for update;
  if wallpaper_row.revision <> expected_wallpaper_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  select * into rights_row from wali.rights_declarations rights
   where rights.submission_id = submission_row.id and rights.review_status = 'approved' for share;
  if not found or rights_row.license_id <> submission_row.license_id
     or rights_row.rights_holder <> submission_row.rights_holder
     or rights_row.attribution_text is distinct from submission_row.attribution_text
     or rights_row.source_url is distinct from submission_row.source_url then
    raise exception using errcode = 'P0001', message = 'WALI_PUBLICATION_RIGHTS_INVALID';
  end if;
  metadata_set_digest := encode(extensions.digest(jsonb_build_object(
    'title', submission_row.proposed_title, 'description', submission_row.proposed_description,
    'primary_category_id', submission_row.primary_category_id, 'license_id', rights_row.license_id,
    'rights_holder', rights_row.rights_holder, 'attribution_text', rights_row.attribution_text,
    'source_url', rights_row.source_url, 'content_rating', submission_row.content_rating_warning,
    'creator_tags', coalesce((select jsonb_agg(suggestion.tag_id order by suggestion.tag_id)
      from wali.submission_tag_suggestions suggestion where suggestion.submission_id = submission_row.id
        and suggestion.source = 'creator'), '[]'::jsonb)
  )::text, 'sha256'), 'hex');
  select * into release_row from wali.wallpaper_releases r where r.source_submission_id = submission_row.id for update;
  if not found or release_row.status <> 'approved' then raise exception using errcode = 'P0001', message = 'WALI_RELEASE_NOT_AVAILABLE'; end if;
  if (select count(*) from wali.release_artifacts ra where ra.release_id = release_row.id
      and ra.role in ('thumbnail','poster','preview','video_default')) <> 4 then
    if (select count(*) from wali.release_staged_artifacts rsa where rsa.release_id = release_row.id
        and rsa.role in ('thumbnail','poster','preview','video_default')) <> 4 then
      raise exception using errcode = 'P0001', message = 'WALI_ARTIFACT_SET_INVALID';
    end if;
    insert into wali.artifact_promotions (release_id) values (release_row.id)
    on conflict (release_id) do update set status = case
      when wali.artifact_promotions.status = 'failed' then 'queued' else wali.artifact_promotions.status end,
      safe_error_code = case when wali.artifact_promotions.status = 'failed' then null else wali.artifact_promotions.safe_error_code end
    returning id into promotion_id;
    if not exists (select 1 from pgmq.q_wali_promotions q where (q.message ->> 'promotion_id')::uuid = promotion_id) then
      perform pgmq.send('wali_promotions', jsonb_build_object(
        'schema_version', 1, 'promotion_id', promotion_id, 'release_id', release_row.id,
        'artifacts', (select jsonb_agg(jsonb_build_object(
          'role', link.role, 'digest', staged.digest, 'byte_count', staged.byte_count,
          'media_type', staged.media_type, 'source_bucket', 'processing-private',
          'source_path', staged.storage_path, 'destination_bucket', 'catalog-public',
          'destination_path', staged.storage_path
        ) order by link.sort_order, link.role)
          from wali.release_staged_artifacts link
          join wali.staged_artifacts staged on staged.digest = link.artifact_digest
          where link.release_id = release_row.id)
      ));
    end if;
    return jsonb_build_object('status', 'promotion_pending', 'promotion_id', promotion_id, 'retry_after_seconds', 2);
  end if;
  select string_agg(ra.role::text || ':' || ra.artifact_digest, ',' order by ra.sort_order, ra.role)
    into artifact_digest from wali.release_artifacts ra where ra.release_id = release_row.id;
  artifact_digest := encode(extensions.digest(artifact_digest, 'sha256'), 'hex');
  select * into key_row from wali.catalog_signing_keys k where k.status = 'active'
    and statement_timestamp() between k.valid_from and coalesce(k.valid_until, 'infinity')
    order by k.valid_from desc, k.key_id limit 1;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_SIGNING_KEY_UNAVAILABLE'; end if;
  select * into intent from wali.publication_intents p
   where p.actor_id = wali_edge_prepare_publication_v1.actor_id
     and p.idempotency_key = wali_edge_prepare_publication_v1.idempotency_key for update;
  if found and (intent.submission_id <> submission_row.id or intent.submission_revision <> expected_revision
    or intent.generation <> expected_generation or intent.wallpaper_revision <> expected_wallpaper_revision
    or intent.artifact_set_digest <> artifact_digest or intent.metadata_set_digest <> metadata_set_digest) then
    raise exception using errcode = 'P0001', message = 'WALI_IDEMPOTENCY_CONFLICT';
  end if;
  if not found then
    insert into wali.publication_intents (actor_id, idempotency_key, request_id, submission_id,
      release_id, wallpaper_id, submission_revision, generation, wallpaper_revision,
      artifact_set_digest, metadata_set_digest, signing_key_id, issued_at, expires_at)
    values (wali_edge_prepare_publication_v1.actor_id, wali_edge_prepare_publication_v1.idempotency_key,
      wali_edge_prepare_publication_v1.request_id, submission_row.id, release_row.id,
      wallpaper_row.id, expected_revision, expected_generation, expected_wallpaper_revision,
      artifact_digest, metadata_set_digest, key_row.key_id, date_trunc('second', statement_timestamp()),
      statement_timestamp() + interval '5 minutes') returning * into intent;
  elsif intent.expires_at <= statement_timestamp() or intent.signing_key_id <> key_row.key_id then
    update wali.publication_intents set request_id = wali_edge_prepare_publication_v1.request_id,
      signing_key_id = key_row.key_id, issued_at = date_trunc('second', statement_timestamp()),
      expires_at = statement_timestamp() + interval '5 minutes'
      where id = intent.id and consumed_at is null returning * into intent;
    if not found then raise exception using errcode = 'P0001', message = 'WALI_RELEASE_ALREADY_PUBLISHED'; end if;
  end if;
  return jsonb_build_object(
    'wallpaper_id', wallpaper_row.id, 'release_id', release_row.id, 'edition', release_row.edition,
    'issued_at', to_char(intent.issued_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'key_id', intent.signing_key_id,
    'public_key', translate(encode(key_row.public_key, 'base64'), E'+/=\n\r', '-_'),
    'title', submission_row.proposed_title,
    'creator', (select jsonb_build_object('id', p.id, 'handle', p.handle::text, 'display_name', p.display_name)
      from wali.profiles p where p.id = wallpaper_row.creator_id),
    'rights_holder', rights_row.rights_holder,
    'attribution', jsonb_build_object('text', coalesce(rights_row.attribution_text, ''),
      'source_url', coalesce(rights_row.source_url, ''),
      'license_code', (select l.code from wali.licenses l where l.id = rights_row.license_id)),
    'artifacts', (select jsonb_agg(jsonb_build_object(
      'role', ra.role, 'url', cfg.catalog_public_base_url || '/' || a.storage_path,
      'sha256', a.digest, 'byte_count', a.byte_count, 'media_type', a.media_type,
      'width', a.width, 'height', a.height, 'duration_ms', coalesce(a.duration_ms, 0)
    ) order by ra.sort_order, ra.role) from wali.release_artifacts ra
      join wali.artifacts a on a.digest = ra.artifact_digest
      cross join wali.runtime_configuration cfg where ra.release_id = release_row.id)
  );
end $$;
