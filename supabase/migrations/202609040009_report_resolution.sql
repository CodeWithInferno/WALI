-- Report decisions use real revisions and the existing audited command boundary.
-- Policy actions change catalog visibility; they never issue technical revocations.
alter table wali.reports add column revision bigint not null default 1
  check (revision between 1 and 9007199254740991);

-- Full review video remains private after publication. An open report grants
-- eligible staff access to that report's exact edition, including hidden media.
create or replace function wali.moderator_can_preview_canonical(
  object_bucket text, object_path text
) returns boolean language sql stable security definer set search_path = '' as $$
  select object_bucket = 'processing-private'
    and auth.uid() is not null and wali.current_aal() = 'aal2'
    and exists (select 1 from wali.profiles profile
      where profile.id = auth.uid() and profile.status = 'active')
    and (wali.edge_actor_has_role(auth.uid(), 'moderator') or wali.edge_actor_has_role(auth.uid(), 'admin'))
    and exists (
      select 1 from wali.staged_artifacts staged
      join wali.release_staged_artifacts link on link.artifact_digest = staged.digest
      join wali.wallpaper_releases release on release.id = link.release_id
      join wali.submissions submission on submission.id = release.source_submission_id
      join wali.processing_attempts attempt on attempt.id = staged.verified_by_attempt_id
      where staged.storage_path = object_path and attempt.submission_id = submission.id
        and (
          (submission.status in ('submitted', 'under_review', 'approved') and attempt.generation = submission.generation)
          or exists (
            select 1 from wali.reports report
            join wali.wallpapers wallpaper on wallpaper.id = report.wallpaper_id
            where report.wallpaper_id = release.wallpaper_id
              and coalesce(report.release_id, wallpaper.current_release_id) = release.id
              and report.status in ('open', 'triaged', 'appealed')
              and wallpaper.creator_id <> auth.uid() and report.reporter_id is distinct from auth.uid()
              and (report.assigned_moderator_id is null or report.assigned_moderator_id = auth.uid()
                or wali.edge_actor_has_role(auth.uid(), 'admin'))
          )
        )
    )
$$;

create or replace function public.moderation_reports_v1(
  actor_id uuid, actor_aal text, cursor text default null, page_limit integer default 24
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare cursor_id uuid; cursor_time timestamptz; items jsonb; next_cursor text; is_admin boolean;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  is_admin := wali.edge_actor_has_role(actor_id, 'admin');
  if actor_aal is distinct from 'aal2' or not exists (select 1 from wali.profiles profile
       where profile.id = actor_id and profile.status = 'active')
     or not (wali.edge_actor_has_role(actor_id, 'moderator') or is_admin) then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATOR_AAL2_REQUIRED';
  end if;
  if page_limit is null or page_limit not between 1 and 50 then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  if cursor is not null then
    begin cursor_id := cursor::uuid; exception when others then
      raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end;
    select report.created_at into cursor_time from wali.reports report where report.id = cursor_id;
    if not found then raise exception using errcode = 'P0001', message = 'WALI_CURSOR_INVALID'; end if;
  end if;
  with page as (
    select report.* from wali.reports report
    join wali.wallpapers wallpaper on wallpaper.id = report.wallpaper_id
    where report.status in ('open', 'triaged', 'appealed')
      and (report.assigned_moderator_id is null or report.assigned_moderator_id = actor_id or is_admin)
      and wallpaper.creator_id <> actor_id and report.reporter_id is distinct from actor_id
      and (cursor_id is null or (report.created_at, report.id) > (cursor_time, cursor_id))
    order by report.created_at, report.id limit page_limit
  ), projected as (
    select page.id, page.created_at, jsonb_build_object(
      'report_id', page.id, 'revision', page.revision, 'reason_code', page.kind,
      'safe_summary', page.detail, 'status', page.status,
      'wallpaper_id', wallpaper.id, 'wallpaper_revision', wallpaper.revision,
      'wallpaper_title', wallpaper.title, 'wallpaper_status', wallpaper.status,
      'release_id', release.id, 'edition', release.edition,
      'canonical_artifacts', coalesce(artifacts.items, '[]'::jsonb),
      'created_at', to_char(page.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ) as item
    from page join wali.wallpapers wallpaper on wallpaper.id = page.wallpaper_id
    left join wali.wallpaper_releases release
      on release.id = coalesce(page.release_id, wallpaper.current_release_id)
        and release.wallpaper_id = wallpaper.id
    left join lateral (select jsonb_agg(jsonb_build_object(
      'role', link.role, 'storage_path', staged.storage_path,
      'sha256', staged.digest, 'byte_count', staged.byte_count,
      'media_type', staged.media_type, 'width', staged.width, 'height', staged.height,
      'duration_ms', coalesce(staged.duration_ms, 0)
    ) order by link.sort_order, link.role) as items
      from wali.release_staged_artifacts link
      join wali.staged_artifacts staged on staged.digest = link.artifact_digest
      join wali.processing_attempts verified on verified.id = staged.verified_by_attempt_id
      where link.release_id = release.id
        and link.role in ('poster', 'preview', 'video_default')
        and verified.submission_id = release.source_submission_id) artifacts on true
  ) select coalesce(jsonb_agg(item order by created_at, id), '[]'::jsonb),
      case when count(*) = page_limit then (array_agg(id order by created_at, id))[count(*)]::text else null end
    into items, next_cursor from projected;
  return jsonb_build_object('items', items, 'next_cursor', next_cursor);
end $$;

create or replace function public.wali_edge_resolve_report_v1(
  actor_id uuid, actor_aal text, request_id uuid, idempotency_key text,
  report_id uuid, expected_revision bigint, expected_wallpaper_revision bigint,
  resolution_action text, reason_code text, private_note text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare request_hash text; replay jsonb; response jsonb;
  report_row wali.reports%rowtype; wallpaper_row wali.wallpapers%rowtype;
  prior_status wali.wallpaper_status; is_admin boolean;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = 'P0001', message = 'WALI_SERVICE_ROLE_REQUIRED';
  end if;
  is_admin := wali.edge_actor_has_role(actor_id, 'admin');
  if actor_aal is distinct from 'aal2' or not exists (select 1 from wali.profiles profile
       where profile.id = actor_id and profile.status = 'active')
     or not (wali.edge_actor_has_role(actor_id, 'moderator') or is_admin) then
    raise exception using errcode = 'P0001', message = 'WALI_MODERATOR_AAL2_REQUIRED';
  end if;
  if request_id is null or report_id is null
     or expected_revision is null or expected_revision not between 1 and 9007199254740990
     or expected_wallpaper_revision is null or expected_wallpaper_revision not between 1 and 9007199254740990
     or resolution_action is null or resolution_action not in ('close_no_action', 'hide_pending_review', 'delist')
     or reason_code is null or reason_code not in ('no_violation', 'copyright', 'impersonation', 'unsafe', 'sexual', 'hate', 'violence', 'spam', 'misleading', 'other')
     or ((resolution_action = 'close_no_action') <> (reason_code = 'no_violation'))
     or not wali.plain_text_is_valid(private_note, 1, 2000) then
    raise exception using errcode = 'P0001', message = 'WALI_REQUEST_INVALID';
  end if;
  request_hash := encode(extensions.digest(jsonb_build_object(
    'report_id', report_id, 'expected_revision', expected_revision,
    'expected_wallpaper_revision', expected_wallpaper_revision,
    'action', resolution_action, 'reason_code', reason_code, 'private_note', private_note
  )::text, 'sha256'), 'hex');
  replay := wali.reserve_command(actor_id, 'resolve_report', idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select * into report_row from wali.reports report where report.id = report_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'WALI_REPORT_NOT_FOUND'; end if;
  select * into wallpaper_row from wali.wallpapers wallpaper where wallpaper.id = report_row.wallpaper_id for update;
  if report_row.reporter_id = actor_id or wallpaper_row.creator_id = actor_id then
    raise exception using errcode = 'P0001', message = 'WALI_SELF_REVIEW_FORBIDDEN';
  end if;
  if report_row.assigned_moderator_id is not null and report_row.assigned_moderator_id <> actor_id and not is_admin then
    raise exception using errcode = 'P0001', message = 'WALI_REPORT_ASSIGNED_ELSEWHERE';
  end if;
  if report_row.revision <> expected_revision or wallpaper_row.revision <> expected_wallpaper_revision
     or report_row.status not in ('open', 'triaged', 'appealed') then
    raise exception using errcode = 'P0001', message = 'WALI_REVISION_MISMATCH';
  end if;
  prior_status := wallpaper_row.status;
  if resolution_action = 'hide_pending_review' and wallpaper_row.status = 'published' then
    update wali.wallpapers set status = 'hidden' where id = wallpaper_row.id returning * into wallpaper_row;
  elsif resolution_action = 'delist' and wallpaper_row.status <> 'removed' then
    update wali.wallpapers set status = 'removed', removed_at = statement_timestamp()
      where id = wallpaper_row.id returning * into wallpaper_row;
  end if;
  update wali.reports set
    status = case when resolution_action = 'hide_pending_review' then 'triaged'::wali.case_status else 'closed'::wali.case_status end,
    assigned_moderator_id = actor_id,
    resolution_code = case when resolution_action <> 'hide_pending_review' then reason_code else null end,
    resolved_at = case when resolution_action <> 'hide_pending_review' then statement_timestamp() else null end
    where id = report_row.id returning * into report_row;
  insert into wali.moderation_actions (actor_id, action, target_type, target_id, reason_code, request_id, metadata)
    values (actor_id, 'report.' || resolution_action, 'report', report_row.id, reason_code, request_id,
      jsonb_build_object('report_revision', report_row.revision, 'wallpaper_id', wallpaper_row.id,
        'wallpaper_revision', wallpaper_row.revision, 'previous_wallpaper_status', prior_status,
        'wallpaper_status', wallpaper_row.status, 'private_note', private_note));
  insert into wali.audit_events (actor_id, action, target_type, target_id, request_id, metadata)
    values (actor_id, 'moderation.report.' || resolution_action, 'report', report_row.id, request_id,
      jsonb_build_object('report_revision', report_row.revision, 'wallpaper_id', wallpaper_row.id,
        'wallpaper_revision', wallpaper_row.revision, 'reason_code', reason_code));
  response := jsonb_build_object('report_id', report_row.id, 'revision', report_row.revision,
    'status', report_row.status, 'action', resolution_action, 'wallpaper_id', wallpaper_row.id,
    'wallpaper_revision', wallpaper_row.revision, 'wallpaper_status', wallpaper_row.status);
  perform wali.complete_command(actor_id, 'resolve_report', idempotency_key, response);
  return response;
end $$;

revoke execute on function public.wali_edge_resolve_report_v1(uuid, text, uuid, text, uuid, bigint, bigint, text, text, text) from public, anon, authenticated;
grant execute on function public.wali_edge_resolve_report_v1(uuid, text, uuid, text, uuid, bigint, bigint, text, text, text) to service_role;
