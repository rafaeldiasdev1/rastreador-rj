-- RJ Domótica · Área do instalador: ordens de serviço, fotos obrigatórias com localização,
-- assinatura do responsável e curso com acesso restrito.
-- Projeto Supabase: rastreador-rj. Migração só de acréscimo (não altera tabelas existentes,
-- exceto um gatilho novo em public.veiculos que abre a ordem de serviço).

-- ───────────────────────── Tipos ─────────────────────────
create type public.tipo_os as enum ('instalacao', 'manutencao', 'retirada');
create type public.status_os as enum ('aberta', 'em_execucao', 'concluida', 'reprovada', 'cancelada');
create type public.status_pagamento_os as enum ('pendente', 'liberado', 'pago', 'bloqueado');
create type public.tipo_foto_os as enum (
  'rastreador_imei',    -- rastreador com a numeração (IMEI) legível
  'local_acomodacao',   -- local onde o rastreador foi acomodado
  'bomba_solda',        -- fio da bomba cortado e emendado com solda
  'bomba_isolada',      -- a mesma emenda já isolada
  'local_afastada'      -- foto afastada do local onde o rastreador ficou escondido
);

-- ───────────────────────── Instaladores ─────────────────────────
create table public.instaladores (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nome text not null,
  documento text,
  whatsapp text,
  chave_pix text,
  valor_padrao numeric(10,2) check (valor_padrao is null or valor_padrao >= 0),
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.instaladores enable row level security;

create or replace function public.is_instalador()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.instaladores where user_id = (select auth.uid()) and ativo);
$$;

create policy admin_tudo on public.instaladores for all
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy instalador_le_proprio on public.instaladores for select
  using (user_id = (select auth.uid()));

-- ───────────────────────── Ordens de serviço ─────────────────────────
create table public.ordens_servico (
  id uuid primary key default gen_random_uuid(),
  numero bigint generated always as identity (start with 1001) unique,
  tipo public.tipo_os not null default 'instalacao',
  descricao_servico text,
  cliente_id uuid not null references public.clientes(id),
  veiculo_id uuid references public.veiculos(id),
  instalador_id uuid references public.instaladores(user_id),
  status public.status_os not null default 'aberta',
  valor_instalador numeric(10,2) check (valor_instalador is null or valor_instalador >= 0),
  pagamento_status public.status_pagamento_os not null default 'pendente',
  pago_em timestamptz,
  iniciada_em timestamptz,
  concluida_em timestamptz,
  responsavel_nome text,
  responsavel_documento text,
  assinatura_path text,
  assinatura_lat double precision,
  assinatura_lng double precision,
  observacoes_finais text,
  motivo_reprovacao text,
  observacoes_internas text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.ordens_servico (instalador_id);
create index on public.ordens_servico (cliente_id);
create index on public.ordens_servico (veiculo_id);
create trigger tocar_updated_at before update on public.ordens_servico
  for each row execute function public.tocar_updated_at();
alter table public.ordens_servico enable row level security;

-- O instalador NÃO lê a tabela direto (ela tem dados internos); usa as funções os_* abaixo.
create policy admin_tudo on public.ordens_servico for all
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- Uma ordem de serviço por veículo novo
create or replace function public.abrir_os_do_veiculo()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.ordens_servico (cliente_id, veiculo_id) values (new.cliente_id, new.id);
  return new;
end; $$;
create trigger abrir_os after insert on public.veiculos
  for each row execute function public.abrir_os_do_veiculo();

-- ───────────────────────── Fotos ─────────────────────────
create table public.os_fotos (
  id uuid primary key default gen_random_uuid(),
  os_id uuid not null references public.ordens_servico(id) on delete cascade,
  tipo public.tipo_foto_os not null,
  path text not null,
  descricao text not null check (length(btrim(descricao)) >= 5),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  precisao_m double precision,
  geo_capturada_em timestamptz not null,
  enviada_por uuid not null default auth.uid(),
  enviada_em timestamptz not null default now(),
  unique (os_id, tipo)
);
alter table public.os_fotos enable row level security;

create or replace function public.os_editavel_pelo_instalador(p_os uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.ordens_servico o
    where o.id = p_os and o.instalador_id = (select auth.uid())
      and o.status in ('em_execucao', 'reprovada')
  ) and public.is_instalador();
$$;

create policy admin_tudo on public.os_fotos for all
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy instalador_le on public.os_fotos for select
  using (exists (select 1 from public.ordens_servico o where o.id = os_id and o.instalador_id = (select auth.uid())));
create policy instalador_insere on public.os_fotos for insert
  with check (public.os_editavel_pelo_instalador(os_id) and enviada_por = (select auth.uid()));
create policy instalador_apaga on public.os_fotos for delete
  using (public.os_editavel_pelo_instalador(os_id));

-- A localização tem de ter sido capturada no momento do envio (até 3 minutos antes, sem data futura)
create or replace function public.validar_geo_foto()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.enviada_em := now();
  if new.geo_capturada_em > now() + interval '1 minute'
     or new.geo_capturada_em < now() - interval '3 minutes' then
    raise exception 'A localização precisa ser capturada no momento do envio da foto.';
  end if;
  return new;
end; $$;
create trigger validar_geo before insert on public.os_fotos
  for each row execute function public.validar_geo_foto();

-- ───────────────────────── Funções usadas pela tela do instalador ─────────────────────────

-- Abre a OS pelo número. Se ainda não tem instalador, fica com quem abriu.
create or replace function public.os_abrir(p_numero bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
end; $$;

-- Lista as OS do instalador logado
create or replace function public.os_minhas()
returns table (numero bigint, tipo public.tipo_os, status public.status_os, pagamento_status public.status_pagamento_os,
               cliente text, placa text, concluida_em timestamptz, valor_instalador numeric)
language sql stable security definer set search_path = '' as $$
  select s.numero, s.tipo, s.status, s.pagamento_status, c.nome, v.placa, s.concluida_em, s.valor_instalador
  from public.ordens_servico s join public.clientes c on c.id = s.cliente_id
  left join public.veiculos v on v.id = s.veiculo_id
  where s.instalador_id = auth.uid() and public.is_instalador()
  order by s.created_at desc;
$$;

-- Encerra a OS: exige as 5 fotos, responsável, assinatura e localização. Libera o pagamento.
create or replace function public.os_encerrar(
  p_os uuid, p_responsavel_nome text, p_responsavel_documento text,
  p_observacoes text, p_assinatura_path text, p_lat double precision, p_lng double precision)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare faltam text[];
begin
  if not public.os_editavel_pelo_instalador(p_os) then
    raise exception 'Esta ordem de serviço não pode ser encerrada pelo seu usuário.';
  end if;
  if (select tipo from public.ordens_servico where id = p_os) = 'instalacao' then
    select array_agg(t::text) into faltam
    from unnest(enum_range(null::public.tipo_foto_os)) t
    where not exists (select 1 from public.os_fotos f where f.os_id = p_os and f.tipo = t);
    if faltam is not null then
      raise exception 'Faltam fotos obrigatórias: %', array_to_string(faltam, ', ');
    end if;
  elsif not exists (select 1 from public.os_fotos f where f.os_id = p_os) then
    raise exception 'Envie pelo menos uma foto do serviço realizado.';
  end if;
  if length(btrim(coalesce(p_responsavel_nome, ''))) < 3 then
    raise exception 'Informe o nome do responsável pelo veículo.';
  end if;
  if length(btrim(coalesce(p_observacoes, ''))) < 10 then
    raise exception 'Preencha as observações finais.';
  end if;
  if p_assinatura_path is null or p_assinatura_path not like p_os::text || '/%' then
    raise exception 'Colete a assinatura do responsável.';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Localização obrigatória para encerrar.';
  end if;
  update public.ordens_servico set
    status = 'concluida', concluida_em = now(), pagamento_status = 'liberado', motivo_reprovacao = null,
    responsavel_nome = btrim(p_responsavel_nome), responsavel_documento = nullif(btrim(p_responsavel_documento), ''),
    observacoes_finais = btrim(p_observacoes), assinatura_path = p_assinatura_path,
    assinatura_lat = p_lat, assinatura_lng = p_lng
  where id = p_os;
  insert into public.historico (cliente_id, tipo, detalhe, autor)
  select cliente_id, 'instalacao', 'OS ' || numero || ' (' || tipo || ') encerrada pelo instalador', (select nome from public.instaladores where user_id = auth.uid())
  from public.ordens_servico where id = p_os;
  return jsonb_build_object('ok', true);
end; $$;

-- Admin: reprovar (volta para o instalador corrigir e bloqueia o pagamento) e marcar como pago
create or replace function public.os_reprovar(p_os uuid, p_motivo text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  update public.ordens_servico set status = 'reprovada', pagamento_status = 'bloqueado', motivo_reprovacao = p_motivo
  where id = p_os and status = 'concluida';
end; $$;

create or replace function public.os_marcar_pago(p_os uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  update public.ordens_servico set pagamento_status = 'pago', pago_em = now()
  where id = p_os and pagamento_status = 'liberado';
end; $$;


-- ───────────────────────── Funções do painel admin ─────────────────────────

-- Abre uma OS de manutenção (ou retirada) para um veículo
create or replace function public.os_criar(p_veiculo uuid, p_tipo public.tipo_os, p_descricao text,
  p_instalador uuid default null, p_valor numeric default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare n bigint;
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  insert into public.ordens_servico (cliente_id, veiculo_id, tipo, descricao_servico, instalador_id, valor_instalador)
  select v.cliente_id, v.id, p_tipo, nullif(btrim(p_descricao), ''), p_instalador,
         coalesce(p_valor, (select valor_padrao from public.instaladores where user_id = p_instalador))
  from public.veiculos v where v.id = p_veiculo
  returning numero into n;
  if n is null then raise exception 'Veículo não encontrado.'; end if;
  return n;
end; $$;

-- Tudo sobre instalação e manutenções dos veículos de um cliente, para o painel
create or replace function public.admin_os_do_cliente(p_cliente uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  return jsonb_build_object(
    'cliente', (select jsonb_build_object('id', c.id, 'nome', c.nome) from public.clientes c where c.id = p_cliente),
    'instaladores', coalesce((select jsonb_agg(jsonb_build_object('user_id', i.user_id, 'nome', i.nome) order by i.nome)
                              from public.instaladores i where i.ativo), '[]'::jsonb),
    'veiculos', coalesce((select jsonb_agg(jsonb_build_object(
        'id', v.id, 'marca', v.marca, 'modelo', v.modelo, 'ano', v.ano, 'cor', v.cor, 'placa', v.placa, 'imei', v.imei,
        'ordens', coalesce((select jsonb_agg(jsonb_build_object(
            'id', o.id, 'numero', o.numero, 'tipo', o.tipo, 'descricao_servico', o.descricao_servico,
            'status', o.status, 'pagamento_status', o.pagamento_status, 'valor_instalador', o.valor_instalador,
            'tecnico', i.nome, 'tecnico_whatsapp', i.whatsapp,
            'criada_em', o.created_at, 'iniciada_em', o.iniciada_em, 'concluida_em', o.concluida_em, 'pago_em', o.pago_em,
            'responsavel_nome', o.responsavel_nome, 'responsavel_documento', o.responsavel_documento,
            'assinatura_path', o.assinatura_path, 'assinatura_lat', o.assinatura_lat, 'assinatura_lng', o.assinatura_lng,
            'observacoes_finais', o.observacoes_finais, 'motivo_reprovacao', o.motivo_reprovacao,
            'fotos', coalesce((select jsonb_agg(jsonb_build_object('tipo', f.tipo, 'path', f.path, 'descricao', f.descricao,
                'latitude', f.latitude, 'longitude', f.longitude, 'precisao_m', f.precisao_m, 'enviada_em', f.enviada_em)
                order by f.tipo) from public.os_fotos f where f.os_id = o.id), '[]'::jsonb)
          ) order by o.created_at desc)
          from public.ordens_servico o left join public.instaladores i on i.user_id = o.instalador_id
          where o.veiculo_id = v.id), '[]'::jsonb)
      ) order by v.created_at) from public.veiculos v where v.cliente_id = p_cliente), '[]'::jsonb));
end; $$;

create or replace function public.os_atribuir(p_os uuid, p_instalador uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  update public.ordens_servico set instalador_id = p_instalador,
    valor_instalador = coalesce(valor_instalador, (select valor_padrao from public.instaladores where user_id = p_instalador))
  where id = p_os and status in ('aberta', 'em_execucao', 'reprovada');
end; $$;

revoke execute on function public.os_abrir(bigint), public.os_minhas(),
  public.os_encerrar(uuid, text, text, text, text, double precision, double precision),
  public.os_reprovar(uuid, text), public.os_marcar_pago(uuid),
  public.os_criar(uuid, public.tipo_os, text, uuid, numeric), public.admin_os_do_cliente(uuid),
  public.os_atribuir(uuid, uuid) from public, anon;
grant execute on function public.os_abrir(bigint), public.os_minhas(),
  public.os_encerrar(uuid, text, text, text, text, double precision, double precision),
  public.os_reprovar(uuid, text), public.os_marcar_pago(uuid), public.is_instalador(),
  public.os_criar(uuid, public.tipo_os, text, uuid, numeric), public.admin_os_do_cliente(uuid),
  public.os_atribuir(uuid, uuid) to authenticated;

-- ───────────────────────── Storage ─────────────────────────
-- instalacoes: fotos e assinaturas, pasta = id da OS. curso: apostila, vídeos e conteúdo das aulas.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('instalacoes', 'instalacoes', false, 10485760, array['image/jpeg', 'image/png', 'image/webp']),
  ('curso', 'curso', false, 52428800, array['application/pdf', 'video/mp4', 'audio/mpeg', 'text/html'])
on conflict (id) do nothing;

create policy instalacoes_admin on storage.objects for all
  using (bucket_id = 'instalacoes' and (select public.is_admin()))
  with check (bucket_id = 'instalacoes' and (select public.is_admin()));
create policy instalacoes_instalador_envia on storage.objects for insert
  with check (bucket_id = 'instalacoes'
    and public.os_editavel_pelo_instalador(((storage.foldername(name))[1])::uuid));
create policy instalacoes_instalador_le on storage.objects for select
  using (bucket_id = 'instalacoes' and exists (
    select 1 from public.ordens_servico o
    where o.id::text = (storage.foldername(name))[1] and o.instalador_id = (select auth.uid())));

create policy curso_le on storage.objects for select
  using (bucket_id = 'curso' and ((select public.is_instalador()) or (select public.is_admin())));
create policy curso_admin on storage.objects for all
  using (bucket_id = 'curso' and (select public.is_admin()))
  with check (bucket_id = 'curso' and (select public.is_admin()));
