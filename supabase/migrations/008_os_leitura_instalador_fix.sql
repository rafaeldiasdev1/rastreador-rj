-- Correção: o instalador não lia as próprias fotos (a política consultava ordens_servico sob RLS).
create or replace function public.os_e_do_instalador(p_os text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.ordens_servico o
                 where o.id::text = p_os and o.instalador_id = (select auth.uid()));
$$;
grant execute on function public.os_e_do_instalador(text) to authenticated;

drop policy instalador_le on public.os_fotos;
create policy instalador_le on public.os_fotos for select
  using (public.os_e_do_instalador(os_id::text));

drop policy instalacoes_instalador_le on storage.objects;
create policy instalacoes_instalador_le on storage.objects for select
  using (bucket_id = 'instalacoes' and public.os_e_do_instalador((storage.foldername(name))[1]));
