// Builds www/ (the app the Android wrapper loads) from src/app.html.
// Bundles fonts and the zip reader locally so the app works offline, and writes config.js.
import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const www = path.join(root, 'www');
fs.rmSync(www, { recursive: true, force: true });
fs.mkdirSync(path.join(www, 'fonts'), { recursive: true });
fs.mkdirSync(path.join(www, 'vendor'), { recursive: true });

// Fonts
const fonts = [
  ['Figtree', '@fontsource/figtree/files/figtree-latin-{w}-normal.woff2', [400, 500, 600, 700]],
  ['Bricolage Grotesque', '@fontsource/bricolage-grotesque/files/bricolage-grotesque-latin-{w}-normal.woff2', [600, 800]],
  ['IBM Plex Mono', '@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-{w}-normal.woff2', [500]],
];
let css = '';
for (const [family, pattern, weights] of fonts) {
  for (const w of weights) {
    const src = path.join(root, 'node_modules', pattern.replace('{w}', w));
    const name = path.basename(src);
    fs.copyFileSync(src, path.join(www, 'fonts', name));
    css += `@font-face{font-family:"${family}";font-style:normal;font-weight:${w};font-display:swap;src:url(${name}) format("woff2")}\n`;
  }
}
fs.writeFileSync(path.join(www, 'fonts', 'fonts.css'), css);
for (const [src, name] of [
  ['jszip/dist/jszip.min.js', 'jszip.min.js'],
  ['qrcode-generator/dist/qrcode.js', 'qrcode.js'],
  ['jsqr/dist/jsQR.js', 'jsQR.js'],
  ['@supabase/supabase-js/dist/umd/supabase.js', 'supabase.js'],
  ['leaflet/dist/leaflet.js', 'leaflet.js'],
  ['leaflet/dist/leaflet.css', 'leaflet.css'],
]) fs.copyFileSync(path.join(root, 'node_modules', src), path.join(www, 'vendor', name));

// Config comes from the environment (GitHub secrets) or config.local.json.
// TASTEMATE_TARGET=web builds the website (vendors can buy tokens there); anything else builds the Android app.
const target = process.env.TASTEMATE_TARGET === 'web' ? 'web' : 'android';
// OSM: interactive OpenStreetMap map and live places when there's no Google Maps key (set TASTEMATE_OSM=false to turn off)
let cfg = { GOOGLE_MAPS_API_KEY: '', GOOGLE_MAP_ID: '', SUPABASE_URL: '', SUPABASE_ANON_KEY: '', APP_URL: '', BUY_TOKENS_IN_APP: target === 'web', OSM: process.env.TASTEMATE_OSM !== 'false', BUILD: true };
const local = path.join(root, 'config.local.json');
if (fs.existsSync(local)) Object.assign(cfg, JSON.parse(fs.readFileSync(local, 'utf8')));
if (process.env.TASTEMATE_MAPS_KEY) cfg.GOOGLE_MAPS_API_KEY = process.env.TASTEMATE_MAPS_KEY;
if (process.env.TASTEMATE_MAP_ID) cfg.GOOGLE_MAP_ID = process.env.TASTEMATE_MAP_ID;
if (process.env.SUPABASE_URL) cfg.SUPABASE_URL = process.env.SUPABASE_URL;
if (process.env.SUPABASE_ANON_KEY) cfg.SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
if (process.env.APP_URL) cfg.APP_URL = process.env.APP_URL;
if (process.env.BUY_TOKENS_IN_APP) cfg.BUY_TOKENS_IN_APP = process.env.BUY_TOKENS_IN_APP === 'true';
fs.writeFileSync(path.join(www, 'config.js'), `window.TASTEMATE_CONFIG = ${JSON.stringify(cfg, null, 2)};\n`);

// Page
let app = fs.readFileSync(path.join(root, 'src/app.html'), 'utf8');
app = app.replace(/<link rel="preconnect"[^>]*>\s*/g, '')
         .replace(/<link rel="stylesheet" href="https:\/\/fonts\.googleapis\.com[^>]*>/, '<link rel="stylesheet" href="fonts/fonts.css">')
         .replace(/<script src="https:\/\/cdnjs\.cloudflare\.com\/ajax\/libs\/jszip\/[^"]+"><\/script>/, '<script src="vendor/jszip.min.js"></script>\n<script src="vendor/jsQR.js"></script>\n<script src="vendor/supabase.js"></script>\n<link rel="stylesheet" href="vendor/leaflet.css">\n<script src="vendor/leaflet.js"></script>')
         .replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/qrcode-generator[^"]+"><\/script>/, '<script src="vendor/qrcode.js"></script>');
const split = app.indexOf('<div class="app">');
const head = app.slice(0, split), body = app.slice(split);
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#5B21B6">
<style>[hidden]{display:none!important}img{max-width:100%}html{-webkit-text-size-adjust:100%}</style>
<script src="config.js"></script>
${head}
</head>
<body>
${body}
</body>
</html>
`;
fs.writeFileSync(path.join(www, 'index.html'), html);
if (target === 'web' && fs.existsSync(path.join(root, 'docs'))) for (const f of fs.readdirSync(path.join(root, 'docs'))) fs.copyFileSync(path.join(root, 'docs', f), path.join(www, f));
console.log(`Built www/ for ${target}: ` + [cfg.SUPABASE_URL ? 'live backend' : 'DEMO MODE (no backend configured)', cfg.GOOGLE_MAPS_API_KEY ? 'Google Maps + Places' : cfg.OSM ? 'OpenStreetMap map + places' : 'simple map'].join(', '));
