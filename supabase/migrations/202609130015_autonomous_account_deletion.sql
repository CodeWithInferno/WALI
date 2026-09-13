-- ADR0029. Inert until the separate scheduler credential is explicitly installed.
begin;
alter table wali.runtime_configuration add column automatic_account_deletion_enabled boolean not null default false;

create table wali.account_deletion_finalization_jobs (
 id uuid primary key default gen_random_uuid(),
 deletion_id uuid not null unique references wali.account_deletion_requests(id) on delete restrict,
 policy_version text not null check(policy_version='2026-09-13'),
 stage text not null default 'cleanup' check(stage in('cleanup','held','apple_revocation','identity_deletion','retrying','completed')),
 revision bigint not null default 1 check(revision between 1 and 9007199254740991),
 run_token uuid, lease_token uuid, lease_expires_at timestamptz,
 attempts integer not null default 0 check(attempts>=0),
 next_attempt_at timestamptz not null default statement_timestamp(),
 safe_error_code text check(safe_error_code ~ '^WALI_[A-Z0-9_]{2,96}$'),
 authorized_at timestamptz, identity_authorized_at timestamptz,
 apple_required_clients text[] not null default '{}', apple_revoked_clients text[] not null default '{}',
 apple_action_required boolean not null default false,
 retained_categories text[] not null default '{}',
 created_at timestamptz not null default statement_timestamp(), completed_at timestamptz,
 check(cardinality(apple_required_clients)<=2 and cardinality(apple_revoked_clients)<=2),
 check((lease_token is null)=(lease_expires_at is null)),
 check((stage='completed')=(completed_at is not null))
);
create index account_deletion_jobs_due on wali.account_deletion_finalization_jobs(next_attempt_at,id) where completed_at is null;
create table wali.account_deletion_status_receipts (
 capability_hash text primary key check(capability_hash ~ '^[0-9a-f]{64}$'),
 job_id uuid not null unique references wali.account_deletion_finalization_jobs(id) on delete restrict,
 status_expires_at timestamptz,
 check_window timestamptz not null default statement_timestamp(), checks integer not null default 0 check(checks between 0 and 120)
);
create table wali.account_deletion_dispatch_state (
 singleton boolean primary key default true check(singleton), run_token uuid,
 lease_expires_at timestamptz, last_started_at timestamptz,
 check((run_token is null)=(lease_expires_at is null))
);
insert into wali.account_deletion_dispatch_state(singleton) values(true);

-- A durable deletion fence is separate from the transient worker intent, which
-- existing retention may remove. Immutable signed release records are preserved.
create table wali.account_deletion_object_intents (
 deletion_id uuid not null references wali.account_deletion_requests(id) on delete restrict,
 bucket_id text not null check(bucket_id in('catalog-public','processing-private')),
 storage_path text not null, digest text not null check(digest ~ '^[0-9a-f]{64}$'),
 owned_release_ids uuid[] not null default '{}', reference_revision bigint not null default 1,
 cleanup_id uuid, disposition text not null check(disposition in('queued','shared_reference','completed')),
 completed_at timestamptz,
 primary key(deletion_id,bucket_id,storage_path),
 check(storage_path ~ ('^sha256/'||substr(digest,1,2)||'/'||substr(digest,3,2)||'/'||digest||'/[a-z0-9_-]+[.](jpg|jpeg|png|mp4)$')),
 check((disposition='completed')=(completed_at is not null))
);
create index account_deletion_objects_fence on wali.account_deletion_object_intents(digest,bucket_id,disposition);
alter table wali.cleanup_object_intents drop constraint cleanup_object_intents_bucket_id_check;
alter table wali.cleanup_object_intents add constraint cleanup_object_intents_bucket_id_check
 check(bucket_id in('uploads-private','exports-private','processing-private','moderation-private','catalog-public'));

alter table wali.account_deletion_finalization_jobs enable row level security;
alter table wali.account_deletion_status_receipts enable row level security;
alter table wali.account_deletion_dispatch_state enable row level security;
alter table wali.account_deletion_object_intents enable row level security;
revoke all on wali.account_deletion_finalization_jobs,wali.account_deletion_status_receipts,
 wali.account_deletion_dispatch_state,wali.account_deletion_object_intents from public,anon,authenticated,service_role,wali_worker,wali_storage_worker;

create function wali.require_deletion_service() returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
begin
 if auth.role() is distinct from 'service_role' then raise exception using errcode='P0001',message='WALI_SERVICE_ROLE_REQUIRED'; end if;
end $$;
create function wali.account_deletion_has_hold(actor uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wali.copyright_cases c join wali.wallpapers w on w.id=c.target_wallpaper_id
 where w.creator_id=actor and c.status in('open','triaged','appealed'))
$$;
create function wali.lock_deletion_digest(digest text) returns void language sql volatile security definer set search_path='' as $$
 select pg_advisory_xact_lock(hashtextextended('account-object-deletion:'||digest,0))
$$;
create function wali.account_deletion_targets(actor uuid)
 returns table(bucket_id text,storage_path text,digest text,owned_release_ids uuid[])
 language sql stable security definer set search_path='' as $$
 select a.storage_bucket,a.storage_path,a.digest,array_agg(distinct r.id order by r.id)
 from wali.artifacts a join wali.release_artifacts l on l.artifact_digest=a.digest
 join wali.wallpaper_releases r on r.id=l.release_id join wali.wallpapers w on w.id=r.wallpaper_id
 where w.creator_id=actor group by a.storage_bucket,a.storage_path,a.digest
 union all
 select 'processing-private',a.storage_path,a.digest,
 coalesce(array_agg(distinct l.release_id order by l.release_id) filter(where l.release_id is not null and exists(
  select 1 from wali.wallpaper_releases r join wali.wallpapers w on w.id=r.wallpaper_id where r.id=l.release_id and w.creator_id=actor)),'{}'::uuid[])
 from wali.staged_artifacts a join wali.processing_attempts p on p.id=a.verified_by_attempt_id
 join wali.submissions s on s.id=p.submission_id left join wali.release_staged_artifacts l on l.artifact_digest=a.digest
 where s.creator_id=actor or exists(select 1 from wali.release_staged_artifacts x join wali.wallpaper_releases r on r.id=x.release_id
  join wali.wallpapers w on w.id=r.wallpaper_id where x.artifact_digest=a.digest and w.creator_id=actor)
 group by a.storage_path,a.digest
$$;
create function wali.deletion_object_has_other_reference(digest text,actor uuid) returns boolean
 language sql stable security definer set search_path='' as $$
 select exists(select 1 from wali.wallpaper_releases r join wali.wallpapers w on w.id=r.wallpaper_id
 join wali.profiles p on p.id=w.creator_id
 where w.creator_id<>actor and p.status<>'deleted'
 and not exists(select 1 from wali.account_deletion_requests d join wali.account_deletion_finalization_jobs j on j.deletion_id=d.id
  where d.user_id=w.creator_id and d.sessions_revoked_at is not null and d.status<>'cancelled') and (
 exists(select 1 from wali.release_artifacts a where a.release_id=r.id and a.artifact_digest=deletion_object_has_other_reference.digest)
 or exists(select 1 from wali.release_staged_artifacts a where a.release_id=r.id and a.artifact_digest=deletion_object_has_other_reference.digest)))
 or exists(select 1 from wali.staged_artifacts a join wali.processing_attempts p on p.id=a.verified_by_attempt_id
 join wali.submissions s on s.id=p.submission_id join wali.profiles u on u.id=s.creator_id
 where a.digest=deletion_object_has_other_reference.digest and s.creator_id<>actor and u.status<>'deleted'
 and not exists(select 1 from wali.account_deletion_requests d join wali.account_deletion_finalization_jobs j on j.deletion_id=d.id
  where d.user_id=s.creator_id and d.sessions_revoked_at is not null and d.status<>'cancelled'))
$$;

create function wali.account_deletion_object_removable(bucket text,digest text,actor uuid) returns boolean
 language sql stable security definer set search_path='' as $$
 select not wali.deletion_object_has_other_reference(digest,actor) and (
  not (wali.account_deletion_has_hold(actor) or exists(select 1 from wali.copyright_cases c join wali.wallpaper_releases r on r.wallpaper_id=c.target_wallpaper_id
   where c.status in('open','triaged','appealed') and (exists(select 1 from wali.release_artifacts a where a.release_id=r.id and a.artifact_digest=digest)
    or exists(select 1 from wali.release_staged_artifacts a where a.release_id=r.id and a.artifact_digest=digest)))) or (bucket='catalog-public' and exists(
   select 1 from wali.staged_artifacts a join storage.objects o on o.bucket_id='processing-private' and o.name=a.storage_path
   where a.digest=account_deletion_object_removable.digest and not coalesce(o.is_delete_marker,false))))
$$;

create function wali.prepare_account_object_cleanup(deletion_id uuid,actor uuid) returns boolean
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare target record; cleanup uuid; shared boolean; remaining boolean;
begin
 -- The caller holds the exact profile and consented request locks. No arbitrary
 -- external bucket/path can enter this projection. Process bounded pages.
 for target in select t.* from wali.account_deletion_targets(actor) t
  left join wali.account_deletion_object_intents i on i.deletion_id=prepare_account_object_cleanup.deletion_id
   and i.bucket_id=t.bucket_id and i.storage_path=t.storage_path
  where i.deletion_id is null or i.disposition<>'completed' order by t.digest,t.bucket_id limit 100
 loop
  perform wali.lock_deletion_digest(target.digest);
  shared:=wali.deletion_object_has_other_reference(target.digest,actor);
  if shared then
   insert into wali.account_deletion_object_intents(deletion_id,bucket_id,storage_path,digest,owned_release_ids,disposition)
    values(deletion_id,target.bucket_id,target.storage_path,target.digest,target.owned_release_ids,'shared_reference')
    on conflict on constraint account_deletion_object_intents_pkey do update set disposition='shared_reference',completed_at=null;
   continue;
  end if;
  if not exists(select 1 from storage.objects o where o.bucket_id=target.bucket_id and o.name=target.storage_path and not coalesce(o.is_delete_marker,false)) then
   insert into wali.account_deletion_object_intents(deletion_id,bucket_id,storage_path,digest,owned_release_ids,disposition,completed_at)
    values(deletion_id,target.bucket_id,target.storage_path,target.digest,target.owned_release_ids,'completed',statement_timestamp())
    on conflict on constraint account_deletion_object_intents_pkey do update set disposition='completed',completed_at=coalesce(wali.account_deletion_object_intents.completed_at,excluded.completed_at);
   continue;
  end if;
  -- A public copy is removable during a hold only when verified canonical
  -- evidence still exists privately. Otherwise report held, never fake erasure.
  if not wali.account_deletion_object_removable(target.bucket_id,target.digest,actor) then continue; end if;
  insert into wali.cleanup_object_intents(bucket_id,storage_path,reason)
   values(target.bucket_id,target.storage_path,'account_deletion')
   on conflict(bucket_id,storage_path) do update set status='queued',lease_owner=null,lease_expires_at=null,completed_at=null,safe_error_code=null,reason='account_deletion'
    where wali.cleanup_object_intents.status in('completed','failed') returning id into cleanup;
  if cleanup is null then select c.id into cleanup from wali.cleanup_object_intents c where c.bucket_id=target.bucket_id and c.storage_path=target.storage_path; end if;
  insert into wali.account_deletion_object_intents(deletion_id,bucket_id,storage_path,digest,owned_release_ids,cleanup_id,disposition)
   values(deletion_id,target.bucket_id,target.storage_path,target.digest,target.owned_release_ids,cleanup,'queued')
   on conflict on constraint account_deletion_object_intents_pkey do update set cleanup_id=excluded.cleanup_id,disposition='queued',completed_at=null;
  if not exists(select 1 from pgmq.q_wali_cleanup q where q.message->>'cleanup_id'=cleanup::text) then
   perform pgmq.send('wali_cleanup',jsonb_build_object('schema_version',1,'kind','storage_object','cleanup_id',cleanup));
  end if;
 end loop;
 select exists(select 1 from wali.account_deletion_targets(actor) t
  left join wali.account_deletion_object_intents i on i.deletion_id=prepare_account_object_cleanup.deletion_id and i.bucket_id=t.bucket_id and i.storage_path=t.storage_path
  where i.disposition is distinct from 'completed') into remaining;
 return not remaining;
end $$;

create function wali.guard_deleted_artifact_reference() returns trigger language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare creator uuid;
begin
 select w.creator_id into creator from wali.wallpaper_releases r join wali.wallpapers w on w.id=r.wallpaper_id where r.id=new.release_id;
 perform 1 from wali.profiles p where p.id=creator and p.status='active' for update;
 if not found then raise exception using errcode='P0001',message='WALI_ACCOUNT_INACTIVE'; end if;
 perform wali.lock_deletion_digest(new.artifact_digest);
 if exists(select 1 from wali.account_deletion_object_intents i where i.digest=new.artifact_digest and i.disposition in('queued','completed')) then
  raise exception using errcode='P0001',message='WALI_ARTIFACT_DELETION_FENCED'; end if;
 return new;
end $$;
create trigger release_artifact_deletion_fence before insert or update on wali.release_artifacts for each row execute function wali.guard_deleted_artifact_reference();
create trigger staged_release_deletion_fence before insert or update on wali.release_staged_artifacts for each row execute function wali.guard_deleted_artifact_reference();

create function public.wali_edge_request_account_deletion_v2(actor_id uuid,actor_aal text,request_id uuid,idempotency_key text,
 expected_profile_revision bigint,status_capability_hash text,policy_version text) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare replay jsonb; response jsonb; profile_row wali.profiles%rowtype; deletion uuid; job uuid; request_hash text;
begin
 perform wali.require_deletion_service();
 if actor_aal is distinct from 'aal2' then raise exception using errcode='P0001',message='WALI_ADMIN_AAL2_REQUIRED'; end if;
 if not exists(select 1 from wali.runtime_configuration c where c.singleton and c.automatic_account_deletion_enabled) then
  raise exception using errcode='P0001',message='WALI_DELETION_AUTOMATION_UNAVAILABLE'; end if;
 if actor_id is null or request_id is null or expected_profile_revision is null or expected_profile_revision<1
  or policy_version is distinct from '2026-09-13' or status_capability_hash is null or status_capability_hash !~ '^[0-9a-f]{64}$' then
  raise exception using errcode='P0001',message='WALI_REQUEST_INVALID'; end if;
 request_hash:=encode(extensions.digest(actor_id::text||':'||request_id::text||':'||expected_profile_revision::text||':'||status_capability_hash||':'||policy_version,'sha256'),'hex');
 replay:=wali.reserve_command(actor_id,'account_deletion_v2',idempotency_key,request_hash); if replay is not null then return replay; end if;
 select * into profile_row from wali.profiles p where p.id=actor_id for update;
 if not found or profile_row.status<>'active' then raise exception using errcode='P0001',message='WALI_ACCOUNT_INACTIVE'; end if;
 if profile_row.revision<>expected_profile_revision then raise exception using errcode='P0001',message='WALI_REVISION_MISMATCH'; end if;
 insert into wali.account_deletion_requests(user_id,request_id) values(actor_id,request_id) returning id into deletion;
 insert into wali.account_deletion_finalization_jobs(deletion_id,policy_version,retained_categories)
  values(deletion,policy_version,array['deletion_audit']||case when exists(select 1 from wali.submissions s where s.creator_id=actor_id)
   then array['publication_rights_evidence'] else '{}'::text[] end) returning id into job;
 insert into wali.account_deletion_status_receipts(capability_hash,job_id) values(status_capability_hash,job);
 update wali.profiles set status='deletion_pending' where id=actor_id returning * into profile_row;
 update wali.role_grants set revoked_by=actor_id,revoked_at=statement_timestamp(),reason='account deletion requested' where user_id=actor_id and revoked_at is null;
 perform pgmq.send('wali_account_deletions',jsonb_build_object('schema_version',1,'deletion_id',deletion,'user_id',actor_id));
 response:=jsonb_build_object('deletion_id',deletion,'status','deletion_pending','revision',profile_row.revision,
  'requested_at',to_char(statement_timestamp() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
 perform wali.complete_command(actor_id,'account_deletion_v2',idempotency_key,response); return response;
end $$;

create function public.wali_edge_begin_account_deletion_dispatch_v1() returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare state wali.account_deletion_dispatch_state%rowtype; token uuid; admitted_at timestamptz;
begin
 perform wali.require_deletion_service();
 select * into state from wali.account_deletion_dispatch_state where singleton for update;
 admitted_at:=clock_timestamp();
 if not exists(select 1 from wali.runtime_configuration c where c.singleton and c.automatic_account_deletion_enabled)
  or state.lease_expires_at>admitted_at or state.last_started_at>admitted_at-interval '1 minute' then
  return jsonb_build_object('run_token',null); end if;
 token:=gen_random_uuid(); update wali.account_deletion_dispatch_state set run_token=token,lease_expires_at=admitted_at+interval '60 seconds',last_started_at=admitted_at where singleton;
 return jsonb_build_object('run_token',token);
end $$;
create function public.wali_edge_end_account_deletion_dispatch_v1(run_token uuid) returns boolean
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
begin
 perform wali.require_deletion_service();
 update wali.account_deletion_dispatch_state s set run_token=null,lease_expires_at=null where s.singleton and s.run_token=wali_edge_end_account_deletion_dispatch_v1.run_token;
 return found;
end $$;

create function wali.require_account_deletion_lease(run_token uuid,job_id uuid,lease_token uuid,expected_revision bigint)
 returns wali.account_deletion_finalization_jobs language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare job wali.account_deletion_finalization_jobs%rowtype; actor uuid; state wali.account_deletion_dispatch_state%rowtype; checked_at timestamptz;
begin
 perform wali.require_deletion_service();
 if not exists(select 1 from wali.account_deletion_dispatch_state s where s.run_token=require_account_deletion_lease.run_token and s.lease_expires_at>clock_timestamp()) then
  raise exception using errcode='P0001',message='WALI_DELETION_LEASE_INVALID'; end if;
 select d.user_id into actor from wali.account_deletion_finalization_jobs j join wali.account_deletion_requests d on d.id=j.deletion_id where j.id=job_id;
 perform 1 from wali.profiles p where p.id=actor for update;
 perform 1 from wali.account_deletion_requests d join wali.account_deletion_finalization_jobs j on j.deletion_id=d.id where j.id=job_id for update of d;
 select * into job from wali.account_deletion_finalization_jobs j where j.id=job_id for update;
 -- A lock wait may outlive either lease. Recheck the live clock after every
 -- authority row is locked; the shared run lock also fences end/replacement.
 select * into state from wali.account_deletion_dispatch_state where singleton for share;
 checked_at:=clock_timestamp();
 if state.run_token is distinct from run_token or state.lease_expires_at is null or state.lease_expires_at<=checked_at
  or job.id is null or job.run_token is distinct from run_token or job.lease_token is distinct from lease_token or job.lease_expires_at is null or job.lease_expires_at<=checked_at
  or job.revision is distinct from expected_revision then raise exception using errcode='P0001',message='WALI_DELETION_LEASE_INVALID'; end if;
 return job;
end $$;

create function public.wali_edge_claim_account_deletion_v1(run_token uuid) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare candidate record; job wali.account_deletion_finalization_jobs%rowtype; deletion wali.account_deletion_requests%rowtype; token uuid; ready boolean; state wali.account_deletion_dispatch_state%rowtype; claimed_at timestamptz;
begin
 perform wali.require_deletion_service();
 if not exists(select 1 from wali.account_deletion_dispatch_state s where s.run_token=wali_edge_claim_account_deletion_v1.run_token and s.lease_expires_at>clock_timestamp()) then
  raise exception using errcode='P0001',message='WALI_DELETION_LEASE_INVALID'; end if;
 -- Bounded reconciliation also revives a consented cleanup message after its
 -- transport exhausted retries. A DLQ row is evidence, not completion.
 for candidate in select j.id,d.user_id,d.id as deletion_id from wali.account_deletion_finalization_jobs j join wali.account_deletion_requests d on d.id=j.deletion_id
  where j.completed_at is null and j.next_attempt_at<=clock_timestamp() and coalesce(j.lease_expires_at,'-infinity')<=clock_timestamp()
   and d.status<>'cancelled' order by j.next_attempt_at,j.id limit 20
 loop
  perform 1 from wali.profiles p where p.id=candidate.user_id for update skip locked; if not found then continue; end if;
  select * into deletion from wali.account_deletion_requests d where d.id=candidate.deletion_id for update;
  select * into job from wali.account_deletion_finalization_jobs j where j.id=candidate.id for update skip locked;
  if not found or coalesce(job.lease_expires_at,'-infinity')>clock_timestamp() then continue; end if;
  select * into state from wali.account_deletion_dispatch_state where singleton for share;
  if state.run_token is distinct from run_token or state.lease_expires_at is null or state.lease_expires_at<=clock_timestamp() then
   raise exception using errcode='P0001',message='WALI_DELETION_LEASE_INVALID'; end if;
  if deletion.sessions_revoked_at is null then
   -- Recover a lost acceptance response before Edge called the durable session
   -- checkpoint. The consented job is the authority; no sessions are fabricated.
   perform public.wali_edge_mark_account_deletion_sessions_revoked_v1(deletion.user_id,deletion.id,deletion.request_id);
   select * into deletion from wali.account_deletion_requests d where d.id=candidate.deletion_id;
  end if;
  ready:=wali.prepare_account_object_cleanup(deletion.id,deletion.user_id);
  -- Digest/hold reconciliation can also wait; expiry rolls back its writes.
  claimed_at:=clock_timestamp();
  if state.lease_expires_at<=claimed_at then raise exception using errcode='P0001',message='WALI_DELETION_LEASE_INVALID'; end if;
  if wali.account_deletion_has_hold(deletion.user_id) and job.authorized_at is null then
   update wali.account_deletion_finalization_jobs set stage='held',next_attempt_at=statement_timestamp()+interval '15 minutes' where id=job.id;
   continue;
  end if;
  if not ready or deletion.status not in('awaiting_auth_cleanup','completed') then
   update wali.account_deletion_finalization_jobs set stage=case when exists(select 1 from wali.account_deletion_object_intents i where i.deletion_id=deletion.id and i.disposition='shared_reference') then 'held' else 'cleanup' end,
    next_attempt_at=statement_timestamp()+interval '1 minute' where id=job.id;
   if deletion.status='failed' then update wali.account_deletion_requests set status='pending',safe_error_code=null where id=deletion.id; end if;
   if not exists(select 1 from pgmq.q_wali_account_deletions q where q.message->>'deletion_id'=deletion.id::text) then
    perform pgmq.send('wali_account_deletions',jsonb_build_object('schema_version',1,'deletion_id',deletion.id,'user_id',deletion.user_id));
   end if;
   continue;
  end if;
  token:=gen_random_uuid();
  update wali.account_deletion_finalization_jobs j set run_token=wali_edge_claim_account_deletion_v1.run_token,lease_token=token,
   lease_expires_at=claimed_at+interval '3 minutes',revision=j.revision+1,attempts=j.attempts+1,
   next_attempt_at=claimed_at+interval '3 minutes'+make_interval(mins=>case when j.attempts>=7 then 60 when j.attempts>=4 then 15 else (2^j.attempts)::integer end)
   where j.id=job.id returning * into job;
  return jsonb_build_object('job',jsonb_build_object('job_id',job.id,'lease_token',token,'revision',job.revision));
 end loop;
 return jsonb_build_object('job',null);
end $$;

create function public.wali_edge_prepare_automatic_account_deletion_v1(run_token uuid,job_id uuid,lease_token uuid,expected_revision bigint) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare job wali.account_deletion_finalization_jobs%rowtype; deletion wali.account_deletion_requests%rowtype; bindings jsonb;
begin
 job:=wali.require_account_deletion_lease(run_token,job_id,lease_token,expected_revision);
 select * into deletion from wali.account_deletion_requests d where d.id=job.deletion_id;
 if deletion.status<>'awaiting_auth_cleanup' or deletion.sessions_revoked_at is null or deletion.auth_identity_status<>'operator_cleanup_required'
  or not wali.prepare_account_object_cleanup(deletion.id,deletion.user_id)
  or (job.authorized_at is null and wali.account_deletion_has_hold(deletion.user_id))
  or exists(select 1 from wali.apple_authorizations a where a.actor_id=deletion.user_id and a.binding_lease_expires_at>statement_timestamp()) then
  raise exception using errcode='P0001',message='WALI_DELETION_NOT_READY'; end if;
 -- Cleanup may acquire digest locks after the first lease check.
 job:=wali.require_account_deletion_lease(run_token,job_id,lease_token,expected_revision);
 if job.authorized_at is null then
  update wali.account_deletion_finalization_jobs j set authorized_at=statement_timestamp(),stage='apple_revocation',
   apple_required_clients=coalesce((select array_agg(a.client_id order by a.client_id) from wali.apple_authorizations a where a.actor_id=deletion.user_id and a.encrypted_refresh_token is not null),'{}'),
   apple_action_required=(exists(select 1 from auth.identities i where i.user_id=deletion.user_id and i.provider='apple') and not exists(select 1 from wali.apple_authorizations a where a.actor_id=deletion.user_id and a.encrypted_refresh_token is not null))
    or exists(select 1 from wali.apple_authorizations a where a.actor_id=deletion.user_id and a.encrypted_refresh_token is null),
   revision=j.revision+1 where j.id=job.id returning * into job;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('actor_id',a.actor_id,'client_id',a.client_id,'apple_subject',a.apple_subject,
  'encrypted_refresh_token',a.encrypted_refresh_token,'encryption_key_version',a.encryption_key_version,'revision',a.revision) order by a.client_id),'[]') into bindings
  from wali.apple_authorizations a where a.actor_id=deletion.user_id and a.encrypted_refresh_token is not null and a.client_id=any(job.apple_required_clients) and not(a.client_id=any(job.apple_revoked_clients));
 return jsonb_build_object('user_id',deletion.user_id,'deletion_id',deletion.id,'revision',job.revision,'apple_authorizations',bindings);
end $$;
create function public.wali_edge_checkpoint_account_apple_revocation_v1(run_token uuid,job_id uuid,lease_token uuid,expected_revision bigint,client_id text,expected_binding_revision bigint) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare job wali.account_deletion_finalization_jobs%rowtype; actor uuid;
begin
 job:=wali.require_account_deletion_lease(run_token,job_id,lease_token,expected_revision);
 select user_id into actor from wali.account_deletion_requests where id=job.deletion_id;
 if job.authorized_at is null or client_id is null or not(client_id=any(job.apple_required_clients)) then raise exception using errcode='P0001',message='WALI_DELETION_NOT_READY'; end if;
 if not(client_id=any(job.apple_revoked_clients)) then
  delete from wali.apple_authorizations a where a.actor_id=actor and a.client_id=wali_edge_checkpoint_account_apple_revocation_v1.client_id
   and a.revision=expected_binding_revision and a.encrypted_refresh_token is not null and coalesce(a.binding_lease_expires_at,'-infinity')<=statement_timestamp();
  if not found then raise exception using errcode='P0001',message='WALI_REVISION_MISMATCH'; end if;
  update wali.account_deletion_finalization_jobs j set apple_revoked_clients=array_append(j.apple_revoked_clients,client_id),revision=j.revision+1 where j.id=job.id returning * into job;
 end if;
 return jsonb_build_object('revision',job.revision);
end $$;
create function public.wali_edge_authorize_account_identity_deletion_v1(run_token uuid,job_id uuid,lease_token uuid,expected_revision bigint) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare job wali.account_deletion_finalization_jobs%rowtype; actor uuid;
begin
 job:=wali.require_account_deletion_lease(run_token,job_id,lease_token,expected_revision);
 select user_id into actor from wali.account_deletion_requests where id=job.deletion_id;
 if job.authorized_at is null or not(job.apple_required_clients<@job.apple_revoked_clients)
  or exists(select 1 from wali.apple_authorizations a where a.actor_id=actor and (a.encrypted_refresh_token is not null or a.binding_lease_expires_at>statement_timestamp())) then
  raise exception using errcode='P0001',message='WALI_DELETION_NOT_READY'; end if;
 update wali.account_deletion_finalization_jobs j set identity_authorized_at=coalesce(j.identity_authorized_at,statement_timestamp()),stage='identity_deletion',revision=j.revision+1 where j.id=job.id returning * into job;
 return jsonb_build_object('user_id',actor,'revision',job.revision);
end $$;
create function public.wali_edge_finalize_automatic_account_deletion_v1(run_token uuid,job_id uuid,lease_token uuid,expected_revision bigint) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare job wali.account_deletion_finalization_jobs%rowtype; deletion wali.account_deletion_requests%rowtype; finished timestamptz:=date_trunc('second',statement_timestamp());
begin
 job:=wali.require_account_deletion_lease(run_token,job_id,lease_token,expected_revision);
 select * into deletion from wali.account_deletion_requests d where d.id=job.deletion_id;
 if job.completed_at is not null then return jsonb_build_object('completed',true,'revision',job.revision); end if;
 if job.identity_authorized_at is null or deletion.status<>'awaiting_auth_cleanup' or not(job.apple_required_clients<@job.apple_revoked_clients) then
  raise exception using errcode='P0001',message='WALI_DELETION_NOT_READY'; end if;
 delete from wali.apple_authorizations where actor_id=deletion.user_id;
 update wali.account_deletion_requests set status='completed',auth_identity_status='completed',identity_deleted_at=finished,
  identity_deletion_operation_id=job.id,completed_at=finished,revision=revision+1 where id=deletion.id;
 update wali.account_deletion_finalization_jobs j set stage='completed',completed_at=finished,safe_error_code=null,revision=j.revision+1 where j.id=job.id returning * into job;
 update wali.account_deletion_status_receipts r set status_expires_at=finished+interval '30 days' where r.job_id=job.id and r.status_expires_at is null;
 insert into wali.audit_events(actor_id,action,target_type,target_id,request_id,metadata) values(null,'account.automatic_deletion_completed','account',deletion.user_id,deletion.request_id,
  jsonb_build_object('authority','automatic_account_deletion_v1','policy_version',job.policy_version,'apple_action_required',job.apple_action_required));
 return jsonb_build_object('completed',true,'revision',job.revision);
end $$;
create function public.wali_edge_retry_account_deletion_v1(run_token uuid,job_id uuid,lease_token uuid,expected_revision bigint,safe_error_code text) returns boolean
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare job wali.account_deletion_finalization_jobs%rowtype;
begin
 job:=wali.require_account_deletion_lease(run_token,job_id,lease_token,expected_revision);
 if job.completed_at is not null then return true; end if;
 if safe_error_code is distinct from 'WALI_ACCOUNT_DELETION_RETRYING' then raise exception using errcode='P0001',message='WALI_REQUEST_INVALID'; end if;
 update wali.account_deletion_finalization_jobs j set stage='retrying',safe_error_code=wali_edge_retry_account_deletion_v1.safe_error_code,
  next_attempt_at=statement_timestamp()+make_interval(mins=>case when j.attempts>=8 then 60 when j.attempts>=5 then 15 else (2^greatest(j.attempts-1,0))::integer end),
  run_token=null,lease_token=null,lease_expires_at=null,revision=j.revision+1 where j.id=job.id;
 return true;
end $$;

create function public.wali_edge_account_deletion_receipt_v1(capability_hash text) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare receipt wali.account_deletion_status_receipts%rowtype; job wali.account_deletion_finalization_jobs%rowtype; deletion wali.account_deletion_requests%rowtype;
begin
 perform wali.require_deletion_service();
 select * into receipt from wali.account_deletion_status_receipts r where r.capability_hash=wali_edge_account_deletion_receipt_v1.capability_hash for update;
 if not found or receipt.status_expires_at<=statement_timestamp() then return null; end if;
 if receipt.check_window<=statement_timestamp()-interval '1 hour' then receipt.check_window:=statement_timestamp(); receipt.checks:=0; end if;
 if receipt.checks>=120 then raise exception using errcode='P0001',message='WALI_RATE_LIMITED'; end if;
 update wali.account_deletion_status_receipts r set checks=receipt.checks+1,check_window=receipt.check_window where r.capability_hash=receipt.capability_hash;
 select * into job from wali.account_deletion_finalization_jobs j where j.id=receipt.job_id;
 select * into deletion from wali.account_deletion_requests d where d.id=job.deletion_id;
 return jsonb_build_object('status',case when job.stage='held' then 'held' else deletion.status end,'stage',job.stage,
  'requested_at',to_char(deletion.requested_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'completed_at',case when job.completed_at is null then null else to_char(job.completed_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') end,
  'status_expires_at',case when receipt.status_expires_at is null then null else to_char(receipt.status_expires_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') end,
  'retained_categories',job.retained_categories,'apple_action_required',job.apple_action_required);
end $$;

create function wali.deletion_cleanup_is_authorized(cleanup_id uuid) returns boolean
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare intent record;
begin
 select i.*,d.user_id,d.sessions_revoked_at,p.status as profile_status into intent
  from wali.account_deletion_object_intents i join wali.account_deletion_requests d on d.id=i.deletion_id
  join wali.profiles p on p.id=d.user_id where i.cleanup_id=deletion_cleanup_is_authorized.cleanup_id and i.disposition='queued' limit 1;
 if not found then return false; end if;
 perform 1 from wali.profiles p where p.id=intent.user_id for update;
 perform wali.lock_deletion_digest(intent.digest);
 return intent.sessions_revoked_at is not null and intent.profile_status in('deletion_pending','deleted')
  and wali.account_deletion_object_removable(intent.bucket_id,intent.digest,intent.user_id);
end $$;

-- Existing worker identity and lease checks are retained inside the adapters.
alter function wali.worker_begin_cleanup(uuid,text,timestamptz) rename to worker_begin_cleanup_before_deletion;
create function wali.worker_begin_cleanup(cleanup_id uuid,worker_identity text,lease_until timestamptz) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
begin
 if not wali.worker_caller_authorized() then raise exception using errcode='P0001',message='WALI_WORKER_ROLE_REQUIRED'; end if;
 if exists(select 1 from wali.cleanup_object_intents c where c.id=cleanup_id and c.bucket_id='catalog-public')
  or exists(select 1 from wali.account_deletion_object_intents i where i.cleanup_id=worker_begin_cleanup.cleanup_id and i.disposition<>'completed') then
  if not wali.deletion_cleanup_is_authorized(cleanup_id) then return jsonb_build_object('disposition','active'); end if;
 end if;
 return wali.worker_begin_cleanup_before_deletion(cleanup_id,worker_identity,lease_until);
end $$;
alter function wali.worker_complete_cleanup(uuid,text) rename to worker_complete_cleanup_before_deletion;
create function wali.worker_complete_cleanup(cleanup_id uuid,worker_identity text) returns boolean
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare result boolean;
begin
 result:=wali.worker_complete_cleanup_before_deletion(cleanup_id,worker_identity);
 if result then update wali.account_deletion_object_intents i set disposition='completed',completed_at=coalesce(i.completed_at,statement_timestamp()) where i.cleanup_id=worker_complete_cleanup.cleanup_id; end if;
 return result;
end $$;
alter function wali.storage_worker_can_delete(text,text,text) rename to storage_worker_can_delete_before_deletion;
create function wali.storage_worker_can_delete(object_bucket text,object_path text,worker_identity text) returns boolean
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare cleanup uuid;
begin
 if not wali.storage_worker_can_delete_before_deletion(object_bucket,object_path,worker_identity) then return false; end if;
 select id into cleanup from wali.cleanup_object_intents c where c.bucket_id=object_bucket and c.storage_path=object_path;
 if object_bucket='catalog-public' or exists(select 1 from wali.account_deletion_object_intents i where i.cleanup_id=cleanup) then
  return wali.deletion_cleanup_is_authorized(cleanup); end if;
 return true;
end $$;
-- Existing SELECT policy points to the unchanged function OID. Public Storage
-- reads are already public; deletion gets only the exact admitted object lease.
create policy wali_worker_delete_consented_public_object on storage.objects for delete to wali_storage_worker
 using(bucket_id='catalog-public' and wali.storage_worker_can_delete(bucket_id,name,auth.jwt()->>'worker_id'));
create policy wali_worker_read_consented_public_cleanup on storage.objects for select to wali_storage_worker
 using(bucket_id='catalog-public' and wali.storage_worker_can_delete(bucket_id,name,auth.jwt()->>'worker_id'));
-- Rebind the old private policy to the wrapper instead of its renamed OID.
drop policy wali_worker_delete_leased_private_object on storage.objects;
create policy wali_worker_delete_leased_private_object on storage.objects for delete to wali_storage_worker
 using(bucket_id in('uploads-private','exports-private','processing-private','moderation-private') and wali.storage_worker_can_delete(bucket_id,name,auth.jwt()->>'worker_id'));

create function wali.guard_deleted_storage_object() returns trigger language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare digest text;
begin
 if new.bucket_id in('catalog-public','processing-private') then
  digest:=split_part(new.name,'/',4);
  if digest ~ '^[0-9a-f]{64}$' then
   perform wali.lock_deletion_digest(digest);
   if exists(select 1 from wali.account_deletion_object_intents i where i.digest=digest and i.bucket_id=new.bucket_id and i.disposition in('queued','completed')) then
    raise exception using errcode='P0001',message='WALI_ARTIFACT_DELETION_FENCED'; end if;
  end if;
 end if;
 return new;
end $$;
create trigger wali_deleted_object_insert_fence before insert or update of name,bucket_id on storage.objects
 for each row execute function wali.guard_deleted_storage_object();

create function wali.guard_deleting_creator_media() returns trigger language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare actor uuid;
begin
 if tg_table_name='staged_artifacts' then
  select s.creator_id into actor from wali.processing_attempts a join wali.submissions s on s.id=a.submission_id where a.id=new.verified_by_attempt_id;
 else
  if new.status<>'published' then return new; end if;
  select w.creator_id into actor from wali.wallpapers w where w.id=new.wallpaper_id;
 end if;
 perform 1 from wali.profiles p where p.id=actor and p.status='active' for update;
 if not found then raise exception using errcode='P0001',message='WALI_ACCOUNT_INACTIVE'; end if;
 return new;
end $$;
create trigger staged_artifact_creator_deletion_fence before insert on wali.staged_artifacts for each row execute function wali.guard_deleting_creator_media();
create trigger publication_creator_deletion_fence before insert or update of status on wali.wallpaper_releases for each row execute function wali.guard_deleting_creator_media();
create function wali.order_account_deletion_hold() returns trigger language plpgsql security definer set search_path='' as $$
declare artifact_digest text;
begin
 perform 1 from wali.profiles p join wali.wallpapers w on w.creator_id=p.id where w.id=new.target_wallpaper_id for update of p;
 for artifact_digest in select a.artifact_digest from wali.release_artifacts a join wali.wallpaper_releases r on r.id=a.release_id where r.wallpaper_id=new.target_wallpaper_id
  union select a.artifact_digest from wali.release_staged_artifacts a join wali.wallpaper_releases r on r.id=a.release_id where r.wallpaper_id=new.target_wallpaper_id order by 1
 loop perform wali.lock_deletion_digest(artifact_digest); end loop;
 return new;
end $$;
create trigger copyright_account_deletion_order before insert or update of status on wali.copyright_cases for each row execute function wali.order_account_deletion_hold();

alter function wali.worker_begin_account_deletion(uuid,uuid,text,timestamptz) rename to worker_begin_account_deletion_before_automation;
create function wali.worker_begin_account_deletion(deletion_id uuid,user_id uuid,worker_identity text,lease_until timestamptz) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
begin
 if not wali.worker_caller_authorized() then raise exception using errcode='P0001',message='WALI_WORKER_ROLE_REQUIRED'; end if;
 perform 1 from wali.profiles p where p.id=user_id for update;
 if exists(select 1 from wali.account_deletion_finalization_jobs j join wali.account_deletion_requests d on d.id=j.deletion_id where j.deletion_id=worker_begin_account_deletion.deletion_id and d.user_id=worker_begin_account_deletion.user_id) then
  perform 1 from wali.account_deletion_requests d where d.id=deletion_id for update;
  if not wali.prepare_account_object_cleanup(deletion_id,user_id) then return jsonb_build_object('disposition','cleanup_pending'); end if;
 end if;
 return wali.worker_begin_account_deletion_before_automation(deletion_id,user_id,worker_identity,lease_until);
end $$;
alter function wali.worker_complete_account_deletion(uuid,uuid,text) rename to worker_complete_account_deletion_before_automation;
create function wali.worker_complete_account_deletion(deletion_id uuid,user_id uuid,worker_identity text) returns boolean
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare result boolean;
begin
 if not wali.worker_caller_authorized() then raise exception using errcode='P0001',message='WALI_WORKER_ROLE_REQUIRED'; end if;
 perform 1 from wali.profiles p where p.id=user_id for update;
 if exists(select 1 from wali.account_deletion_finalization_jobs j join wali.account_deletion_requests d on d.id=j.deletion_id where j.deletion_id=worker_complete_account_deletion.deletion_id and d.user_id=worker_complete_account_deletion.user_id) then
  perform 1 from wali.account_deletion_requests d where d.id=deletion_id for update;
  if not wali.prepare_account_object_cleanup(deletion_id,user_id) then return false; end if;
 end if;
 result:=wali.worker_complete_account_deletion_before_automation(deletion_id,user_id,worker_identity);
 if result then
  update wali.creator_block_preferences p set generation=p.generation+1,updated_at=statement_timestamp()
   where exists(select 1 from wali.creator_blocks b where b.user_id=p.user_id and b.creator_id=worker_complete_account_deletion.user_id);
  delete from wali.creator_blocks b where b.user_id=worker_complete_account_deletion.user_id or b.creator_id=worker_complete_account_deletion.user_id;
  delete from wali.creator_block_preferences p where p.user_id=worker_complete_account_deletion.user_id;
  update wali.account_deletion_finalization_jobs j set next_attempt_at=statement_timestamp() where j.deletion_id=worker_complete_account_deletion.deletion_id and j.completed_at is null;
 end if;
 return result;
end $$;

-- Manual recovery keeps real admin+AAL2, but cannot bypass the new job fence.
alter function public.wali_edge_prepare_account_identity_deletion_v1(uuid,text,uuid,bigint) set schema wali;
alter function wali.wali_edge_prepare_account_identity_deletion_v1(uuid,text,uuid,bigint) rename to prepare_legacy_account_identity_deletion;
create function public.wali_edge_prepare_account_identity_deletion_v1(actor_id uuid,actor_aal text,deletion_id uuid,expected_revision bigint) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
begin
 perform wali.require_deletion_service();
 if actor_aal is distinct from 'aal2' or not wali.edge_actor_has_role(actor_id,'admin') then raise exception using errcode='P0001',message='WALI_ADMIN_AAL2_REQUIRED'; end if;
 if exists(select 1 from wali.account_deletion_finalization_jobs j where j.deletion_id=wali_edge_prepare_account_identity_deletion_v1.deletion_id) then
  raise exception using errcode='P0001',message='WALI_DELETION_AUTOMATIC_RECOVERY_REQUIRED'; end if;
 return wali.prepare_legacy_account_identity_deletion(actor_id,actor_aal,deletion_id,expected_revision);
end $$;
alter function public.wali_edge_finalize_account_identity_deletion_v1(uuid,text,uuid,uuid,bigint) set schema wali;
alter function wali.wali_edge_finalize_account_identity_deletion_v1(uuid,text,uuid,uuid,bigint) rename to finalize_legacy_account_identity_deletion;
create function public.wali_edge_finalize_account_identity_deletion_v1(actor_id uuid,actor_aal text,request_id uuid,deletion_id uuid,expected_revision bigint) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
begin
 perform public.wali_edge_prepare_account_identity_deletion_v1(actor_id,actor_aal,deletion_id,expected_revision);
 return wali.finalize_legacy_account_identity_deletion(actor_id,actor_aal,request_id,deletion_id,expected_revision);
end $$;
create function public.wali_edge_retry_automatic_account_deletion_v1(actor_id uuid,actor_aal text,deletion_id uuid,expected_revision bigint) returns jsonb
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare actor uuid; job wali.account_deletion_finalization_jobs%rowtype;
begin
 perform wali.require_deletion_service();
 if actor_aal is distinct from 'aal2' or not wali.edge_actor_has_role(actor_id,'admin') then raise exception using errcode='P0001',message='WALI_ADMIN_AAL2_REQUIRED'; end if;
 select d.user_id into actor from wali.account_deletion_requests d where d.id=deletion_id;
 perform 1 from wali.profiles p where p.id=actor for update;
 perform 1 from wali.account_deletion_requests d where d.id=deletion_id and d.revision=expected_revision for update;
 if not found then raise exception using errcode='P0001',message='WALI_REVISION_MISMATCH'; end if;
 select * into job from wali.account_deletion_finalization_jobs j where j.deletion_id=wali_edge_retry_automatic_account_deletion_v1.deletion_id for update;
 if not found or job.completed_at is not null or job.lease_expires_at>statement_timestamp() then raise exception using errcode='P0001',message='WALI_DELETION_NOT_READY'; end if;
 update wali.account_deletion_finalization_jobs set attempts=0,next_attempt_at=statement_timestamp(),safe_error_code=null,revision=revision+1 where id=job.id;
 return public.wali_edge_account_deletion_status_v1(actor,deletion_id);
end $$;

create function wali.purge_expired_deletion_receipts(effective_clock timestamptz) returns integer
 language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare affected integer;
begin
 -- Receipt expiry never rewrites deletion/audit retention or extends a receipt.
 delete from wali.account_deletion_status_receipts r where r.capability_hash in
  (select c.capability_hash from wali.account_deletion_status_receipts c where c.status_expires_at<=effective_clock order by c.status_expires_at limit 1000);
 get diagnostics affected=row_count; return affected;
end $$;
create function wali.dispatch_account_deletion_tick() returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare token text;
begin
 select decrypted_secret into token from vault.decrypted_secrets where name='wali_account_deletion_dispatch_token';
 if token is null or token !~ '^[a-f0-9]{64}$' then return; end if;
 perform net.http_post(url:='https://afgxvhhubqzgpijcstsv.supabase.co/functions/v1/automatic-account-deletion',
  headers:=jsonb_build_object('content-type','application/json','x-wali-account-deletion-token',token),
  body:='{"api_version":"account_deletion_worker.v1"}'::jsonb,timeout_milliseconds:=45000);
end $$;
-- No cron schedule or secret value is installed by schema migration. Activation
-- adds the exact minute dispatcher and bounded daily receipt purge separately.

-- Renaming preserves the old body and security behavior. Update only the
-- implicit function-label qualifiers used by those original parameter bindings.
do $$ declare pair text[]; signature regprocedure; definition text; begin
 foreach pair slice 1 in array array[
  ['worker_begin_cleanup','worker_begin_cleanup_before_deletion'],
  ['worker_complete_cleanup','worker_complete_cleanup_before_deletion'],
  ['storage_worker_can_delete','storage_worker_can_delete_before_deletion'],
  ['worker_begin_account_deletion','worker_begin_account_deletion_before_automation'],
  ['worker_complete_account_deletion','worker_complete_account_deletion_before_automation'],
  ['wali_edge_prepare_account_identity_deletion_v1','prepare_legacy_account_identity_deletion'],
  ['wali_edge_finalize_account_identity_deletion_v1','finalize_legacy_account_identity_deletion']
 ] loop
  select p.oid::regprocedure into signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='wali' and p.proname=pair[2];
  definition:=replace(pg_get_functiondef(signature),pair[1]||'.',pair[2]||'.');
  if pair[1]='worker_complete_account_deletion' then
   -- Truncating the actor UUID collided for distinct accounts with a common
   -- prefix. A new random, format-valid handle discloses no identity prefix.
   definition:=replace(definition,
    $old$('deleted_' || left(replace(profile.id::text, '-', ''), 24))::extensions.citext$old$,
    $new$replace(gen_random_uuid()::text, '-', '')::extensions.citext$new$);
  end if;
  execute definition;
 end loop;
end $$;

-- All new helper functions default-deny; existing adapters retain only their
-- former exact role. The service API list is explicit and has no anon grant.
do $$ declare fn record; begin
 for fn in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='wali' and p.proname in(
   'require_deletion_service','account_deletion_has_hold','lock_deletion_digest','account_deletion_targets','deletion_object_has_other_reference','account_deletion_object_removable',
   'prepare_account_object_cleanup','guard_deleted_artifact_reference','require_account_deletion_lease','deletion_cleanup_is_authorized',
   'worker_begin_cleanup_before_deletion','worker_complete_cleanup_before_deletion','storage_worker_can_delete_before_deletion',
   'guard_deleted_storage_object','guard_deleting_creator_media','order_account_deletion_hold','worker_begin_account_deletion_before_automation','worker_complete_account_deletion_before_automation',
   'prepare_legacy_account_identity_deletion','finalize_legacy_account_identity_deletion','purge_expired_deletion_receipts','dispatch_account_deletion_tick')
 loop execute format('revoke all on function %s from public,anon,authenticated,service_role,wali_worker,wali_storage_worker',fn.signature); end loop;
 for fn in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in(
   'wali_edge_request_account_deletion_v2','wali_edge_begin_account_deletion_dispatch_v1','wali_edge_end_account_deletion_dispatch_v1',
   'wali_edge_claim_account_deletion_v1','wali_edge_prepare_automatic_account_deletion_v1','wali_edge_checkpoint_account_apple_revocation_v1',
   'wali_edge_authorize_account_identity_deletion_v1','wali_edge_finalize_automatic_account_deletion_v1','wali_edge_retry_account_deletion_v1',
   'wali_edge_account_deletion_receipt_v1','wali_edge_prepare_account_identity_deletion_v1','wali_edge_finalize_account_identity_deletion_v1',
   'wali_edge_retry_automatic_account_deletion_v1')
 loop
  execute format('revoke all on function %s from public,anon,authenticated,wali_worker,wali_storage_worker',fn.signature);
  execute format('grant execute on function %s to service_role',fn.signature);
 end loop;
end $$;
revoke all on function wali.worker_begin_cleanup(uuid,text,timestamptz),wali.worker_complete_cleanup(uuid,text),
 wali.worker_begin_account_deletion(uuid,uuid,text,timestamptz),wali.worker_complete_account_deletion(uuid,uuid,text),
 wali.storage_worker_can_delete(text,text,text) from public,anon,authenticated,service_role,wali_worker,wali_storage_worker;
grant execute on function wali.worker_begin_cleanup(uuid,text,timestamptz),wali.worker_complete_cleanup(uuid,text),
 wali.worker_begin_account_deletion(uuid,uuid,text,timestamptz),wali.worker_complete_account_deletion(uuid,uuid,text) to wali_worker,service_role;
grant execute on function wali.storage_worker_can_delete(text,text,text) to wali_storage_worker;
commit;
