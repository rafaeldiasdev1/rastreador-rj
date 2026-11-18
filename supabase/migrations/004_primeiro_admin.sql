-- Torna administrador quem chamar, somente enquanto ainda não existir nenhum administrador.
create or replace function public.primeiro_admin(p_nome text default null)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then return false; end if;
  if exists (select 1 from public.admins) then
    return exists (select 1 from public.admins where user_id = (select auth.uid()));
  end if;
  insert into public.admins (user_id, nome) values ((select auth.uid()), p_nome);
  return true;
end; $$;
revoke execute on function public.primeiro_admin(text) from public, anon;
grant execute on function public.primeiro_admin(text) to authenticated;
