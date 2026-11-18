# RJ Domótica · Rastreador

App instalável (PWA) para ver a localização do carro e bloquear/desbloquear pelo rastreador J16 (4G).

## Pastas
- `src/index.src.html`: código do app (telas, estilos e lógica).
- `icons/`: logo e ícones.
- `build.py`: gera `docs/`, a pasta publicada no GitHub Pages.
- `docs/`: o app pronto (index.html, manifest, service worker e ícones).

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
5. No app, em Ajustes: endereço do servidor e número do chip (para a escuta).

O bloqueio usa os comandos `engineStop` e `engineResume` do Traccar. O próprio J16 só corta a bomba abaixo de 20 km/h ou com o carro parado.
