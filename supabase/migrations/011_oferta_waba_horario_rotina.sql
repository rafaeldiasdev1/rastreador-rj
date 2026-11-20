-- Oferta (preços e data de estreia), conta do WhatsApp e horário da rotina: tudo editável pelo painel.

insert into public.configuracoes (chave, valor, descricao) values
  ('oferta', '{"preco_cheio": 64.90, "preco_promo": 54.90, "meses_promo": 12, "instalacao_cheia": 99.90, "instalacao_promo": 49.95, "data_estreia": "2027-01-04"}'::jsonb,
   'Preços do app e do pré-cadastro e data de estreia (mostrados no app e nas mensagens)'),
  ('whatsapp_waba_id', '"676253188869076"'::jsonb,
   'Identificação da conta do WhatsApp Business (WABA) usada para consultar os modelos na Meta')
on conflict (chave) do nothing;

-- Horário da rotina diária (cron em UTC; o painel trabalha no horário de Brasília, UTC-3)
create or replace function public.horario_rotina()
returns text language plpgsql security definer set search_path = '' as $$
declare s text; m int; h int;
begin
  if not public.is_admin() then raise exception 'Acesso restrito ao administrador.'; end if;
  select schedule into s from cron.job where jobname = 'rotina-cobranca-diaria';
  if s is null then return null; end if;
  m := split_part(s, ' ', 1)::int; h := split_part(s, ' ', 2)::int;
  return lpad(((h + 21) % 24)::text, 2, '0') || ':' || lpad(m::text, 2, '0');
end; $$;

create or replace function public.definir_horario_rotina(p_hora int, p_minuto int)
returns text language plpgsql security definer set search_path = '' as $$
declare j bigint;
begin
  if not public.is_admin() then raise exception 'Acesso restrito ao administrador.'; end if;
  if p_hora is null or p_minuto is null or p_hora not between 0 and 23 or p_minuto not between 0 and 59 then
    raise exception 'Horário inválido.';
  end if;
  select jobid into j from cron.job where jobname = 'rotina-cobranca-diaria';
  if j is null then raise exception 'Rotina diária não encontrada.'; end if;
  perform cron.alter_job(job_id := j, schedule := p_minuto || ' ' || ((p_hora + 3) % 24) || ' * * *');
  return public.horario_rotina();
end; $$;

revoke all on function public.horario_rotina() from public, anon;
revoke all on function public.definir_horario_rotina(int, int) from public, anon;
grant execute on function public.horario_rotina() to authenticated;
grant execute on function public.definir_horario_rotina(int, int) to authenticated;
