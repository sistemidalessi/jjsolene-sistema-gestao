// Regenera catalogo/index.html a partir de CATALOG_CSS / CATALOG_JS / buildCatalogHTML do index.html.
// Uso (na raiz do repo):  node scripts/gera-catalogo.js
// Conferido em 21/09/2026: rodando sobre o index.html commitado, a saida e identica, byte a byte, ao
// catalogo/index.html publicado - entao um `git diff catalogo/index.html` depois de rodar mostra SO o
// que voce mudou no template. Regenerar e commitar sempre que mexer em CATALOG_CSS / CATALOG_JS.
const fs = require('fs'), vm = require('vm'), path = require('path');
const repo = process.argv[2] || path.join(__dirname, "..");
const saida = process.argv[3] || path.join(repo, "catalogo", "index.html");
// copia de trabalho no Windows vem com CRLF; o git guarda LF
const src = fs.readFileSync(path.join(repo, 'index.html'), 'utf8').replace(/\r\n/g, '\n');

function trecho(inicio, fimRegex) {
  const i = src.indexOf(inicio);
  if (i < 0) throw new Error('nao achei: ' + inicio);
  const resto = src.slice(i);
  const m = resto.match(fimRegex);
  if (!m) throw new Error('nao achei o fim de: ' + inicio);
  return resto.slice(0, m.index + m[0].length);
}
const css = trecho('const CATALOG_CSS = [', /\n\]\.join\('\\n'\);/);
const js = trecho('const CATALOG_JS = [', /\n\]\.join\('\\n'\);/);
const build = trecho('function buildCatalogHTML(sbUrl, sbAnon){', /\n\}\n/);
const url = src.match(/const DEFAULT_SB_URL = '([^']+)'/)[1];
const anon = src.match(/const DEFAULT_SB_ANON = '([^']+)'/)[1];

const ctx = vm.createContext({});
// const -> var pra ficarem visiveis no contexto
vm.runInContext(css.replace(/^const /, 'var ') + '\n' + js.replace(/^const /, 'var ') + '\n' + build, ctx);
ctx.__u = url; ctx.__a = anon;
const html = vm.runInContext('buildCatalogHTML(__u, __a)', ctx);
fs.writeFileSync(saida, html, 'utf8');
console.log('gerado:', html.length, 'caracteres,', html.split('\n').length, 'linhas');
