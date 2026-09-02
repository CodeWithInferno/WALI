-- WALI Marketplace foundation: extensions, private schema, bounded enums, and common helpers.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;
create extension if not exists vector with schema extensions;
create extension if not exists pgmq;
create extension if not exists pg_cron with schema pg_catalog;

create schema if not exists wali;

revoke all on schema wali from public, anon, authenticated;
grant usage on schema wali to service_role;

alter default privileges in schema wali revoke all on tables from public, anon, authenticated;
alter default privileges in schema wali revoke all on sequences from public, anon, authenticated;
alter default privileges in schema wali revoke execute on functions from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from public, anon, authenticated;
alter default privileges in schema public revoke all on sequences from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

create type wali.account_status as enum ('active', 'suspended', 'deletion_pending', 'deleted');
create type wali.role_name as enum ('creator', 'moderator', 'admin');
create type wali.verification_status as enum ('unverified', 'pending', 'verified', 'rejected');
create type wali.wallpaper_status as enum ('draft', 'published', 'hidden', 'suspended', 'removed');
create type wali.visibility as enum ('public', 'unlisted');
create type wali.content_rating as enum ('everyone', 'teen', 'mature');
create type wali.submission_status as enum (
  'draft', 'uploading', 'uploaded', 'processing', 'processing_failed',
  'ready_for_submission', 'submitted', 'under_review', 'changes_requested',
  'approved', 'rejected', 'published', 'withdrawn'
);
create type wali.release_status as enum ('processing', 'review', 'approved', 'published', 'revoked');
create type wali.artifact_role as enum (
  'thumbnail', 'poster', 'preview', 'video_1080p', 'video_1440p',
  'video_2160p', 'video_default'
);
create type wali.taxonomy_source as enum ('creator', 'classifier', 'moderator', 'editorial');
create type wali.tag_kind as enum ('subject', 'style', 'mood', 'color', 'motion', 'setting', 'format');
create type wali.suggestion_status as enum ('suggested', 'approved', 'rejected');
create type wali.rights_basis as enum ('original', 'licensed', 'public_domain', 'other');
create type wali.review_decision as enum ('approved', 'changes_requested', 'rejected');
create type wali.report_kind as enum (
  'copyright', 'impersonation', 'unsafe', 'sexual', 'hate', 'violence',
  'spam', 'misleading', 'other'
);
create type wali.case_status as enum ('open', 'triaged', 'actioned', 'closed', 'appealed');
create type wali.event_kind as enum (
  'detail_view', 'install_requested', 'install_succeeded', 'favorite_added',
  'favorite_removed', 'saved', 'unsaved', 'report_submitted'
);
create type wali.revocation_reason as enum ('critical_security', 'corrupt_artifact', 'signing_compromise');

create type wali.upload_status as enum ('issued', 'uploading', 'completed', 'expired', 'cancelled');
create type wali.processing_status as enum (
  'queued', 'leased', 'downloading', 'transcoding', 'verifying',
  'classifying', 'completed', 'failed', 'timed_out'
);
create type wali.rights_review_status as enum ('pending', 'approved', 'rejected');
create type wali.classification_status as enum ('queued', 'running', 'completed', 'failed');
create type wali.collection_kind as enum ('editorial', 'system');
create type wali.collection_status as enum ('draft', 'published', 'archived');
create type wali.embedding_modality as enum ('text', 'visual', 'combined');
create type wali.signing_key_status as enum ('pending', 'active', 'retired', 'compromised');
create type wali.model_status as enum ('pending', 'active', 'retired', 'blocked');
create type wali.moderation_target_type as enum ('submission', 'wallpaper', 'release', 'report', 'account', 'signing_key');

comment on type wali.account_status is 'API enum v1; additive client decoding must fail closed for capabilities.';
comment on type wali.role_name is 'Authorization enum v1; new values do not inherit existing privileges.';
comment on type wali.submission_status is 'Submission state machine v1; transitions are server-command only.';
comment on type wali.release_status is 'Immutable release lifecycle v1.';
comment on type wali.artifact_role is 'Signed manifest artifact-role vocabulary, epoch 1.';
comment on type wali.event_kind is 'Privacy-reviewed engagement vocabulary v1.';
comment on type wali.revocation_reason is 'Critical technical revocation reasons only; policy takedowns use catalog state.';

create or replace function wali.plain_text_is_valid(
  value text,
  minimum_length integer,
  maximum_length integer
) returns boolean
language sql
immutable
set search_path = ''
as $$
  select value is not null
     and char_length(btrim(value)) between minimum_length and maximum_length
     and value !~ '[[:cntrl:]]'
$$;

create or replace function wali.https_url_is_valid(value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select value is null or (
    char_length(value) between 8 and 2048
    and value ~ '^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?([/:?#][^[:space:][:cntrl:]]*)?$'
  )
$$;

create or replace function wali.touch_mutable_row()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := clock_timestamp();
  if to_jsonb(new) ? 'revision' then
    new.revision := old.revision + 1;
  end if;
  return new;
end
$$;

revoke all on all functions in schema wali from public, anon, authenticated;
