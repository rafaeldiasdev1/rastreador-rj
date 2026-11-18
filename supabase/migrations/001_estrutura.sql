-- RJ Domótica · Plataforma de rastreamento
-- Estrutura: administradores, clientes, veículos, cobranças, mensagens, feriados e configurações.

-- ---------- administradores ----------
create table public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  nome text,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = (select auth.uid()));
$$;

-- ---------- tipos ----------
create type public.status_cliente as enum ('ativo', 'bloqueado', 'cancelado');
create type public.status_cobranca as enum ('pendente', 'pago', 'cancelado');

-- ---------- clientes ----------
create table public.clientes (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  tipo_pessoa text not null default 'PF' check (tipo_pessoa in ('PF', 'PJ')),
  documento text not null unique,               -- CPF ou CNPJ, só números
  email text not null,
  whatsapp text not null,                       -- com DDI e DDD, só números: 5521999999999
  telefone2 text,
  cep text, logradouro text, numero text, complemento text, bairro text, cidade text, uf char(2),
  valor_mensal numeric(10,2) not null check (valor_mensal > 0),
  dia_vencimento int not null check (dia_vencimento between 1 and 28),
  status public.status_cliente not null default 'ativo',
  bloqueado_em timestamptz,
  motivo_bloqueio text,
  login_app text,                               -- e-mail de acesso ao app (usuário no Traccar)
  traccar_user_id bigint,
  escuta_liberada boolean not null default false,
  observacoes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- veículos ----------
create table public.veiculos (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes (id) on delete cascade,
  marca text not null,
  modelo text not null,
  ano int,
  cor text,
  placa text not null unique,
  imei text unique,                             -- IMEI do rastreador
  modelo_rastreador text default 'J16 4G',
  chip_numero text,                             -- número do chip do rastreador
  chip_operadora text,
  traccar_device_id bigint,
  escuta boolean not null default false,        -- microfone liberado neste veículo
  ativo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.veiculos (cliente_id);

-- ---------- cobranças ----------
create table public.cobrancas (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes (id) on delete cascade,
  competencia date not null,                    -- primeiro dia do mês de referência
  valor numeric(10,2) not null,
  vencimento date not null,
  status public.status_cobranca not null default 'pendente',
  pago_em timestamptz,
  valor_pago numeric(10,2),
  forma_pagamento text,                         -- pix, boleto, manual
  mp_boleto_id text, boleto_url text, boleto_codigo text,
  mp_pix_id text, pix_copia_cola text, pix_qr_base64 text, pix_url text,
  erro_geracao text,
  enviado_em timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (cliente_id, competencia)
);
create index on public.cobrancas (status, vencimento);

-- ---------- mensagens enviadas (e-mail e WhatsApp) ----------
create table public.mensagens (
  id bigint generated always as identity primary key,
  cliente_id uuid references public.clientes (id) on delete set null,
  cobranca_id uuid references public.cobrancas (id) on delete set null,
  canal text not null check (canal in ('email', 'whatsapp')),
  tipo text not null,                           -- cobranca, lembrete, vencida, bloqueio, pagamento
  destino text,
  status text not null,                         -- enviado, erro, simulado
  detalhe text,
  created_at timestamptz not null default now()
);
create index on public.mensagens (cliente_id, created_at desc);
create index on public.mensagens (cobranca_id);

-- ---------- histórico de ações ----------
create table public.historico (
  id bigint generated always as identity primary key,
  cliente_id uuid references public.clientes (id) on delete cascade,
  tipo text not null,
  detalhe text,
  autor text,                                   -- e-mail do admin ou "automático"
  created_at timestamptz not null default now()
);
create index on public.historico (cliente_id, created_at desc);

-- ---------- feriados (para contar dias úteis) ----------
create table public.feriados (data date primary key, nome text not null);

-- ---------- configurações ----------
create table public.configuracoes (chave text primary key, valor jsonb not null, descricao text);
insert into public.configuracoes (chave, valor, descricao) values
  ('dias_antecedencia_cobranca', '10', 'Quantos dias antes do vencimento a cobrança é gerada e enviada'),
  ('dias_lembrete', '[3, 0]', 'Dias antes do vencimento para lembrar (0 = no dia)'),
  ('dias_uteis_bloqueio', '2', 'Dias úteis de atraso para bloquear o acesso'),
  ('nome_empresa', '"RJ Domótica"', 'Nome que aparece nas mensagens'),
  ('whatsapp_templates', '{"cobranca":"rj_cobranca","lembrete":"rj_lembrete","vencida":"rj_vencida","bloqueio":"rj_bloqueio","pagamento":"rj_pagamento"}', 'Nomes dos modelos aprovados na Meta');

-- Segredo interno da rotina agendada (sem acesso pela API pública)
create table public.segredos_internos (chave text primary key, valor text not null);
insert into public.segredos_internos values ('cron', encode(gen_random_bytes(24), 'hex'));

-- ---------- dias úteis ----------
create or replace function public.dias_uteis_entre(inicio date, fim date)
returns int language sql stable set search_path = '' as $$
  -- dias úteis depois de "inicio" até "fim" (inclusive)
  select count(*)::int
  from generate_series(inicio + 1, fim, interval '1 day') d
  where extract(isodow from d) < 6
    and not exists (select 1 from public.feriados f where f.data = d::date);
$$;

-- ---------- situação financeira por cliente ----------
create or replace view public.v_clientes with (security_invoker = true) as
select c.*,
  (select count(*) from public.veiculos v where v.cliente_id = c.id and v.ativo) as qtd_veiculos,
  p.id as cobranca_aberta_id,
  p.vencimento as proximo_vencimento,
  p.valor as valor_aberto,
  case when p.vencimento < (now() at time zone 'America/Sao_Paulo')::date
       then public.dias_uteis_entre(p.vencimento, (now() at time zone 'America/Sao_Paulo')::date) else 0 end as dias_uteis_atraso,
  case
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

-- ---------- updated_at ----------
create or replace function public.tocar_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end; $$;
create trigger t_clientes before update on public.clientes for each row execute function public.tocar_updated_at();
create trigger t_veiculos before update on public.veiculos for each row execute function public.tocar_updated_at();
create trigger t_cobrancas before update on public.cobrancas for each row execute function public.tocar_updated_at();

-- ---------- segurança: só administradores ----------
alter table public.admins enable row level security;
alter table public.clientes enable row level security;
alter table public.veiculos enable row level security;
alter table public.cobrancas enable row level security;
alter table public.mensagens enable row level security;
alter table public.historico enable row level security;
alter table public.feriados enable row level security;
alter table public.configuracoes enable row level security;
alter table public.segredos_internos enable row level security;   -- sem políticas: ninguém acessa pela API

create policy admin_le_admins on public.admins for select to authenticated using ((select public.is_admin()));
create policy admin_tudo on public.clientes for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_tudo on public.veiculos for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_tudo on public.cobrancas for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_le on public.mensagens for select to authenticated using ((select public.is_admin()));
create policy admin_le on public.historico for select to authenticated using ((select public.is_admin()));
create policy admin_insere on public.historico for insert to authenticated with check ((select public.is_admin()));
create policy admin_tudo on public.feriados for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_tudo on public.configuracoes for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

revoke execute on function public.is_admin() from anon;

-- ajuste de permissões (aplicado como migração separada)
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;
revoke execute on function public.dias_uteis_entre(date, date) from public, anon;
grant execute on function public.dias_uteis_entre(date, date) to authenticated, service_role;
