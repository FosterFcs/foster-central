"""Gera as páginas de captação por cidade: profissionais (<slug>.html, modelo-pagina-cidade.html)
e clientes (orcamento-<slug>.html, modelo-pagina-cliente.html).
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


# ---------------- páginas de clientes ----------------
MODELO_CLI = (RAIZ / 'ferramentas' / 'modelo-pagina-cliente.html').read_text(encoding='utf-8')
SERVICOS = [  # (ícone, rótulo, categoria do app, serviço do app) — os nomes precisam existir em CATEGORIAS do index.html
  ('🎨', 'Pintura', 'acabamento', 'Pintura'),
  ('🧱', 'Pedreiro e alvenaria', 'civil', 'Alvenaria'),
  ('⚡', 'Eletricista', 'eletrica', 'Fiação Elétrica'),
  ('💧', 'Encanador', 'hidraulica', 'Tubulação de Água'),
  ('🚿', 'Reforma de banheiro', 'hidraulica', 'Banheiro Completo'),
  ('🏠', 'Telhado', 'cobertura', 'Cobertura em Telha'),
  ('☔', 'Impermeabili\u00adzação', 'acabamento', 'Impermeabilização'),
  ('🛠️', 'Forro de gesso', 'obraSeca', 'Forro de Gesso'),
  ('🟫', 'Piso porcelanato', 'acabamento', 'Piso Porcelanato'),
  ('⚙️', 'Portão e serralheria', 'estrutura', 'Portão de Ferro'),
  ('❄️', 'Ar-condicionado', 'complementar', 'Ar-Condicionado'),
  ('📋', 'Laudo de engenheiro', 'engenharia', 'Laudo Técnico'),
  ('📐', 'Projeto estrutural', 'engenharia', 'Projeto Estrutural'),
  ('🏛️', 'Regularização de imóvel', 'engenharia', 'Regularização de Imóvel'),
]
SCRIPT_CLI = SCRIPT.replace("a[data-cad]", "a[data-ped]")
import html as _h
for c in CIDADES:
    base = 'https://central.engfoster.com.br/?cidade=' + urllib.parse.quote(c['cadastro'].replace('/', ' - ')) + '&origem=cliente-lp-' + c['slug']
    servs = '\n'.join(f'<a class="serv" data-ped href="{_h.escape(base + "&cat=" + cat + "&servico=" + urllib.parse.quote(sv))}"><span>{ic}</span><b>{_h.escape(rot)}</b></a>' for ic, rot, cat, sv in SERVICOS)
    zap = 'https://wa.me/5524992096103?text=' + urllib.parse.quote(f"Olá! Preciso de um orçamento de obra em {c['nome']}.")
    arq = 'orcamento-' + c['slug'] + '.html'
    h = MODELO_CLI.replace('{{CIDADE}}', c['nome']).replace('{{SELO}}', c['selo']).replace('{{QUEM}}', c['quem'].replace('conhece de perto a obra e quem trabalha nela', 'conhece de perto as obras e os profissionais da região'))
    h = h.replace('{{ARQUIVO}}', arq).replace('{{PEDIDO}}', _h.escape(base)).replace('{{ZAP}}', zap).replace('{{SERVICOS}}', servs).replace('{{PAGINA_PROF}}', c['arquivo'])
    h = h.replace('</body>', SCRIPT_CLI + '\n</body>')
    assert '{{' not in h, arq
    (RAIZ / arq).write_text(h, encoding='utf-8')
    print('gerado', arq)
