-- Pré-cadastro: interessados que se cadastram pelo app antes de virar cliente.
-- (006a) alter type public.status_cliente add value if not exists 'pre_cadastro';
-- Pré-cadastro ainda não tem CPF/CNPJ nem placa, então esses campos passam a aceitar vazio.
alter table public.clientes alter column documento drop not null;
alter table public.veiculos alter column placa drop not null;

create or replace view public.v_clientes with (security_invoker = true) as
select c.*,
  (select count(*) from public.veiculos v where v.cliente_id = c.id and v.ativo) as qtd_veiculos,
  p.id as cobranca_aberta_id,
  p.vencimento as proximo_vencimento,
  p.valor as valor_aberto,
  case when p.vencimento < (now() at time zone 'America/Sao_Paulo')::date
       then public.dias_uteis_entre(p.vencimento, (now() at time zone 'America/Sao_Paulo')::date) else 0 end as dias_uteis_atraso,
  case
    when c.status::text = 'pre_cadastro' then 'pre_cadastro'
    when c.status = 'cancelado' then 'cancelado'
    when p.id is null then 'em_dia'
    when p.vencimento < (now() at time zone 'America/Sao_Paulo')::date then 'inadimplente'
    else 'a_vencer'
  end as situacao
from public.clientes c
left join lateral (
  select * from public.cobrancas cb
  where cb.cliente_id = c.id and cb.status = 'pendente'
  order by cb.vencimento asc limit 1
) p on true;
