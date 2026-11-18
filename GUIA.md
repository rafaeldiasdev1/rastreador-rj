# Guia de configuração · Plataforma RJ Domótica

Endereços:
- **App do cliente:** https://rafaeldiasdev1.github.io/rastreador-rj/
- **Painel do administrador:** https://rafaeldiasdev1.github.io/rastreador-rj/admin/

Tudo já funciona em **modo simulado**: o painel cadastra clientes e veículos, gera cobranças, bloqueia e desbloqueia, e registra em "Mensagens" o que enviaria. Cada integração abaixo liga sozinha assim que o segredo dela é cadastrado.

Os segredos ficam no Supabase (projeto **rastreador-rj**), em **Edge Functions › Secrets**. Nunca coloque nenhum deles no código ou no GitHub.

---

## 1. Sua conta de administrador (fazer primeiro)
1. Abra o painel, preencha seu e-mail e uma senha (mínimo de 8 caracteres) e toque em **Primeiro acesso: criar conta de administrador**.
2. Confirme pelo link que chega no seu e-mail e entre.
3. A primeira conta criada vira a de administrador. Depois disso, ninguém mais consegue se tornar administrador pelo painel.

## 2. Mercado Pago (boleto + Pix)
1. Em **Suas integrações**, crie uma aplicação e copie o **Access Token de produção**.
   - Secret: `MP_ACCESS_TOKEN`
2. Em **Webhooks**, cadastre a URL que aparece em **Configurações** no painel (termina em `/functions/v1/api/webhook-mp`) e marque o evento **Pagamentos**.
3. Copie a **assinatura secreta** do webhook.
   - Secret: `MP_WEBHOOK_SECRET`
4. Para testar antes, use o Access Token de **teste** e um cliente com CPF de teste.

Como funciona: cada mensalidade gera um boleto, que vence no dia, e um Pix, que vale por 30 dias para quem pagar atrasado. Quando um dos dois é pago, o outro é cancelado. O Pix desbloqueia na hora. O boleto pode levar até 2 dias úteis para compensar.

## 3. E-mail (Resend)
1. Crie uma conta no resend.com e verifique um domínio seu, adicionando os registros DNS que ele pedir.
2. Crie uma API Key.
   - Secret: `RESEND_API_KEY`
   - Secret: `EMAIL_REMETENTE`, por exemplo: `RJ Domótica <cobranca@seudominio.com.br>`

O e-mail vai com o Pix copia-e-cola, o QR Code anexado e o link do boleto.

## 4. WhatsApp (API oficial da Meta)
1. No Meta Business, crie um app com **WhatsApp**, adicione e verifique o número da empresa.
2. Gere um **token permanente** (por um usuário do sistema) e copie o **ID do número de telefone**.
   - Secret: `WHATSAPP_TOKEN`
   - Secret: `WHATSAPP_PHONE_ID`
3. Crie e envie para aprovação os 5 modelos abaixo: categoria **Utilidade**, idioma **Português (BR)**. Os nomes precisam bater com os de **Configurações** no painel.

| Nome | Texto do modelo |
|---|---|
| `rj_cobranca` | Olá, {{1}}! A mensalidade do seu rastreamento referente a {{2}} já está disponível. Valor: {{3}}. Vencimento: {{4}}. Pague por Pix ou boleto pelo link: {{5}} |
| `rj_lembrete` | Olá, {{1}}! Lembrete: a mensalidade de {{2}} vence em {{3}}. Para pagar: {{4}}. Se já pagou, desconsidere. |
| `rj_vencida` | Olá, {{1}}. Não identificamos o pagamento da mensalidade de {{2}}, vencida em {{3}}. Para evitar a suspensão do acesso ao app, regularize até {{4}}: {{5}} |
| `rj_bloqueio` | Olá, {{1}}. O acesso ao app de rastreamento foi suspenso por mensalidade em aberto. Assim que o pagamento for confirmado, ele volta automaticamente: {{2}} |
| `rj_pagamento` | Olá, {{1}}! Recebemos o pagamento da mensalidade de {{2}} no valor de {{3}}. Obrigado! |

## 5. Servidor do rastreador (Traccar)
Quando o servidor estiver no ar com HTTPS:
- Secret: `TRACCAR_URL`, por exemplo: `https://rastreador.seudominio.com.br`
- Secret: `TRACCAR_ADMIN_EMAIL`
- Secret: `TRACCAR_ADMIN_SENHA`

Depois, em cada cliente, toque em **Sincronizar com o rastreador**. Isso cria o login do app, os veículos e as permissões. A partir daí, bloquear ou desbloquear no painel (ou pela cobrança) suspende ou libera o login do cliente no app na hora.

---

## Regras automáticas (todo dia às 9h05)
- **Cobrança:** gerada e enviada 10 dias antes do vencimento.
- **Lembretes:** 3 dias antes e no dia do vencimento.
- **Aviso de atraso:** no primeiro dia depois do vencimento, já com a data-limite.
- **Bloqueio:** quando o atraso passa de **2 dias úteis**. Fins de semana e feriados não contam. Exemplo: venceu na sexta, a tolerância é segunda e terça, e o bloqueio acontece na quarta às 9h.
- **Desbloqueio:** automático quando o pagamento é confirmado, pelo Mercado Pago ou registrado por você no painel.
- Todos os números acima podem ser ajustados em **Configurações**, assim como a lista de feriados.
