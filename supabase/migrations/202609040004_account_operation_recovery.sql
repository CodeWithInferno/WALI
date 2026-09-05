-- Resume existing account operations after relaunch, including a lost response.
-- No account selector, private paths, content, or download grants are exposed.
create or replace function public.account_operation_references_v1()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := auth.uid();
begin
  if actor is null or auth.role() <> 'authenticated' then
    raise exception using errcode = 'P0001', message = 'WALI_AUTHENTICATION_REQUIRED';
  end if;
  if not exists (select 1 from wali.profiles p
    where p.id = actor and p.status in ('active', 'deletion_pending')) then
    raise exception using errcode = 'P0001', message = 'WALI_ACCOUNT_INACTIVE';
  end if;
  return jsonb_build_object(
    'subject_id', actor,
    'export_id', (select e.id from wali.account_exports e
      where e.user_id = actor order by e.created_at desc, e.id desc limit 1),
    'deletion_id', (select d.id from wali.account_deletion_requests d
      where d.user_id = actor limit 1)
  );
end $$;
revoke all on function public.account_operation_references_v1() from public, anon;
grant execute on function public.account_operation_references_v1() to authenticated;
