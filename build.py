import base64, pathlib
raiz = pathlib.Path(__file__).parent
src = (raiz / 'src/index.src.html').read_text(encoding='utf-8')
uri = lambda p, t: f'data:{t};base64,' + base64.b64encode((raiz / p).read_bytes()).decode()
src = src.replace('{{LOGO}}', uri('icons/logo.jpg', 'image/jpeg')).replace('{{ICON180}}', uri('icons/icon-180.png', 'image/png'))
dist = raiz / 'docs'; (dist / 'icons').mkdir(parents=True, exist_ok=True)
(dist / 'index.html').write_text(src.replace('<!--MANIFEST-->', '<link rel="manifest" href="manifest.webmanifest">'), encoding='utf-8')
(raiz / 'artifact.html').write_text(src.replace('<!--MANIFEST-->', ''), encoding='utf-8')
for f in ['manifest.webmanifest', 'sw.js']: (dist / f).write_bytes((raiz / f).read_bytes())
for f in ['icon-192.png', 'icon-512.png', 'icon-180.png']: (dist / 'icons' / f).write_bytes((raiz / 'icons' / f).read_bytes())
print('ok')
