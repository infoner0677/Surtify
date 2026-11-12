/* Surtify · service worker
   - Guarda la "cáscara" de la app para que abra sin internet.
   - NUNCA guarda llamadas a Supabase (datos, ventas, sesión): esas siempre van a la red.
   - Páginas: primero la red (para recibir actualizaciones) y, si falla, la copia guardada. */
const V = 'surtify-v11';
const SHELL = ['./', 'index.html', 'config.js', 'manifest.webmanifest', 'assets/logo.png', 'assets/favicon.png',
  'assets/icon-192.png', 'assets/icon-512.png', 'assets/apple-touch-icon.png',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js',
  'https://cdn.jsdelivr.net/npm/@zxing/library@0.21.3/umd/index.min.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(V).then(c => Promise.all(SHELL.map(u => c.add(u).catch(() => {})))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET') return;
  if (u.hostname.endsWith('supabase.co')) return;                     // datos: siempre red
  const mismo = u.origin === location.origin, cdn = u.hostname === 'cdn.jsdelivr.net';
  if (!mismo && !cdn) return;
  if (r.mode === 'navigate' || (mismo && /(index\.html|config\.js)$/.test(u.pathname))) {
    e.respondWith(fetch(r).then(res => { const cp = res.clone(); caches.open(V).then(c => c.put(r, cp)); return res; })
      .catch(() => caches.match(r).then(m => m || caches.match('index.html'))));
    return;
  }
  e.respondWith(caches.match(r).then(m => m || fetch(r).then(res => { const cp = res.clone(); caches.open(V).then(c => c.put(r, cp)); return res; })));
});
