// RJ Domótica · API da plataforma
// Rotas:
//   POST /api/admin       ações do painel (exige login de administrador)
//   POST /api/pre-cadastro  interessados se cadastram pelo app (pública, com limites)
//   POST /api/rotina      rotina diária: gera cobranças, lembra, bloqueia (chamada pelo agendador)
//   POST /api/webhook-mp  avisos de pagamento do Mercado Pago
// Integrações ligam sozinhas quando os segredos existem. Sem eles, tudo roda em modo "simulado".
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_SB = Deno.env.get("SUPABASE_URL")!;
const db = createClient(URL_SB, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const env = (k: string) => (Deno.env.get(k) || "").trim();

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
const json = (d: unknown, s = 200) => new Response(JSON.stringify(d), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

// ---------------- datas (fuso de São Paulo) ----------------
const diaSP = (d: Date | string = new Date()) => new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" }).format(new Date(d));
const hojeSP = () => diaSP();
const addDias = (d: string, n: number) => { const x = new Date(d + "T12:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const diffDias = (a: string, b: string) => Math.round((Date.parse(b + "T12:00:00Z") - Date.parse(a + "T12:00:00Z")) / 864e5);
const util = (d: string, fer: Set<string>) => { const w = new Date(d + "T12:00:00Z").getUTCDay(); return w !== 0 && w !== 6 && !fer.has(d); };
function diasUteisEntre(a: string, b: string, fer: Set<string>) { let c = 0, x = a; while (x < b) { x = addDias(x, 1); if (util(x, fer)) c++; } return c; }
function somarDiasUteis(d: string, n: number, fer: Set<string>) { let x = d, c = 0; while (c < n) { x = addDias(x, 1); if (util(x, fer)) c++; } return x; }
const brl = (v: number) => Number(v).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const dataBR = (d?: string) => (d ? d.slice(0, 10).split("-").reverse().join("/") : "");
const mesBR = (c: string) => new Date(c + "T12:00:00Z").toLocaleDateString("pt-BR", { month: "long", year: "numeric", timeZone: "UTC" });
const competenciaDe = (d: string) => d.slice(0, 8) + "01";
const vencimentoDe = (competencia: string, dia: number) => competencia.slice(0, 8) + String(dia).padStart(2, "0");
const primeiroNome = (n: string) => n.trim().split(/\s+/)[0];

// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;

async function config(): Promise<Obj> {
  const { data } = await db.from("configuracoes").select("chave,valor");
  return Object.fromEntries((data || []).map((r) => [r.chave, r.valor]));
}
async function feriados() {
  const { data } = await db.from("feriados").select("data");
  return new Set((data || []).map((r) => r.data as string));
}
async function registrar(cliente_id: string | null, tipo: string, detalhe: string, autor = "automático") {
  await db.from("historico").insert({ cliente_id, tipo, detalhe, autor });
}

// ---------------- Traccar (servidor do rastreador) ----------------
const traccarOn = () => !!(env("TRACCAR_URL") && env("TRACCAR_ADMIN_EMAIL") && env("TRACCAR_ADMIN_SENHA"));
async function traccar(path: string, opt: RequestInit = {}) {
  const r = await fetch(env("TRACCAR_URL").replace(/\/+$/, "") + path, {
    ...opt,
    headers: {
      Authorization: "Basic " + btoa(env("TRACCAR_ADMIN_EMAIL") + ":" + env("TRACCAR_ADMIN_SENHA")),
      "Content-Type": "application/json", Accept: "application/json",
    },
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`Traccar ${path}: HTTP ${r.status} ${t.slice(0, 160)}`);
  return t ? JSON.parse(t) : null;
}
async function traccarAcesso(cli: Obj, liberado: boolean) {
  if (!traccarOn() || !cli.traccar_user_id) return "servidor do rastreador não configurado";
  const u = await traccar(`/api/users/${cli.traccar_user_id}`);
  u.disabled = !liberado;
  await traccar(`/api/users/${cli.traccar_user_id}`, { method: "PUT", body: JSON.stringify(u) });
  return liberado ? "acesso liberado no app" : "acesso bloqueado no app";
}
async function sincronizar(cliente_id: string, senha?: string) {
  if (!traccarOn()) return { ok: false, aviso: "Servidor do rastreador ainda não configurado. Os dados ficam salvos e são enviados quando ele estiver no ar." };
  const { data: cli } = await db.from("clientes").select("*").eq("id", cliente_id).single();
  if (cli.status === "pre_cadastro") return { ok: false, aviso: "Este é um pré-cadastro. Complete os dados e marque como Ativo para criar o login no rastreador." };
  const { data: veics } = await db.from("veiculos").select("*").eq("cliente_id", cliente_id);
  const login = cli.login_app || cli.email;
  let uid = cli.traccar_user_id;
  const base = { name: cli.nome, email: login, phone: cli.whatsapp, disabled: cli.status !== "ativo", readonly: false, deviceReadonly: true, limitCommands: false };
  if (uid) {
    const u = await traccar(`/api/users/${uid}`);
    Object.assign(u, base); if (senha) u.password = senha;
    await traccar(`/api/users/${uid}`, { method: "PUT", body: JSON.stringify(u) });
  } else {
    if (!senha) throw new Error("Defina uma senha de acesso para criar o login do cliente no app.");
    uid = (await traccar("/api/users", { method: "POST", body: JSON.stringify({ ...base, password: senha }) })).id;
  }
  await db.from("clientes").update({ traccar_user_id: uid, login_app: login }).eq("id", cliente_id);
  const res: string[] = [];
  for (const v of veics || []) {
    if (!v.imei) { res.push(`${v.placa}: falta o IMEI do rastreador`); continue; }
    const attrs = { escuta: !!(v.escuta && cli.escuta_liberada), placa: v.placa, tipo: v.tipo || "carro", marca: v.marca, modelo: v.modelo, cor: v.cor || "", ano: v.ano || "" };
    const dev = { name: `${v.marca} ${v.modelo} · ${v.placa}`, uniqueId: v.imei, phone: v.chip_numero || "", model: v.modelo_rastreador || "", category: ({ carro: "car", moto: "motorcycle", caminhao: "truck" } as Record<string, string>)[v.tipo] || "default", disabled: !v.ativo };
    let did = v.traccar_device_id;
    if (did) {
      const d = await traccar(`/api/devices/${did}`);
      Object.assign(d, dev); d.attributes = { ...(d.attributes || {}), ...attrs };
      await traccar(`/api/devices/${did}`, { method: "PUT", body: JSON.stringify(d) });
    } else {
      const ex = await traccar(`/api/devices?uniqueId=${encodeURIComponent(v.imei)}`).catch(() => []);
      did = ex && ex.length ? ex[0].id : (await traccar("/api/devices", { method: "POST", body: JSON.stringify({ ...dev, attributes: attrs }) })).id;
      if (ex && ex.length) { const d = ex[0]; Object.assign(d, dev); d.attributes = { ...(d.attributes || {}), ...attrs }; await traccar(`/api/devices/${did}`, { method: "PUT", body: JSON.stringify(d) }); }
      await db.from("veiculos").update({ traccar_device_id: did }).eq("id", v.id);
    }
    await traccar("/api/permissions", { method: "POST", body: JSON.stringify({ userId: uid, deviceId: did }) }).catch(() => null);
    res.push(`${v.placa}: ok`);
  }
  await registrar(cliente_id, "sincronizado", "Login e veículos enviados ao servidor do rastreador. " + res.join(" · "));
  return { ok: true, resultados: res };
}

// ---------------- Mercado Pago ----------------
const mpOn = () => !!env("MP_ACCESS_TOKEN");
async function mp(path: string, opt: RequestInit & { idem?: string } = {}) {
  const h: Obj = { Authorization: "Bearer " + env("MP_ACCESS_TOKEN"), "Content-Type": "application/json" };
  if (opt.idem) h["X-Idempotency-Key"] = opt.idem;
  const r = await fetch("https://api.mercadopago.com" + path, { ...opt, headers: h });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d.message || `HTTP ${r.status}`);
  return d;
}
async function criarPagamentosMP(cli: Obj, cob: Obj, empresa: string) {
  const doc = cli.documento.replace(/\D/g, "");
  const partes = cli.nome.trim().split(/\s+/);
  const payer = { email: cli.email, first_name: partes[0], last_name: partes.slice(1).join(" ") || partes[0], identification: { type: doc.length > 11 ? "CNPJ" : "CPF", number: doc } };
  const comum = {
    transaction_amount: Number(cob.valor),
    description: `${empresa} · Mensalidade ${mesBR(cob.competencia)}`,
    external_reference: cob.id,
    notification_url: `${URL_SB}/functions/v1/api/webhook-mp`,
  };
  const upd: Obj = { erro_geracao: null };
  const erros: string[] = [];
  try {
    const b = await mp("/v1/payments", { method: "POST", idem: cob.id + "-boleto", body: JSON.stringify({
      ...comum, payment_method_id: "bolbradesco", date_of_expiration: `${cob.vencimento}T23:59:59.000-03:00`,
      payer: { ...payer, address: { zip_code: (cli.cep || "").replace(/\D/g, ""), street_name: cli.logradouro, street_number: cli.numero || "S/N", neighborhood: cli.bairro, city: cli.cidade, federal_unit: cli.uf } },
    }) });
    upd.mp_boleto_id = String(b.id);
    upd.boleto_url = b.transaction_details?.external_resource_url || null;
    upd.boleto_codigo = b.transaction_details?.digitable_line || b.barcode?.content || null;
  } catch (e) { erros.push("Boleto: " + (e as Error).message); }
  try {
    const p = await mp("/v1/payments", { method: "POST", idem: cob.id + "-pix", body: JSON.stringify({
      ...comum, payment_method_id: "pix", date_of_expiration: `${addDias(cob.vencimento, 30)}T23:59:59.000-03:00`, payer,
    }) });
    const t = p.point_of_interaction?.transaction_data || {};
    upd.mp_pix_id = String(p.id); upd.pix_copia_cola = t.qr_code || null; upd.pix_qr_base64 = t.qr_code_base64 || null; upd.pix_url = t.ticket_url || null;
  } catch (e) { erros.push("Pix: " + (e as Error).message); }
  if (erros.length) upd.erro_geracao = erros.join(" | ");
  return upd;
}

// ---------------- mensagens: e-mail (Resend) e WhatsApp (API oficial da Meta) ----------------
function conteudo(tipo: string, cli: Obj, cob: Obj | null, empresa: string, extra: Obj) {
  const nome = primeiroNome(cli.nome);
  const link = cob ? (cob.pix_url || cob.boleto_url || "") : "";
  const valor = cob ? brl(cob.valor) : "", venc = cob ? dataBR(cob.vencimento) : "", mes = cob ? mesBR(cob.competencia) : "";
  const T: Obj = {
    cobranca: { assunto: `${empresa} · Mensalidade de ${mes}`, titulo: `Sua mensalidade de ${mes} chegou`,
      texto: `Olá, ${nome}! A mensalidade do seu rastreamento está disponível: ${valor}, com vencimento em ${venc}. Você pode pagar por Pix ou boleto.`,
      params: [nome, mes, valor, venc, link] },
    lembrete: { assunto: `${empresa} · Lembrete: mensalidade vence ${extra.dias === 0 ? "hoje" : "em " + venc}`, titulo: extra.dias === 0 ? "Sua mensalidade vence hoje" : `Sua mensalidade vence em ${extra.dias} dia(s)`,
      texto: `Olá, ${nome}! Passando para lembrar da mensalidade de ${valor} com vencimento em ${venc}. Se já pagou, desconsidere esta mensagem.`,
      params: [nome, valor, venc, link] },
    vencida: { assunto: `${empresa} · Mensalidade em atraso`, titulo: "Identificamos um atraso",
      texto: `Olá, ${nome}! Não identificamos o pagamento da mensalidade de ${valor}, vencida em ${venc}. Para evitar a suspensão do acesso ao app, regularize até ${dataBR(extra.limite)}. O Pix é confirmado na hora.`,
      params: [nome, valor, venc, dataBR(extra.limite), link] },
    bloqueio: { assunto: `${empresa} · Acesso ao app suspenso`, titulo: "Seu acesso foi suspenso",
      texto: `Olá, ${nome}. Como a mensalidade vencida em ${venc} continua em aberto, o acesso ao app foi suspenso. Assim que o pagamento for confirmado, o acesso volta automaticamente. Pelo Pix, a liberação é imediata.`,
      params: [nome, link] },
    pagamento: { assunto: `${empresa} · Pagamento confirmado`, titulo: "Pagamento confirmado. Obrigado!",
      texto: `Olá, ${nome}! Recebemos o pagamento de ${valor} referente a ${mes}.${extra.desbloqueado ? " Seu acesso ao app já foi liberado." : ""}`,
      params: [nome, mes, valor] },
    pre_cadastro: { assunto: `${empresa} · Recebemos seu pré-cadastro`, titulo: "Obrigado pelo seu pré-cadastro!",
      texto: `Olá, ${nome}! Recebemos o seu pré-cadastro no rastreamento ${empresa}. Obrigado pela confiança!<br><br>Assim que iniciarmos o processo de instalação dos rastreadores, entraremos em contato pelo WhatsApp ou por este e-mail para agendar a instalação no seu veículo.<br><br>Sua condição especial já está garantida: <b style="color:#e8eaed">${brl(PRECO_PROMO)}/mês por 12 meses</b> e instalação com 50% de desconto (${brl(49.95)}), paga só no dia da instalação. Não é preciso fazer nada agora.`,
      params: [nome] },
  };
  return T[tipo];
}
function emailHtml(c: Obj, cob: Obj | null, empresa: string, tipo: string) {
  const mostraPagamento = cob && tipo !== "pagamento";
  const rodape = tipo === "pre_cadastro" ? `${empresa} · Você recebeu esta mensagem porque fez um pré-cadastro no app. Dúvidas? É só responder este e-mail.` : `${empresa} · Mensagem automática. Se já pagou, desconsidere.`;
  const bloco = (rot: string, val: string) => `<tr><td style="padding:6px 0;color:#9aa3ad;font-size:13px">${rot}</td><td style="padding:6px 0;text-align:right;color:#e8eaed;font-size:14px;font-weight:600">${val}</td></tr>`;
  return `<!doctype html><html lang="pt-BR"><body style="margin:0;background:#0b0d10;font-family:Arial,Helvetica,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0b0d10;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#15181d;border:1px solid #262a31;border-radius:16px;padding:28px">
<tr><td style="color:#38d6f5;font-size:12px;letter-spacing:3px;font-weight:700">${empresa.toUpperCase()} · RASTREAMENTO</td></tr>
<tr><td style="padding:14px 0 8px;color:#e8eaed;font-size:22px;font-weight:700">${c.titulo}</td></tr>
<tr><td style="color:#c4cad1;font-size:15px;line-height:1.6;padding-bottom:16px">${c.texto}</td></tr>
${cob ? `<tr><td><table role="presentation" width="100%" style="border-top:1px solid #262a31;border-bottom:1px solid #262a31;margin-bottom:18px">${bloco("Referência", mesBR(cob.competencia))}${bloco("Valor", brl(cob.valor))}${bloco("Vencimento", dataBR(cob.vencimento))}</table></td></tr>` : ""}
${mostraPagamento && cob.pix_copia_cola ? `<tr><td style="color:#e8eaed;font-size:15px;font-weight:700;padding-bottom:6px">Pagar com Pix (confirmação na hora)</td></tr>
<tr><td style="color:#9aa3ad;font-size:13px;padding-bottom:6px">O QR Code vai anexado. Ou copie o código abaixo no app do seu banco:</td></tr>
<tr><td style="background:#0b0d10;border:1px solid #262a31;border-radius:10px;padding:12px;color:#e8eaed;font-size:12px;word-break:break-all;font-family:monospace">${cob.pix_copia_cola}</td></tr>
<tr><td style="padding:12px 0 18px"><a href="https://app.rjdomotica.com/pix/#${encodeURIComponent(cob.pix_copia_cola)}" style="display:inline-block;background:#38d6f5;color:#0b0d10;text-decoration:none;font-weight:700;padding:12px 20px;border-radius:10px">Copiar Pix</a></td></tr>` : ""}
${mostraPagamento && cob.boleto_url ? `<tr><td style="color:#e8eaed;font-size:15px;font-weight:700;padding:6px 0">Pagar com boleto</td></tr>
${cob.boleto_codigo ? `<tr><td style="color:#c4cad1;font-size:13px;font-family:monospace;padding-bottom:10px">${cob.boleto_codigo}</td></tr>` : ""}
<tr><td style="padding-bottom:18px"><a href="${cob.boleto_url}" style="display:inline-block;border:1px solid #38d6f5;color:#38d6f5;text-decoration:none;font-weight:700;padding:11px 20px;border-radius:10px">Ver boleto</a></td></tr>
<tr><td style="color:#9aa3ad;font-size:12px;padding-bottom:12px">O boleto leva até 2 dias úteis para ser compensado.</td></tr>` : ""}
<tr><td style="color:#8a929c;font-size:12px;border-top:1px solid #262a31;padding-top:14px">${rodape}</td></tr>
</table></td></tr></table></body></html>`;
}
async function logMsg(cli: Obj, cob: Obj | null, canal: string, tipo: string, destino: string, status: string, detalhe: string) {
  await db.from("mensagens").insert({ cliente_id: cli.id, cobranca_id: cob?.id || null, canal, tipo, destino, status, detalhe });
}
async function notificar(cli: Obj, cob: Obj | null, tipo: string, cfg: Obj, extra: Obj = {}, chave = tipo) {
  const empresa = cfg.nome_empresa || "RJ Domótica";
  const c = conteudo(tipo, cli, cob, empresa, extra);
  // e-mail
  if (env("RESEND_API_KEY") && env("EMAIL_REMETENTE")) {
    try {
      const corpo: Obj = { from: env("EMAIL_REMETENTE"), to: [cli.email], subject: c.assunto, html: emailHtml(c, cob, empresa, tipo) };
      if (env("EMAIL_RESPOSTA")) corpo.reply_to = env("EMAIL_RESPOSTA");
      if (cob?.pix_qr_base64 && tipo !== "pagamento") corpo.attachments = [{ filename: "pix-qrcode.png", content: cob.pix_qr_base64 }];
      const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: "Bearer " + env("RESEND_API_KEY"), "Content-Type": "application/json" }, body: JSON.stringify(corpo) });
      const d = await r.json().catch(() => ({}));
      await logMsg(cli, cob, "email", chave, cli.email, r.ok ? "enviado" : "erro", r.ok ? c.assunto : (d.message || `HTTP ${r.status}`));
    } catch (e) { await logMsg(cli, cob, "email", chave, cli.email, "erro", (e as Error).message); }
  } else await logMsg(cli, cob, "email", chave, cli.email, "simulado", c.assunto + " (e-mail ainda não configurado)");
  // WhatsApp
  const fone = (cli.whatsapp || "").replace(/\D/g, "");
  const modelo = (cfg.whatsapp_templates || {})[tipo];
  if (env("WHATSAPP_TOKEN") && env("WHATSAPP_PHONE_ID") && modelo) {
    try {
      const r = await fetch(`https://graph.facebook.com/v21.0/${env("WHATSAPP_PHONE_ID")}/messages`, {
        method: "POST", headers: { Authorization: "Bearer " + env("WHATSAPP_TOKEN"), "Content-Type": "application/json" },
        body: JSON.stringify({ messaging_product: "whatsapp", to: fone, type: "template", template: { name: modelo, language: { code: "pt_BR" }, components: [{ type: "body", parameters: c.params.map((t: string) => ({ type: "text", text: String(t || "-") })) }] } }),
      });
      const d = await r.json().catch(() => ({}));
      await logMsg(cli, cob, "whatsapp", chave, fone, r.ok ? "enviado" : "erro", r.ok ? `modelo ${modelo}` : (d.error?.message || `HTTP ${r.status}`));
    } catch (e) { await logMsg(cli, cob, "whatsapp", chave, fone, "erro", (e as Error).message); }
  } else await logMsg(cli, cob, "whatsapp", chave, fone, "simulado", c.texto.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ") + " (WhatsApp ainda não configurado)");
}
async function jaEnviado(cob: Obj, chave: string) {
  const { count } = await db.from("mensagens").select("id", { count: "exact", head: true }).eq("cobranca_id", cob.id).eq("tipo", chave).in("status", ["enviado", "simulado"]);
  return (count || 0) > 0;
}

// ---------------- regras de cobrança ----------------
async function gerarCobranca(cli: Obj, competencia: string, cfg: Obj, autor = "automático") {
  let { data: cob } = await db.from("cobrancas").select("*").eq("cliente_id", cli.id).eq("competencia", competencia).maybeSingle();
  if (!cob) {
    const { data, error } = await db.from("cobrancas").insert({ cliente_id: cli.id, competencia, valor: cli.valor_mensal, vencimento: vencimentoDe(competencia, cli.dia_vencimento) }).select().single();
    if (error) throw new Error(error.message);
    cob = data;
    await registrar(cli.id, "cobranca_gerada", `Mensalidade ${mesBR(competencia)} · ${brl(cob.valor)} · vence ${dataBR(cob.vencimento)}`, autor);
  }
  if (cob.status !== "pendente") return cob;
  if (mpOn() && !cob.mp_boleto_id && !cob.mp_pix_id) {
    const { data } = await db.from("cobrancas").update(await criarPagamentosMP(cli, cob, cfg.nome_empresa || "RJ Domótica")).eq("id", cob.id).select().single();
    cob = data;
  }
  if (!cob.enviado_em) {
    await notificar(cli, cob, "cobranca", cfg);
    const { data } = await db.from("cobrancas").update({ enviado_em: new Date().toISOString() }).eq("id", cob.id).select().single();
    cob = data;
  }
  return cob;
}
async function bloquear(cli: Obj, motivo: string, autor: string, cob: Obj | null, cfg: Obj) {
  if (cli.status !== "ativo") return "cliente já não está ativo";
  let tr = "";
  try { tr = await traccarAcesso(cli, false); } catch (e) { tr = "falha no servidor do rastreador: " + (e as Error).message; }
  await db.from("clientes").update({ status: "bloqueado", bloqueado_em: new Date().toISOString(), motivo_bloqueio: motivo }).eq("id", cli.id);
  await registrar(cli.id, "bloqueio", `${motivo} (${tr})`, autor);
  if (cob && !(await jaEnviado(cob, "bloqueio"))) await notificar(cli, cob, "bloqueio", cfg);
  return tr;
}
async function desbloquear(cli: Obj, autor: string, motivo = "Acesso liberado") {
  if (cli.status !== "bloqueado") return "cliente não estava bloqueado";
  let tr = "";
  try { tr = await traccarAcesso(cli, true); } catch (e) { tr = "falha no servidor do rastreador: " + (e as Error).message; }
  await db.from("clientes").update({ status: "ativo", bloqueado_em: null, motivo_bloqueio: null }).eq("id", cli.id);
  await registrar(cli.id, "desbloqueio", `${motivo} (${tr})`, autor);
  return tr;
}
async function aindaInadimplente(cliente_id: string, cfg: Obj, fer: Set<string>) {
  const hoje = hojeSP(), n = Number(cfg.dias_uteis_bloqueio ?? 2);
  const { data } = await db.from("cobrancas").select("vencimento").eq("cliente_id", cliente_id).eq("status", "pendente").lt("vencimento", hoje);
  return (data || []).some((c) => diasUteisEntre(c.vencimento, hoje, fer) > n);
}
async function marcarPago(cob: Obj, forma: string, valor: number | null, quando: string | null, autor: string) {
  if (cob.status === "pago") return { ok: true, aviso: "já estava paga" };
  await db.from("cobrancas").update({ status: "pago", forma_pagamento: forma, valor_pago: valor ?? cob.valor, pago_em: quando || new Date().toISOString() }).eq("id", cob.id);
  // cancela o outro meio de pagamento em aberto no Mercado Pago
  if (mpOn()) {
    for (const id of [cob.mp_boleto_id, cob.mp_pix_id]) {
      if (!id) continue;
      try { const p = await mp(`/v1/payments/${id}`); if (p.status === "pending") await mp(`/v1/payments/${id}`, { method: "PUT", body: JSON.stringify({ status: "cancelled" }) }); } catch (_) { /* segue */ }
    }
  }
  const { data: cli } = await db.from("clientes").select("*").eq("id", cob.cliente_id).single();
  await registrar(cli.id, "pagamento", `Mensalidade ${mesBR(cob.competencia)} paga via ${forma} · ${brl(valor ?? cob.valor)}`, autor);
  const cfg = await config(), fer = await feriados();
  let desbloqueado = false;
  if (cli.status === "bloqueado" && (cli.motivo_bloqueio || "").startsWith("Inadimplência") && !(await aindaInadimplente(cli.id, cfg, fer))) {
    await desbloquear(cli, autor, "Pagamento confirmado"); desbloqueado = true;
  }
  await notificar(cli, { ...cob, status: "pago" }, "pagamento", cfg, { desbloqueado });
  return { ok: true, desbloqueado };
}
async function conferirNoMP(cob: Obj) {
  if (!mpOn()) return false;
  for (const id of [cob.mp_pix_id, cob.mp_boleto_id]) {
    if (!id) continue;
    try {
      const p = await mp(`/v1/payments/${id}`);
      if (p.status === "approved") { await marcarPago(cob, p.payment_method_id === "pix" ? "pix" : "boleto", p.transaction_amount, p.date_approved, "Mercado Pago"); return true; }
    } catch (_) { /* segue */ }
  }
  return false;
}

// ---------------- rotina diária ----------------
async function rotina() {
  const cfg = await config(), fer = await feriados(), hoje = hojeSP();
  const antecedencia = Number(cfg.dias_antecedencia_cobranca ?? 10);
  const lembretes: number[] = cfg.dias_lembrete ?? [3, 0];
  const n = Number(cfg.dias_uteis_bloqueio ?? 2);
  const rel = { geradas: 0, lembretes: 0, vencidas: 0, bloqueados: 0, pagos_conferidos: 0, erros: [] as string[] };

  const { data: clientes } = await db.from("clientes").select("*").in("status", ["ativo", "bloqueado"]);
  for (const cli of clientes || []) {
    try {
      // 1. gera a cobrança do mês atual e do próximo quando entra na janela de antecedência
      for (const comp of [competenciaDe(hoje), competenciaDe(addDias(competenciaDe(hoje), 32))]) {
        const venc = vencimentoDe(comp, cli.dia_vencimento), falta = diffDias(hoje, venc);
        if (falta >= 0 && falta <= antecedencia && venc >= diaSP(cli.created_at)) {
          const { count } = await db.from("cobrancas").select("id", { count: "exact", head: true }).eq("cliente_id", cli.id).eq("competencia", comp);
          if (!count) { await gerarCobranca(cli, comp, cfg); rel.geradas++; }
        }
      }
      // 2. lembretes, aviso de atraso e bloqueio
      const { data: abertas } = await db.from("cobrancas").select("*").eq("cliente_id", cli.id).eq("status", "pendente").order("vencimento");
      for (const cob of abertas || []) {
        const falta = diffDias(hoje, cob.vencimento);
        if (falta >= 0 && lembretes.includes(falta) && falta !== diffDias(diaSP(cob.created_at), cob.vencimento)) {
          const chave = `lembrete_${falta}`;
          if (!(await jaEnviado(cob, chave))) { await notificar(cli, cob, "lembrete", cfg, { dias: falta }, chave); rel.lembretes++; }
        }
        if (falta < 0) {
          if (await conferirNoMP(cob)) { rel.pagos_conferidos++; continue; }
          if (!(await jaEnviado(cob, "vencida"))) { await notificar(cli, cob, "vencida", cfg, { limite: somarDiasUteis(cob.vencimento, n, fer) }); rel.vencidas++; }
          if (cli.status === "ativo" && diasUteisEntre(cob.vencimento, hoje, fer) > n) {
            await bloquear(cli, `Inadimplência: mensalidade vencida em ${dataBR(cob.vencimento)}`, "automático", cob, cfg);
            cli.status = "bloqueado"; rel.bloqueados++;
          }
        }
      }
    } catch (e) { rel.erros.push(`${cli.nome}: ${(e as Error).message}`); }
  }
  await registrar(null, "rotina", `Geradas ${rel.geradas} · lembretes ${rel.lembretes} · atrasos avisados ${rel.vencidas} · bloqueios ${rel.bloqueados} · pagamentos conferidos ${rel.pagos_conferidos}${rel.erros.length ? " · erros: " + rel.erros.join("; ") : ""}`);
  return rel;
}

// ---------------- webhook do Mercado Pago ----------------
async function assinaturaValida(req: Request, dataId: string) {
  const segredo = env("MP_WEBHOOK_SECRET");
  if (!segredo) return true; // sem segredo: seguro mesmo assim, pois o pagamento é sempre conferido direto no Mercado Pago
  const sig = req.headers.get("x-signature") || "", reqId = req.headers.get("x-request-id") || "";
  const p = Object.fromEntries(sig.split(",").map((s) => s.trim().split("=")));
  const manifesto = `id:${dataId};request-id:${reqId};ts:${p.ts};`;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(segredo), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(manifesto)));
  return [...mac].map((b) => b.toString(16).padStart(2, "0")).join("") === p.v1;
}
async function webhookMP(req: Request) {
  const u = new URL(req.url);
  const corpo: Obj = await req.json().catch(() => ({}));
  const id = String(u.searchParams.get("data.id") || corpo?.data?.id || u.searchParams.get("id") || "");
  const tipo = u.searchParams.get("type") || corpo.type || u.searchParams.get("topic") || "";
  if (!id || (tipo && tipo !== "payment")) return json({ ok: true, ignorado: true });
  if (!(await assinaturaValida(req, id.toLowerCase()))) return json({ erro: "assinatura inválida" }, 401);
  if (!mpOn()) return json({ ok: true, aviso: "Mercado Pago não configurado" });
  const p = await mp(`/v1/payments/${id}`);
  if (!p.external_reference) return json({ ok: true, ignorado: true });
  const { data: cob } = await db.from("cobrancas").select("*").eq("id", p.external_reference).maybeSingle();
  if (!cob) return json({ ok: true, ignorado: true });
  if (p.status === "approved" && cob.status === "pendente") {
    return json(await marcarPago(cob, p.payment_method_id === "pix" ? "pix" : "boleto", p.transaction_amount, p.date_approved, "Mercado Pago"));
  }
  return json({ ok: true, status: p.status });
}

// ---------------- pré-cadastro (rota pública, usada pelo app) ----------------
const PRECO_CHEIO = 64.9, PRECO_PROMO = 54.9; // promoção travada para quem se pré-cadastra
const TIPOS_VEIC = ["carro", "moto", "caminhao", "outros"];
const CORES_VEIC = ["Branco", "Preto", "Prata", "Cinza", "Vermelho", "Azul", "Verde", "Amarelo", "Laranja", "Marrom", "Bege", "Dourado", "Vinho", "Rosa"];
const soDig = (s: unknown) => String(s ?? "").replace(/\D/g, "");
const limpa = (s: unknown, max: number) => String(s ?? "").replace(/[\u0000-\u001f<>]/g, " ").replace(/\s+/g, " ").trim().slice(0, max);
async function preCadastro(req: Request) {
  const b: Obj = await req.json().catch(() => ({}));
  if (b.site) return json({ ok: true }); // campo-isca: robô preencheu, finge que deu certo
  const nome = limpa(b.nome, 100), email = limpa(b.email, 120).toLowerCase();
  let zap = soDig(b.whatsapp); if (zap.length === 10 || zap.length === 11) zap = "55" + zap;
  if (nome.length < 3 || !/\S+\s+\S+/.test(nome)) return json({ erro: "Informe seu nome completo." }, 400);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return json({ erro: "E-mail inválido." }, 400);
  if (zap.length < 12 || zap.length > 13) return json({ erro: "WhatsApp inválido: use DDD + número." }, 400);
  if (b.aceite !== true) return json({ erro: "Marque a autorização para contato." }, 400);
  const lista: Obj[] = Array.isArray(b.veiculos) ? b.veiculos.slice(0, 5) : [];
  const veics = lista.map((v) => ({
    tipo: TIPOS_VEIC.includes(v?.tipo) ? v.tipo : "carro", marca: limpa(v?.marca, 40), modelo: limpa(v?.modelo, 40), cor: CORES_VEIC.includes(v?.cor) ? v.cor : null,
    ano: Number(v?.ano) >= 1950 && Number(v?.ano) <= new Date().getFullYear() + 1 ? Number(v.ano) : null,
    placa: limpa(v?.placa, 8).toUpperCase().replace(/[^A-Z0-9]/g, "") || null,
  })).filter((v) => v.marca || v.modelo);
  if (!veics.length) return json({ erro: "Informe pelo menos um veículo (marca e modelo)." }, 400);
  if (veics.some((v) => !v.marca || !v.modelo)) return json({ erro: "Preencha marca e modelo de cada veículo." }, 400);

  // limite de segurança: no máximo 30 pré-cadastros por hora no total
  const desde = new Date(Date.now() - 3600e3).toISOString();
  const { count: recentes } = await db.from("clientes").select("id", { count: "exact", head: true }).eq("status", "pre_cadastro").gte("created_at", desde);
  if ((recentes || 0) >= 30) return json({ erro: "Muitos pedidos agora. Tente de novo em alguns minutos." }, 429);

  // quem já está na base não duplica (resposta igual, sem revelar nada)
  const { count: jaTem } = await db.from("clientes").select("id", { count: "exact", head: true }).eq("email", email);
  if (jaTem) return json({ ok: true, valor: PRECO_PROMO });

  const obs = `Pré-cadastro pelo app. Promoção travada: ${brl(PRECO_PROMO)}/mês por 12 meses (preço cheio ${brl(PRECO_CHEIO)}). Instalação com 50% de desconto (R$ 49,95 em vez de R$ 99,90). Pagamento só no ato da instalação.`;
  const { data: cli, error } = await db.from("clientes").insert({
    nome, email, whatsapp: zap, tipo_pessoa: "PF", valor_mensal: PRECO_PROMO, dia_vencimento: 10, status: "pre_cadastro", observacoes: obs,
  }).select().single();
  if (error || !cli) throw new Error("Não foi possível salvar o pré-cadastro.");
  for (const v of veics) {
    let r = await db.from("veiculos").insert({ cliente_id: cli.id, ...v, ativo: true });
    if (r.error && v.placa) r = await db.from("veiculos").insert({ cliente_id: cli.id, ...v, placa: null, ativo: true }); // placa já existe: grava sem ela
  }
  await registrar(cli.id, "pre_cadastro", `Pré-cadastro recebido pelo app (${veics.length} veículo(s)). Autorizou contato. Promoção ${brl(PRECO_PROMO)}/mês.`, "app");
  // agradecimento por e-mail e WhatsApp; uma falha aqui nunca derruba o pré-cadastro
  try { await notificar(cli, null, "pre_cadastro", await config()); } catch (e) { console.error("agradecimento pré-cadastro:", e); }
  return json({ ok: true, valor: PRECO_PROMO });
}

// ---------------- instaladores (convite e link de acesso) ----------------
const URL_INSTALADOR = "https://app.rjdomotica.com/instalador/";
async function linkAcessoInstalador(email: string) {
  // link de uso único para o instalador criar a própria senha (vale pelo prazo configurado no Supabase Auth)
  const { data, error } = await db.auth.admin.generateLink({ type: "recovery", email, options: { redirectTo: URL_INSTALADOR } });
  if (error || !data?.properties?.hashed_token) throw new Error("Não foi possível gerar o link de acesso: " + (error?.message || "sem link"));
  // O código vai depois do "#": a prévia do WhatsApp/e-mail abre a página mas não gasta o código.
  // Ele só é validado quando o instalador toca em "Salvar senha e entrar".
  return { link: `${URL_INSTALADOR}#acesso=${data.properties.hashed_token}`, user_id: data.user.id };
}
async function emailAcessoInstalador(email: string, nome: string, link: string, empresa: string, novo: boolean) {
  if (!(env("RESEND_API_KEY") && env("EMAIL_REMETENTE"))) return false;
  const titulo = novo ? "Bem-vindo à equipe de instaladores" : "Seu link de acesso";
  const texto = `Olá, ${primeiroNome(nome)}! ${novo ? `Você foi cadastrado como instalador parceiro da ${empresa}.` : "Aqui está um novo link de acesso à área do instalador."}<br><br>Toque no botão abaixo para criar sua senha. Depois é só entrar em <b style="color:#e8eaed">app.rjdomotica.com/instalador</b> com este e-mail e a senha criada. Lá você também encontra o curso de instalação.<br><br><a href="${link}" style="display:inline-block;background:#38d6f5;color:#0b0d10;text-decoration:none;font-weight:700;padding:12px 20px;border-radius:10px">Criar minha senha</a><br><br><span style="color:#9aa3ad;font-size:13px">O link é de uso único e expira. Se expirar, peça um novo à ${empresa}.</span>`;
  const html = emailHtml({ titulo, texto }, null, empresa, "instalador").replace(`${empresa} · Mensagem automática. Se já pagou, desconsidere.`, `${empresa} · Você recebeu esta mensagem porque foi cadastrado como instalador.`);
  const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: "Bearer " + env("RESEND_API_KEY"), "Content-Type": "application/json" },
    body: JSON.stringify({ from: env("EMAIL_REMETENTE"), to: [email], subject: `${empresa} · ${titulo}`, html, ...(env("EMAIL_RESPOSTA") ? { reply_to: env("EMAIL_RESPOSTA") } : {}) }) });
  return r.ok;
}

// ---------------- ações do painel ----------------
async function adminDe(req: Request) {
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data } = await db.auth.getUser(token);
  if (!data?.user) return null;
  const { data: a } = await db.from("admins").select("user_id").eq("user_id", data.user.id).maybeSingle();
  return a ? data.user : null;
}
async function acaoAdmin(req: Request) {
  const user = await adminDe(req);
  if (!user) return json({ erro: "Acesso restrito ao administrador." }, 401);
  const b: Obj = await req.json().catch(() => ({}));
  const autor = user.email || "admin";
  const cfg = await config();
  const cliente = async (id: string) => { const { data } = await db.from("clientes").select("*").eq("id", id).single(); if (!data) throw new Error("Cliente não encontrado."); return data; };
  const cobranca = async (id: string) => { const { data } = await db.from("cobrancas").select("*").eq("id", id).single(); if (!data) throw new Error("Cobrança não encontrada."); return data; };

  switch (b.acao) {
    case "integracoes":
      return json({
        traccar: traccarOn(), mercadopago: mpOn(), mp_assinatura: !!env("MP_WEBHOOK_SECRET"),
        email: !!(env("RESEND_API_KEY") && env("EMAIL_REMETENTE")), whatsapp: !!(env("WHATSAPP_TOKEN") && env("WHATSAPP_PHONE_ID")),
        webhook_url: `${URL_SB}/functions/v1/api/webhook-mp`, hoje: hojeSP(),
      });
    case "sincronizar":
      return json(await sincronizar(b.cliente_id, b.senha));
    case "bloquear": {
      const c = await cliente(b.cliente_id);
      return json({ ok: true, detalhe: await bloquear(c, b.motivo || "Bloqueio manual", autor, null, cfg) });
    }
    case "desbloquear": {
      const c = await cliente(b.cliente_id);
      return json({ ok: true, detalhe: await desbloquear(c, autor, b.motivo || "Desbloqueio manual") });
    }
    case "gerar_cobranca": {
      const c = await cliente(b.cliente_id);
      if (c.status === "pre_cadastro") throw new Error("Este cliente ainda é um pré-cadastro. Complete os dados e marque como Ativo antes de gerar cobrança.");
      const comp = b.competencia ? competenciaDe(b.competencia) : (() => {
        const h = hojeSP(), atual = competenciaDe(h);
        return vencimentoDe(atual, c.dia_vencimento) >= h ? atual : competenciaDe(addDias(atual, 32));
      })();
      return json({ ok: true, cobranca: await gerarCobranca(c, comp, cfg, autor) });
    }
    case "reenviar": {
      const cob = await cobranca(b.cobranca_id), c = await cliente(cob.cliente_id);
      if (cob.status !== "pendente") throw new Error("Só dá para reenviar cobranças em aberto.");
      if (mpOn() && !cob.mp_boleto_id && !cob.mp_pix_id) {
        const { data } = await db.from("cobrancas").update(await criarPagamentosMP(c, cob, cfg.nome_empresa || "RJ Domótica")).eq("id", cob.id).select().single();
        Object.assign(cob, data);
      }
      await notificar(c, cob, cob.vencimento < hojeSP() ? "vencida" : "cobranca", cfg, { limite: somarDiasUteis(cob.vencimento, Number(cfg.dias_uteis_bloqueio ?? 2), await feriados()) }, "reenvio");
      await registrar(c.id, "reenvio", `Cobrança de ${mesBR(cob.competencia)} reenviada`, autor);
      return json({ ok: true });
    }
    case "marcar_pago": {
      const cob = await cobranca(b.cobranca_id);
      return json(await marcarPago(cob, b.forma || "manual", b.valor ? Number(b.valor) : null, null, autor));
    }
    case "cancelar_cobranca": {
      const cob = await cobranca(b.cobranca_id);
      if (mpOn()) for (const id of [cob.mp_boleto_id, cob.mp_pix_id]) if (id) await mp(`/v1/payments/${id}`, { method: "PUT", body: JSON.stringify({ status: "cancelled" }) }).catch(() => null);
      await db.from("cobrancas").update({ status: "cancelado" }).eq("id", cob.id);
      await registrar(cob.cliente_id, "cobranca_cancelada", `Mensalidade ${mesBR(cob.competencia)} cancelada`, autor);
      return json({ ok: true });
    }
    case "excluir_cliente": {
      const c = await cliente(b.cliente_id);
      if (traccarOn()) {
        const { data: vs } = await db.from("veiculos").select("traccar_device_id").eq("cliente_id", c.id);
        for (const v of vs || []) if (v.traccar_device_id) await traccar(`/api/devices/${v.traccar_device_id}`, { method: "DELETE" }).catch(() => null);
        if (c.traccar_user_id) await traccar(`/api/users/${c.traccar_user_id}`, { method: "DELETE" }).catch(() => null);
      }
      await db.from("clientes").delete().eq("id", c.id);
      await registrar(null, "cliente_excluido", `${c.nome} (${c.documento || c.status}) excluído`, autor);
      return json({ ok: true });
    }
    case "convidar_instalador": {
      const email = limpa(b.email, 120).toLowerCase(), nome = limpa(b.nome, 100);
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) throw new Error("E-mail inválido.");
      if (nome.length < 3) throw new Error("Informe o nome do instalador.");
      let zap = soDig(b.whatsapp); if (zap.length === 10 || zap.length === 11) zap = "55" + zap;
      const valor = b.valor_padrao === "" || b.valor_padrao == null ? null : Number(b.valor_padrao);
      if (valor !== null && !(valor >= 0)) throw new Error("Valor por instalação inválido.");
      const cria = await db.auth.admin.createUser({ email, email_confirm: true, user_metadata: { nome } });
      if (cria.error && !/already|registered|exists/i.test(cria.error.message)) throw new Error("Não foi possível criar o login: " + cria.error.message);
      const { link, user_id } = await linkAcessoInstalador(email);
      const { data: ja } = await db.from("instaladores").select("user_id").eq("user_id", user_id).maybeSingle();
      if (ja) throw new Error("Este e-mail já é de um instalador cadastrado. Use \"Gerar link de acesso\" na lista.");
      const { error } = await db.from("instaladores").insert({ user_id, nome, documento: soDig(b.documento) || null, whatsapp: zap || null, chave_pix: limpa(b.chave_pix, 140) || null, valor_padrao: valor, ativo: true });
      if (error) throw new Error(error.message);
      const empresa = cfg.nome_empresa || "RJ Domótica";
      let email_enviado = false;
      try { email_enviado = await emailAcessoInstalador(email, nome, link, empresa, true); } catch (_) { /* segue: o admin tem o link */ }
      await registrar(null, "instalador", `Instalador ${nome} (${email}) cadastrado${email_enviado ? "; convite enviado por e-mail" : ""}`, autor);
      return json({ ok: true, user_id, link, email_enviado });
    }
    case "link_instalador": {
      const { data: inst } = await db.from("instaladores").select("user_id, nome").eq("user_id", b.user_id).maybeSingle();
      if (!inst) throw new Error("Instalador não encontrado.");
      const { data: u, error: eu } = await db.auth.admin.getUserById(inst.user_id);
      if (eu || !u?.user?.email) throw new Error("Login do instalador não encontrado.");
      const { link } = await linkAcessoInstalador(u.user.email);
      let email_enviado = false;
      if (b.enviar_email) { try { email_enviado = await emailAcessoInstalador(u.user.email, inst.nome, link, cfg.nome_empresa || "RJ Domótica", false); } catch (_) { /* segue */ } }
      await registrar(null, "instalador", `Novo link de acesso gerado para ${inst.nome}${email_enviado ? " (enviado por e-mail)" : ""}`, autor);
      return json({ ok: true, link, email: u.user.email, email_enviado });
    }
    case "emails_instaladores": {
      const { data: insts } = await db.from("instaladores").select("user_id");
      const out: Obj = {};
      for (const i of insts || []) { const { data: u } = await db.auth.admin.getUserById(i.user_id); out[i.user_id] = { email: u?.user?.email || "", ultimo_acesso: u?.user?.last_sign_in_at || null }; }
      return json({ ok: true, usuarios: out });
    }
    case "rodar_rotina":
      return json({ ok: true, relatorio: await rotina() });
    default:
      return json({ erro: "Ação desconhecida." }, 400);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const rota = new URL(req.url).pathname.split("/").filter(Boolean).pop();
  try {
    if (rota === "admin") return await acaoAdmin(req);
    if (rota === "webhook-mp") return await webhookMP(req);
    if (rota === "pre-cadastro") return await preCadastro(req);
    if (rota === "rotina") {
      const { data } = await db.from("segredos_internos").select("valor").eq("chave", "cron").single();
      if (!data || req.headers.get("x-cron-secret") !== data.valor) return json({ erro: "não autorizado" }, 401);
      return json({ ok: true, relatorio: await rotina() });
    }
    return json({ ok: true, servico: "RJ Domótica API" });
  } catch (e) {
    console.error(e);
    return json({ erro: (e as Error).message }, 500);
  }
});
