"""Gera as páginas de captação de profissionais por cidade a partir de parnaiba.html (modelo).
Uso: python3 ferramentas/gerar_paginas_cidade.py   (rode na raiz do repositório)
Para uma cidade nova, acrescente um item em CIDADES."""
import re, urllib.parse, pathlib
RAIZ = pathlib.Path(__file__).resolve().parent.parent
MODELO = (RAIZ / 'ferramentas' / 'modelo-pagina-cidade.html').read_text(encoding='utf-8')

CIDADES = [
  dict(arquivo='parnaiba.html', slug='parnaiba', nome='Santana de Parnaíba', cadastro='Santana de Parnaíba/SP',
       selo='Santana de Parnaíba e região', atende='Santana de Parnaíba, Barueri, Alphaville, Cotia, Osasco e São Paulo.',
       quem='Morador e profissional de Santana de Parnaíba, conhece de perto a obra e quem trabalha nela.'),
  dict(arquivo='barueri.html', slug='barueri', nome='Barueri', cadastro='Barueri/SP',
       selo='Barueri, Alphaville e região', atende='Barueri, Alphaville, Santana de Parnaíba, Jandira, Carapicuíba, Osasco e São Paulo.',
       quem='Engenheiro da região oeste da Grande SP, vizinho de Barueri, conhece de perto a obra e quem trabalha nela.'),
  dict(arquivo='osasco.html', slug='osasco', nome='Osasco', cadastro='Osasco/SP',
       selo='Osasco e região', atende='Osasco, Carapicuíba, Barueri, Cotia, Santana de Parnaíba e São Paulo.',
       quem='Engenheiro da região oeste da Grande SP, conhece de perto a obra e quem trabalha nela.'),
]

SCRIPT = """<script>
// Cadastro já com a cidade preenchida e a origem registrada (página + anúncio, se vier de um: ?utm_source=meta).
(function(){var q=new URLSearchParams(location.search),u=(q.get('utm_source')||q.get('origem')||'').toLowerCase().replace(/[^a-z0-9]/g,'').slice(0,12);
document.querySelectorAll('a[data-cad]').forEach(function(a){if(u)a.href=a.href.replace(/(origem=[a-z0-9-]+)/,'$1-'+u);});})();
</script>"""

for c in CIDADES:
    h = MODELO
    cad = 'https://central.engfoster.com.br/?sou=profissional&cidade=' + urllib.parse.quote(c['cadastro']) + '&origem=convite-lp-' + c['slug']
    zap = 'https://wa.me/5524992096103?text=' + urllib.parse.quote(f"Olá! Vi a página da Foster Central de {c['nome']} e quero saber mais.")
    h = h.replace('{{CIDADE}}', c['nome']).replace('{{SELO}}', c['selo']).replace('{{ATENDE}}', c['atende']).replace('{{QUEM}}', c['quem'])
    h = h.replace('{{ARQUIVO}}', c['arquivo']).replace('{{CADASTRO}}', cad.replace('&', '&amp;')).replace('{{ZAP}}', zap)
    h = h.replace('</body>', SCRIPT + '\n</body>')
    assert '{{' not in h, c['arquivo']
    (RAIZ / c['arquivo']).write_text(h, encoding='utf-8')
    print('gerado', c['arquivo'])
