// Service worker de Nativo: hace que la web abra rápido (y aunque haya mala señal en la guardería).
//  - Páginas: primero la red (así siempre ves la última versión); si no hay señal, la última guardada.
//  - Logo, íconos, fuentes y la librería de Supabase: se guardan en el celu y salen de ahí.
//  - Datos (Supabase) y /api: nunca se guardan, siempre van a la red.
const V = 'nativo-v1';
const STATIC = /\/img\/|fonts\.(googleapis|gstatic)\.com|cdn\.jsdelivr\.net\/npm\/@supabase/;

self.addEventListener('install', e => {
  e.waitUntil(caches.open(V).then(c => c.addAll(['/', '/img/icon-sm.webp', '/img/logo.webp'])).catch(() => {}));
  self.skipWaiting();
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET' || u.pathname.startsWith('/api/') || u.hostname.endsWith('supabase.co')) return;
  if (r.mode === 'navigate') {
    e.respondWith(fetch(r).then(res => { if (res.ok && u.origin === location.origin && !u.search) caches.open(V).then(c => c.put('/', res.clone())); return res; })
      .catch(() => caches.match('/').then(c => c || Response.error())));
    return;
  }
  if (STATIC.test(r.url)) {
    e.respondWith(caches.match(r).then(hit => hit || fetch(r).then(res => {
      if (res.ok || res.type === 'opaque') { const cp = res.clone(); caches.open(V).then(c => c.put(r, cp)); }
      return res;
    })));
  }
});
