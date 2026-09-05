-- Metadata corrections reuse only the current generation's verified media.
-- No media identifiers, ownership rules, review privileges, or submission
-- revision/generation checks change in this migration.
begin;

create or replace function wali.submission_has_verified_media(target_submission_id uuid, expected_generation integer)
returns boolean language plpgsql stable set search_path = '' as $$
declare attempt wali.processing_attempts%rowtype; claims jsonb;
begin
  select p.* into attempt from wali.processing_attempts p
    join wali.submissions s on s.id = p.submission_id and s.generation = p.generation
   where p.submission_id = target_submission_id and p.generation = expected_generation
     and p.status = 'completed';
  if not found then return false; end if;
  claims := attempt.output_summary -> 'artifacts';
  if jsonb_typeof(claims) is distinct from 'array' then return false; end if;
  if jsonb_array_length(claims) <> 4 then return false; end if;
  if (select array_agg(value ->> 'role' order by value ->> 'role') from jsonb_array_elements(claims))
       is distinct from array['poster','preview','thumbnail','video_default']::text[] then
    return false;
  end if;
  return not exists (
    select 1 from jsonb_array_elements(claims) claim
     where not exists (
       select 1 from wali.wallpaper_releases release
       join wali.release_staged_artifacts link on link.release_id = release.id
       join wali.staged_artifacts artifact on artifact.digest = link.artifact_digest
       join storage.objects object on object.bucket_id = artifact.storage_bucket and object.name = artifact.storage_path
        where release.source_submission_id = target_submission_id
          and link.role::text = claim ->> 'role' and artifact.digest = claim ->> 'digest'
          and artifact.byte_count = (claim ->> 'byte_count')::bigint
          and artifact.media_type = claim ->> 'media_type'
          and not coalesce(object.is_delete_marker, false)
          and coalesce((object.metadata ->> 'size')::bigint, 0) = artifact.byte_count
     )
  );
end $$;
revoke all on function wali.submission_has_verified_media(uuid, integer) from public, anon, authenticated;


create or replace function wali.submission_transition_allowed(
  old_status wali.submission_status,
  new_status wali.submission_status
) returns boolean
language sql
immutable
set search_path = ''
as $$
  select (old_status, new_status) in (
    ('draft', 'uploading'), ('draft', 'withdrawn'),
    ('uploading', 'uploaded'), ('uploading', 'withdrawn'),
    ('uploaded', 'processing'), ('uploaded', 'withdrawn'),
    ('processing', 'ready_for_submission'), ('processing', 'processing_failed'),
    ('processing_failed', 'processing'), ('processing_failed', 'withdrawn'),
    ('ready_for_submission', 'submitted'), ('ready_for_submission', 'withdrawn'),
    ('submitted', 'under_review'),
    ('under_review', 'changes_requested'), ('under_review', 'approved'), ('under_review', 'rejected'),
    ('changes_requested', 'draft'), ('changes_requested', 'ready_for_submission'), ('changes_requested', 'withdrawn'),
    ('approved', 'published')
  )
$$;

create or replace function public.wali_edge_save_submission_draft_v1(
  actor_id uuid, request_id uuid, idempotency_key text, submission_id uuid, expected_revision bigint,
  title text, description text, primary_category_id uuid, suggested_tag_ids uuid[], content_warning text,
  rights_basis wali.rights_basis, rights_holder text, license_id uuid, source_url text,
  attribution_text text, proof_object_ids uuid[], attests_rights boolean, creator_terms_version text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; current_row wali.submissions%rowtype; target_status wali.submission_status;
  license_row wali.licenses%rowtype; response jsonb;
begin
  if auth.role() <> 'service_role' then raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED'; end if;
  if not wali.edge_actor_has_role(actor_id, 'creator') then raise exception using errcode = 'P0001', message = 'WALI_CREATOR_ROLE_REQUIRED'; end if;
  -- Licensed/other declarations stay closed until every proof object is issued,
  -- scanned, observed and bound to this submission. UUIDs alone are not proof.
  if rights_basis in ('licensed', 'other') or cardinality(proof_object_ids) <> 0 then
    raise exception using errcode = 'P0001', message = 'WALI_RIGHTS_WORKFLOW_UNAVAILABLE';
  end if;
  if creator_terms_version is distinct from (select cfg.creator_terms_version from wali.runtime_configuration cfg where cfg.singleton)
     or not exists (select 1 from wali.terms_acceptances t where t.user_id = actor_id and t.document_kind = 'creator_terms' and t.document_version = creator_terms_version) then
    raise exception using errcode = 'P0001', message = 'WALI_CREATOR_TERMS_REQUIRED';
  end if;
  select * into license_row from wali.licenses license where license.id = license_id and license.active;
  if not found or not attests_rights or not wali.plain_text_is_valid(title, 1, 120)
     or not wali.plain_text_is_valid(description, 1, 2000)
     or not wali.plain_text_is_valid(rights_holder, 1, 160)
     or (content_warning is not null and not wali.plain_text_is_valid(content_warning, 1, 500))
     or (attribution_text is not null and not wali.plain_text_is_valid(attribution_text, 1, 1000))
     or not wali.https_url_is_valid(source_url)
     or not exists (select 1 from wali.categories c where c.id = primary_category_id and c.active)
     or cardinality(suggested_tag_ids) not between 0 and 20
     or cardinality(suggested_tag_ids) <> (select count(distinct tag_id) from unnest(suggested_tag_ids) tag_id)
     or exists (select 1 from unnest(suggested_tag_ids) tag_id where not exists (select 1 from wali.tags t where t.id = tag_id and t.active))
     or (license_row.attribution_required and attribution_text is null)
     or (rights_basis in ('licensed', 'public_domain') and source_url is null)
     then
    raise exception using errcode = 'P0001', message = 'WALI_RIGHTS_INCOMPLETE';
  end if;
  request_hash := encode(extensions.digest(jsonb_build_object(
    'submission_id', submission_id, 'expected_revision', expected_revision, 'title', title,
    'description', description, 'primary_category_id', primary_category_id,
    'suggested_tag_ids', suggested_tag_ids, 'content_warning', content_warning,
    'rights_basis', rights_basis, 'rights_holder', rights_holder, 'license_id', license_id,
    'source_url', source_url, 'attribution_text', attribution_text, 'proof_object_ids', proof_object_ids,
    'attests_rights', attests_rights, 'creator_terms_version', creator_terms_version
  )::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'save_submission_draft', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select * into current_row from wali.submissions s where s.id = submission_id and s.creator_id = actor_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_FOUND'; end if;
  if current_row.revision <> expected_revision then raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH'; end if;
  if current_row.status not in ('draft', 'ready_for_submission', 'changes_requested') then
    raise exception using errcode = 'P0001', message = 'WALI_INVALID_TRANSITION';
  end if;
  target_status := current_row.status;
  if current_row.status = 'changes_requested' then
    if not wali.submission_has_verified_media(current_row.id, current_row.generation) then
      raise exception using errcode = 'P0001', message = 'WALI_SUBMISSION_NOT_READY';
    end if;
    target_status := 'ready_for_submission';
  end if;
  update wali.submissions set proposed_title = wali_edge_save_submission_draft_v1.title,
    proposed_description = wali_edge_save_submission_draft_v1.description,
    primary_category_id = wali_edge_save_submission_draft_v1.primary_category_id,
    license_id = wali_edge_save_submission_draft_v1.license_id,
    rights_holder = wali_edge_save_submission_draft_v1.rights_holder,
    attribution_text = wali_edge_save_submission_draft_v1.attribution_text,
    source_url = wali_edge_save_submission_draft_v1.source_url,
    content_warning = wali_edge_save_submission_draft_v1.content_warning,
    status = target_status where id = current_row.id returning * into current_row;
  insert into wali.rights_declarations (submission_id, basis, rights_holder, license_id, source_url,
    attribution_text, proof_object_ids, attested_at, creator_terms_version)
  values (current_row.id, rights_basis, rights_holder, license_id, source_url, attribution_text,
    proof_object_ids, statement_timestamp(), creator_terms_version)
  on conflict on constraint rights_declarations_submission_id_key do update set basis = excluded.basis, rights_holder = excluded.rights_holder,
    license_id = excluded.license_id, source_url = excluded.source_url, attribution_text = excluded.attribution_text,
    proof_object_ids = excluded.proof_object_ids, attested_at = excluded.attested_at,
    creator_terms_version = excluded.creator_terms_version, review_status = 'pending',
    reviewed_by = null, reviewed_at = null;
  delete from wali.submission_tag_suggestions suggestion
   where suggestion.submission_id = current_row.id and suggestion.source = 'creator';
  insert into wali.submission_tag_suggestions (submission_id, tag_id, source)
  select current_row.id, tag_id, 'creator'::wali.taxonomy_source from unnest(suggested_tag_ids) tag_id;
  response := jsonb_build_object('submission_id', current_row.id, 'revision', current_row.revision,
    'generation', current_row.generation, 'state', current_row.status, 'field_errors', '[]'::jsonb);
  perform wali.complete_command(actor_id, 'save_submission_draft', idempotency_key, response);
  return response;
end $$;


-- Recover only previously reviewed drafts stranded by the old Save transition.
-- The review must postdate completion of this exact generation; fresh drafts,
-- rejected/withdrawn/published submissions and incomplete media are excluded.
update wali.submissions submission
   set status = 'changes_requested'
 where submission.status = 'draft' and submission.submitted_at is not null
   and wali.submission_has_verified_media(submission.id, submission.generation)
   and exists (
     select 1 from wali.processing_attempts attempt
     join lateral (
       select review.decision, review.created_at from wali.moderation_reviews review
        where review.submission_id = submission.id
        order by review.created_at desc, review.id desc limit 1
     ) latest_review on true
      where attempt.submission_id = submission.id and attempt.generation = submission.generation
        and attempt.status = 'completed' and latest_review.decision = 'changes_requested'
        and latest_review.created_at >= attempt.finished_at
   );

commit;
