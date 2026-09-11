-- A caller's account remains readable before catalog activation. Configuration
-- supplies only the optional avatar URL; it must not filter out the profile.
create or replace view public.my_profile_v1
with (security_invoker = true, security_barrier = true) as
select p.id, p.handle::text as handle, p.display_name,
  case when p.avatar_path is null then null else cfg.catalog_public_base_url || '/' || p.avatar_path end as avatar_url,
  p.status::text as status, p.revision, pref.rating_ceiling::text as rating_ceiling,
  pref.locale, pref.personalization_opt_out, pref.marketing_opt_out, pref.revision as preferences_revision
from wali.profiles p
join wali.user_preferences pref on pref.user_id = p.id
left join wali.runtime_configuration cfg on cfg.singleton
where p.id = auth.uid();
