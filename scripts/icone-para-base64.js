/*
 * Prepara um PNG da pasta "ícones/" para virar ícone de categoria do catálogo.
 *
 *   node scripts/icone-para-base64.js "ícones/Blazers.png" [tamanho] [cores]
 *
 * Redimensiona (320px por padrão), reduz a uma paleta (32 cores por padrão) e
 * imprime o data URI pronto pra entrar em CAT_ICON_IMAGES, dentro do index.html.
 *
 * Por que reduzir: os originais da pasta são 1024x1024 com ~1MB cada. Embutidos
 * crus, dois ícones já engordariam o catálogo em quase 3MB — e o catálogo é
 * baixado inteiro pelo celular da cliente a cada visita. Os ícones que já estão
 * lá têm 9 a 20KB, com paleta de 12 cores; isto aqui chega perto disso.
 *
 * Sem dependências de propósito: o projeto não tem package.json e não vale
 * criar um por causa disto. Usa só zlib do próprio Node — PNG é, no fundo,
 * dados deflate com um cabeçalho em volta.
 */
const fs = require('fs');
const zlib = require('zlib');

/* ---------- leitura do PNG ---------- */
function lerPNG(arquivo){
  const b = fs.readFileSync(arquivo);
  if(b.readUInt32BE(0) !== 0x89504e47) throw new Error('não parece um PNG: ' + arquivo);
  let off = 8, ihdr = null, idat = [];
  while(off < b.length - 8){
    const len = b.readUInt32BE(off);
    const tipo = b.toString('ascii', off + 4, off + 8);
    const dados = b.slice(off + 8, off + 8 + len);
    if(tipo === 'IHDR'){
      ihdr = { w: dados.readUInt32BE(0), h: dados.readUInt32BE(4), prof: dados[8], cor: dados[9], entrelacado: dados[12] };
    } else if(tipo === 'IDAT'){
      idat.push(dados);
    } else if(tipo === 'IEND'){ break; }
    off += 12 + len;
  }
  if(!ihdr) throw new Error('PNG sem IHDR');
  if(ihdr.prof !== 8) throw new Error('só trato PNG de 8 bits por canal (este tem ' + ihdr.prof + ')');
  if(ihdr.entrelacado) throw new Error('PNG entrelaçado não é tratado aqui');
  if(ihdr.cor !== 2 && ihdr.cor !== 6) throw new Error('só trato PNG RGB ou RGBA (tipo de cor ' + ihdr.cor + ')');
  const canais = ihdr.cor === 2 ? 3 : 4;
  const cru = zlib.inflateSync(Buffer.concat(idat));
  return { ...ihdr, canais, pixels: desfiltrar(cru, ihdr.w, ihdr.h, canais) };
}

// Desfaz os filtros por linha do PNG (spec: 0 nenhum, 1 sub, 2 up, 3 média, 4 Paeth).
function desfiltrar(cru, w, h, canais){
  const passo = w * canais;
  const saida = Buffer.alloc(h * passo);
  let pos = 0;
  for(let y = 0; y < h; y++){
    const filtro = cru[pos++];
    const linha = cru.slice(pos, pos + passo); pos += passo;
    const destino = saida.slice(y * passo, (y + 1) * passo);
    const anterior = y > 0 ? saida.slice((y - 1) * passo, y * passo) : Buffer.alloc(passo);
    for(let x = 0; x < passo; x++){
      const a = x >= canais ? destino[x - canais] : 0;
      const b = anterior[x];
      const c = x >= canais ? anterior[x - canais] : 0;
      let v = linha[x];
      if(filtro === 1) v += a;
      else if(filtro === 2) v += b;
      else if(filtro === 3) v += (a + b) >> 1;
      else if(filtro === 4){
        const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
      }
      destino[x] = v & 255;
    }
  }
  return saida;
}

/* ---------- redimensionamento ---------- */
// Média da área de origem (box filter). Como só reduzimos, e bastante, isso dá
// resultado limpo sem precisar de filtro mais caro.
function redimensionar(img, destino){
  const { w, h, canais, pixels } = img;
  const saida = Buffer.alloc(destino * destino * 3);
  for(let y = 0; y < destino; y++){
    const y0 = Math.floor(y * h / destino), y1 = Math.max(y0 + 1, Math.floor((y + 1) * h / destino));
    for(let x = 0; x < destino; x++){
      const x0 = Math.floor(x * w / destino), x1 = Math.max(x0 + 1, Math.floor((x + 1) * w / destino));
      let r = 0, g = 0, b = 0, n = 0;
      for(let sy = y0; sy < y1; sy++){
        for(let sx = x0; sx < x1; sx++){
          const i = (sy * w + sx) * canais;
          r += pixels[i]; g += pixels[i + 1]; b += pixels[i + 2]; n++;
        }
      }
      const o = (y * destino + x) * 3;
      saida[o] = Math.round(r / n); saida[o + 1] = Math.round(g / n); saida[o + 2] = Math.round(b / n);
    }
  }
  return saida;
}

/* ---------- paleta (corte mediano) ---------- */
// Divide repetidamente o conjunto de cores pelo canal de maior amplitude,
// sempre partindo a caixa mais populosa. É o algoritmo clássico de median cut,
// que preserva bem arte chapada como a destes ícones.
function paletizar(rgb, maxCores){
  const total = rgb.length / 3;
  const indices = new Array(total);
  for(let i = 0; i < total; i++) indices[i] = i;
  let caixas = [{ ids: indices, prof: 0 }];
  while(caixas.length < maxCores){
    caixas.sort((a, b) => b.ids.length - a.ids.length);
    const caixa = caixas.find(c => c.ids.length > 1);
    if(!caixa) break;
    let min = [255, 255, 255], max = [0, 0, 0];
    caixa.ids.forEach(i => {
      for(let c = 0; c < 3; c++){
        const v = rgb[i * 3 + c];
        if(v < min[c]) min[c] = v;
        if(v > max[c]) max[c] = v;
      }
    });
    const canal = [0, 1, 2].reduce((m, c) => (max[c] - min[c]) > (max[m] - min[m]) ? c : m, 0);
    if(max[canal] === min[canal]) break;
    caixa.ids.sort((a, b) => rgb[a * 3 + canal] - rgb[b * 3 + canal]);
    const meio = caixa.ids.length >> 1;
    caixas = caixas.filter(c => c !== caixa);
    caixas.push({ ids: caixa.ids.slice(0, meio) }, { ids: caixa.ids.slice(meio) });
  }
  const paleta = caixas.filter(c => c.ids.length).map(c => {
    let r = 0, g = 0, b = 0;
    c.ids.forEach(i => { r += rgb[i * 3]; g += rgb[i * 3 + 1]; b += rgb[i * 3 + 2]; });
    const n = c.ids.length;
    return [Math.round(r / n), Math.round(g / n), Math.round(b / n)];
  });
  const idx = Buffer.alloc(total);
  let erro = 0;
  for(let i = 0; i < total; i++){
    const r = rgb[i * 3], g = rgb[i * 3 + 1], b = rgb[i * 3 + 2];
    let melhor = 0, melhorD = Infinity;
    for(let p = 0; p < paleta.length; p++){
      const d = (r - paleta[p][0]) ** 2 + (g - paleta[p][1]) ** 2 + (b - paleta[p][2]) ** 2;
      if(d < melhorD){ melhorD = d; melhor = p; }
    }
    idx[i] = melhor; erro += Math.sqrt(melhorD);
  }
  return { paleta, idx, erroMedio: erro / total };
}

/* ---------- gravação do PNG com paleta ---------- */
const TABELA_CRC = (() => {
  const t = new Int32Array(256);
  for(let n = 0; n < 256; n++){
    let c = n;
    for(let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c;
  }
  return t;
})();
function crc32(buf){
  let c = -1;
  for(let i = 0; i < buf.length; i++) c = TABELA_CRC[(c ^ buf[i]) & 255] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function pedaco(tipo, dados){
  const cab = Buffer.alloc(8);
  cab.writeUInt32BE(dados.length, 0);
  cab.write(tipo, 4, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([Buffer.from(tipo, 'ascii'), dados])), 0);
  return Buffer.concat([cab, dados, crc]);
}
function gravarPNGPaleta(lado, paleta, idx){
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(lado, 0); ihdr.writeUInt32BE(lado, 4);
  ihdr[8] = 8;   // bits por amostra
  ihdr[9] = 3;   // tipo de cor: paleta
  const plte = Buffer.alloc(paleta.length * 3);
  paleta.forEach((c, i) => { plte[i * 3] = c[0]; plte[i * 3 + 1] = c[1]; plte[i * 3 + 2] = c[2]; });
  // Cada linha entra com o byte de filtro 0 na frente: a imagem é pequena e
  // indexada, e filtrar índice de paleta costuma piorar a compressão.
  const cru = Buffer.alloc(lado * (lado + 1));
  for(let y = 0; y < lado; y++){
    cru[y * (lado + 1)] = 0;
    idx.copy(cru, y * (lado + 1) + 1, y * lado, (y + 1) * lado);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pedaco('IHDR', ihdr),
    pedaco('PLTE', plte),
    pedaco('IDAT', zlib.deflateSync(cru, { level: 9 })),
    pedaco('IEND', Buffer.alloc(0))
  ]);
}

/* ---------- linha de comando ---------- */
if(require.main === module){
  const arquivo = process.argv[2];
  if(!arquivo){
    console.error('uso: node scripts/icone-para-base64.js "ícones/Nome.png" [tamanho] [cores]');
    process.exit(1);
  }
  const lado = Number(process.argv[3]) || 320;
  const cores = Number(process.argv[4]) || 32;
  const img = lerPNG(arquivo);
  const rgb = redimensionar(img, lado);
  const { paleta, idx, erroMedio } = paletizar(rgb, cores);
  const png = gravarPNGPaleta(lado, paleta, idx);
  const b64 = png.toString('base64');
  const chave = require('path').basename(arquivo, '.png')
    .toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]/g, '');
  console.error('origem ...: ' + img.w + 'x' + img.h + ', ' + Math.round(fs.statSync(arquivo).size / 1024) + 'KB');
  console.error('resultado : ' + lado + 'x' + lado + ', ' + paleta.length + ' cores, ' + Math.round(png.length / 1024) + 'KB');
  console.error('erro medio: ' + erroMedio.toFixed(1) + ' (distancia RGB por pixel; abaixo de ~8 e imperceptivel)');
  console.error('chave ....: ' + chave);
  console.log('  ' + chave + ': "data:image/png;base64,' + b64 + '",');
}

module.exports = { lerPNG, redimensionar, paletizar, gravarPNGPaleta };
