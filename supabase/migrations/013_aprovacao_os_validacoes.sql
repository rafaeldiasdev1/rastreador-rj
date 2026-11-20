-- RJ Domótica · Melhorias da área do instalador (20/11/2026)
-- 1. Ao encerrar, a OS fica "aguardando aprovação": o pagamento só é liberado quando o admin aprova.
-- 2. Nova função os_aprovar (admin) libera o pagamento.
-- 3. A OS só pode ser iniciada a partir do dia agendado (horário de Brasília).
-- 4. IMEI validado pelo dígito verificador (Luhn) em cadastros novos ou alterados.
-- 5. admin_os_do_cliente devolve data e endereço da visita (para conferir a distância das fotos).

alter table public.ordens_servico add column if not exists aprovada_em timestamptz;

-- 1. Encerramento: pagamento fica pendente até a aprovação
create or replace function public.os_encerrar(p_os uuid, p_responsavel_nome text, p_responsavel_documento text, p_observacoes text, p_assinatura_path text, p_lat double precision, p_lng double precision)
returns jsonb language plpgsql security definer set search_path to '' as $function$
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
    status = 'concluida', concluida_em = now(), pagamento_status = 'pendente', aprovada_em = null, motivo_reprovacao = null,
    responsavel_nome = btrim(p_responsavel_nome), responsavel_documento = nullif(btrim(p_responsavel_documento), ''),
    observacoes_finais = btrim(p_observacoes), assinatura_path = p_assinatura_path,
    assinatura_lat = p_lat, assinatura_lng = p_lng
  where id = p_os;
  insert into public.historico (cliente_id, tipo, detalhe, autor)
  select cliente_id, 'instalacao', 'OS ' || numero || ' (' || tipo || ') encerrada pelo instalador, aguardando aprovação', (select nome from public.instaladores where user_id = auth.uid())
  from public.ordens_servico where id = p_os;
  return jsonb_build_object('ok', true);
end; $function$;

-- 2. Aprovação pelo administrador
create or replace function public.os_aprovar(p_os uuid)
returns void language plpgsql security definer set search_path to '' as $function$
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  update public.ordens_servico set pagamento_status = 'liberado', aprovada_em = now()
  where id = p_os and status = 'concluida' and pagamento_status = 'pendente';
  if not found then raise exception 'Esta OS não está aguardando aprovação.'; end if;
  insert into public.historico (cliente_id, tipo, detalhe, autor)
  select cliente_id, 'instalacao', 'OS ' || numero || ' aprovada; pagamento do técnico liberado', 'admin'
  from public.ordens_servico where id = p_os;
end; $function$;
revoke all on function public.os_aprovar(uuid) from public, anon;
grant execute on function public.os_aprovar(uuid) to authenticated;

-- 3. Não deixa iniciar antes do dia agendado
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
  if o.status = 'aberta' and o.agendada_para is not null
     and (o.agendada_para at time zone 'America/Sao_Paulo')::date > (now() at time zone 'America/Sao_Paulo')::date then
    raise exception 'Esta OS está agendada para %. Ela só pode ser iniciada no dia da visita. Se o cliente pediu para adiantar, peça ao administrador para mudar a data.',
      to_char(o.agendada_para at time zone 'America/Sao_Paulo', 'DD/MM/YYYY "às" HH24:MI');
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

-- 4. IMEI com dígito verificador (vale para cadastros novos e alterações; registros antigos não são barrados)
create or replace function public.imei_valido(p text)
returns boolean language plpgsql immutable set search_path = '' as $function$
declare s int := 0; d int; i int;
begin
  if p is null then return true; end if;
  if p !~ '^[0-9]{15}$' then return false; end if;
  for i in 1..15 loop
    d := substr(p, i, 1)::int;
    if i % 2 = 0 then d := d * 2; if d > 9 then d := d - 9; end if; end if;
    s := s + d;
  end loop;
  return s % 10 = 0;
end; $function$;
alter table public.veiculos drop constraint if exists veiculos_imei_valido;
alter table public.veiculos add constraint veiculos_imei_valido check (public.imei_valido(imei)) not valid;

-- 5. Admin recebe data e endereço da visita e a data de aprovação
create or replace function public.admin_os_do_cliente(p_cliente uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
begin
  if not public.is_admin() then raise exception 'Somente administradores.'; end if;
  return jsonb_build_object(
    'cliente', (select jsonb_build_object('id', c.id, 'nome', c.nome,
        'endereco', concat_ws(', ', nullif(concat_ws(' ', c.logradouro, c.numero), ''), c.bairro, c.cidade, c.uf))
      from public.clientes c where c.id = p_cliente),
    'instaladores', coalesce((select jsonb_agg(jsonb_build_object('user_id', i.user_id, 'nome', i.nome) order by i.nome)
                              from public.instaladores i where i.ativo), '[]'::jsonb),
    'veiculos', coalesce((select jsonb_agg(jsonb_build_object(
        'id', v.id, 'marca', v.marca, 'modelo', v.modelo, 'ano', v.ano, 'cor', v.cor, 'placa', v.placa, 'imei', v.imei,
        'ordens', coalesce((select jsonb_agg(jsonb_build_object(
            'id', o.id, 'numero', o.numero, 'tipo', o.tipo, 'descricao_servico', o.descricao_servico,
            'status', o.status, 'pagamento_status', o.pagamento_status, 'valor_instalador', o.valor_instalador,
            'tecnico', i.nome, 'tecnico_whatsapp', i.whatsapp,
            'criada_em', o.created_at, 'iniciada_em', o.iniciada_em, 'concluida_em', o.concluida_em, 'pago_em', o.pago_em,
            'aprovada_em', o.aprovada_em, 'agendada_para', o.agendada_para, 'endereco_visita', o.endereco_visita,
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
end; $function$;
