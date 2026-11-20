# RJ Domótica · instruções para o Claude

## Preferência do dono: tudo pelo painel admin

O Rafael quer gerenciar o negócio inteiro pelo **painel admin** (`app.rjdomotica.com/admin/`, código em `admin/index.src.html`). Por isso:

- **Toda alteração ou configuração do app deve ter tela no painel.** Cadastros (clientes, veículos, instaladores), ajustes de cobrança, mensagens, integrações e situação dos modelos do WhatsApp: tudo deve poder ser visto e mudado ali.
- **Não deixe tarefas que exijam o dashboard do Supabase, SQL, a Meta ou o terminal**, quando der para levar ao painel. Se algo novo precisar de configuração, crie junto a tela ou o campo no painel.
- **O que precisa de chave secreta** (criar logins, gerar links, falar com Traccar, Mercado Pago, Resend e WhatsApp) vai como ação na função `api` (`supabase/functions/api/index.ts`, rota `/admin`). Ela confere se quem chama é administrador. O painel só chama a ação.
- **Exceção combinada: o conteúdo do curso de instalação** (aulas, narrações, vídeos, apostila, bucket `curso`) fica com o Claude, que cria e publica. Não precisa de tela no painel.
- **Outras exceções** (só quando não há outro jeito): segredos da função (tokens e senhas, que o próprio Rafael configura e nunca passam pelo chat), a aprovação de modelos na Meta e a configuração de login do Supabase Auth. Nesses casos, explique o passo e, se possível, mostre o estado no painel (como em Configurações → Integrações).

## Como publicar

- Este computador (`rafael-Macmini`) tem o clone em `~/rastreador-rj` e o `gh` logado. Faça commit e `git push`. O GitHub Pages publica `docs/` em cerca de 1 minuto.
- Depois de mexer em `src/` ou `admin/index.src.html`, rode `python3 build.py`, que gera `docs/`.
- `docs/admin/os.html`, `docs/instalador/` e `docs/curso/` são editados direto em `docs/`.
- A função `api` é publicada no Supabase (projeto `xpafmvjlwgmhmvhfsqrg`) com `verify_jwt: false`. Mantenha `supabase/functions/api/index.ts` igual à versão publicada.
- Nunca coloque tokens, senhas ou o `traccar.xml` no repositório (ele é público) nem no chat.
