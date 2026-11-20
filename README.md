# RJ Domótica · Rastreador

Plataforma de rastreamento veicular: app do cliente (PWA), painel do administrador, cobrança automática (Mercado Pago, e-mail e WhatsApp) e bloqueio por inadimplência.

- App do cliente: https://app.rjdomotica.com/
- Painel do administrador: https://app.rjdomotica.com/admin/
- Área do instalador (ordens de serviço): https://app.rjdomotica.com/instalador/
- Curso de instalação (só para instaladores e admin): https://app.rjdomotica.com/curso/
- **Configuração das integrações: veja [GUIA.md](GUIA.md)**

## Pastas
- `src/index.src.html`: código do app do cliente.
- `admin/index.src.html`: código do painel do administrador.
- `supabase/migrations/`: estrutura do banco (clientes, veículos, cobranças, mensagens, feriados).
- `supabase/functions/api/`: API (ações do painel, rotina diária de cobrança, webhook do Mercado Pago).
- `icons/`: logo e ícones.
- `build.py`: gera `docs/`, a pasta publicada no GitHub Pages.
- `docs/`: o app pronto (index.html, manifest, service worker e ícones).
- `docs/admin/os.html`, `docs/instalador/`, `docs/curso/`: tela "Instalação e OS" do admin, área do instalador e página do curso. São arquivos prontos, editados direto em `docs/` (o `build.py` não mexe neles). O conteúdo das aulas fica no bucket privado `curso` do Supabase.

Para gerar de novo depois de mudar algo: `python3 build.py`

## Modos
- **Demonstração** (padrão): o carro é simulado. Ele liga, anda, gera alertas e responde ao bloqueio.
- **Servidor real**: em Ajustes, desligue a demonstração e informe o endereço do servidor Traccar.

## Ligar no rastreador real (quando o J16 chegar)
1. Subir o servidor Traccar com HTTPS. O app precisa disso.
2. No `traccar.xml`, liberar o endereço do app para o navegador conseguir conversar com o servidor:
   `<entry key='web.origin'>https://ENDERECO-DO-APP</entry>`
3. Cadastrar o J16 no Traccar com o IMEI dele.
4. Enviar por SMS para o chip do rastreador:
   `SZCS#SERVIP=IP_DO_SERVIDOR#SERVPORT=5023#PTL_SEL=2#GT06SEL=1#`
5. No app, em Ajustes: endereço do servidor.

## Escuta (microfone) — liberada pelo administrador
O botão de escuta não aparece para o cliente por padrão. Para liberar em um veículo, no painel do Traccar (como administrador):
- no campo **Telefone** do dispositivo, coloque o número do chip do rastreador;
- em **Atributos**, adicione `escuta` com valor `true`.

Sem os dois, o botão fica escondido. Na demonstração ele nunca aparece.

O bloqueio usa os comandos `engineStop` e `engineResume` do Traccar. O próprio J16 só corta a bomba abaixo de 20 km/h ou com o carro parado.
