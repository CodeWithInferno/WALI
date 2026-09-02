#!/bin/sh
set -eu

: "${WALI_RESTORE_DATABASE_URL:?set to the isolated restored database URL}"
: "${WALI_RESTORE_EXPECTED_HOST:?set to the exact isolated database host}"
: "${WALI_RESTORE_CONFIRM:?set to isolated-non-production}"
: "${WALI_RESTORE_OBJECT_ROOT:?set to the isolated restored object root}"
: "${WALI_RESTORE_OBJECT_MANIFEST:?set to the SHA-256 manifest path}"

if [ "$WALI_RESTORE_CONFIRM" != "isolated-non-production" ]; then
  echo "restore verification requires WALI_RESTORE_CONFIRM=isolated-non-production" >&2
  exit 64
fi

database_host=$(ruby -ruri -e 'u=URI.parse(ARGV.fetch(0)); abort unless %w[postgres postgresql].include?(u.scheme); puts u.host' "$WALI_RESTORE_DATABASE_URL")
if [ -z "$database_host" ] || [ "$database_host" != "$WALI_RESTORE_EXPECTED_HOST" ]; then
  echo "database host does not match the explicitly approved isolated host" >&2
  exit 64
fi

case "$database_host" in
  db.nkwzjuzoyuanjimexulz.supabase.co|db.afgxvhhubqzgpijcstsv.supabase.co)
    echo "refusing to run restore verification against a WALI live project" >&2
    exit 64
    ;;
esac

if [ ! -d "$WALI_RESTORE_OBJECT_ROOT" ] || [ ! -f "$WALI_RESTORE_OBJECT_MANIFEST" ]; then
  echo "isolated object root or checksum manifest is missing" >&2
  exit 66
fi

if awk 'NF != 2 || $1 !~ /^[0-9a-f]{64}$/ || $2 ~ /^\// || $2 ~ /(^|\/)\.\.($|\/)/ { exit 1 }' "$WALI_RESTORE_OBJECT_MANIFEST"; then
  :
else
  echo "object manifest contains an unsafe or malformed entry" >&2
  exit 65
fi

(
  cd "$WALI_RESTORE_OBJECT_ROOT"
  shasum -a 256 -c "$WALI_RESTORE_OBJECT_MANIFEST"
)

violations=$(psql -X --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 "$WALI_RESTORE_DATABASE_URL" <<'SQL'
begin transaction read only;
with checks(name, violations) as (
  select 'current_release', count(*)
    from wali.wallpapers w
    left join wali.wallpaper_releases r on r.id = w.current_release_id
   where w.current_release_id is not null
     and (r.id is null or r.wallpaper_id <> w.id or r.status <> 'published')
  union all
  select 'published_manifest', count(*)
    from wali.wallpaper_releases r
   where r.status = 'published'
     and (r.manifest_body is null or r.manifest_digest is null
       or encode(extensions.digest(r.manifest_body, 'sha256'), 'hex') <> r.manifest_digest
       or octet_length(r.manifest_signature) <> 64)
  union all
  select 'required_artifacts', count(*)
    from wali.wallpaper_releases r
   where r.status = 'published'
     and 4 <> (
       select count(*) from wali.release_artifacts ra
        where ra.release_id = r.id
          and ra.role in ('thumbnail', 'poster', 'preview', 'video_default')
     )
  union all
  select 'artifact_paths', count(*)
    from wali.artifacts a
   where a.storage_bucket <> 'catalog-public'
      or a.storage_path !~ ('^sha256/' || substring(a.digest from 1 for 2)
        || '/' || substring(a.digest from 3 for 2) || '/' || a.digest || '/')
  union all
  select 'revocation_release', count(*)
    from wali.catalog_revocations cr
    left join wali.wallpaper_releases r on r.id = cr.release_id
   where r.id is null
)
select name || '=' || violations from checks where violations <> 0 order by name;
rollback;
SQL
)

if [ -n "$violations" ]; then
  echo "restore integrity violations:" >&2
  echo "$violations" >&2
  exit 1
fi

echo "isolated database and object restore integrity verified"
