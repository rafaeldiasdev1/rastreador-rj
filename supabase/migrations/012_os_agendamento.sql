-- Agendamento das ordens de serviço: data/hora e endereço da visita técnica.
alter table public.ordens_servico
  add column if not exists agendada_para timestamptz,
  add column if not exists endereco_visita text;
create index if not exists ordens_servico_agendada_para on public.ordens_servico (agendada_para);
comment on column public.ordens_servico.agendada_para is 'Data e hora marcadas para a visita técnica';
comment on column public.ordens_servico.endereco_visita is 'Endereço onde o técnico vai atender (pode ser diferente do cadastro do cliente)';

-- O instalador passa a ver data, hora e endereço da visita (precisa disso para ir ao local)
drop function if exists public.os_minhas();
create function public.os_minhas()
returns table(numero bigint, tipo public.tipo_os, status public.status_os, pagamento_status public.status_pagamento_os,
              cliente text, placa text, concluida_em timestamptz, valor_instalador numeric,
              agendada_para timestamptz, endereco_visita text)
language sql stable security definer set search_path = '' as $$
  select s.numero, s.tipo, s.status, s.pagamento_status, c.nome, v.placa, s.concluida_em, s.valor_instalador,
         s.agendada_para, s.endereco_visita
  from public.ordens_servico s join public.clientes c on c.id = s.cliente_id
  left join public.veiculos v on v.id = s.veiculo_id
  where s.instalador_id = auth.uid() and public.is_instalador()
  order by coalesce(s.agendada_para, s.created_at) desc;
$$;
revoke all on function public.os_minhas() from public, anon;
grant execute on function public.os_minhas() to authenticated;

create or replace function public.os_abrir(p_numero bigint)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare o public.ordens_servico; r jsonb;
begin
  if not public.is_instalador() then raise exception 'Acesso restrito a instaladores.'; end if;
  select * into o from public.ordens_servico where numero = p_numero for update;
  if not found or o.status = 'cancelada'
     or (o.instalador_id is not null and o.instalador_id <> auth.uid()) then
    raise exception 'Ordem de serviço não encontrada para o seu usuário.';
  end if;
  if o.instalador_id is null then
    update public.ordens_servico set instalador_id = auth.uid(),
      valor_instalador = coalesce(valor_instalador, (select valor_padrao from public.instaladores where user_id = auth.uid()))
      where id = o.id;
  end if;
  if o.status = 'aberta' then
    update public.ordens_servico set status = 'em_execucao', iniciada_em = now() where id = o.id;
  end if;
  select jsonb_build_object(
    'id', s.id, 'numero', s.numero, 'tipo', s.tipo, 'descricao_servico', s.descricao_servico, 'status', s.status, 'pagamento_status', s.pagamento_status,
    'motivo_reprovacao', s.motivo_reprovacao,
    'responsavel_nome', s.responsavel_nome, 'observacoes_finais', s.observacoes_finais,
    'agendada_para', s.agendada_para, 'endereco_visita', s.endereco_visita,
    'cliente', c.nome, 'cidade', c.cidade, 'bairro', c.bairro,
    'veiculo', case when v.id is null then null else jsonb_build_object(
      'marca', v.marca, 'modelo', v.modelo, 'ano', v.ano, 'cor', v.cor, 'placa', v.placa,
      'tipo', v.tipo, 'imei', v.imei) end,
    'fotos', coalesce((select jsonb_agg(jsonb_build_object('tipo', f.tipo, 'path', f.path, 'descricao', f.descricao,
      'latitude', f.latitude, 'longitude', f.longitude, 'enviada_em', f.enviada_em)) from public.os_fotos f where f.os_id = s.id), '[]'::jsonb))
  into r
  from public.ordens_servico s join public.clientes c on c.id = s.cliente_id
  left join public.veiculos v on v.id = s.veiculo_id
  where s.id = o.id;
  return r;
end; $function$;
