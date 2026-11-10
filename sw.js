// Service worker: keeps the app's own files so it opens fast and without internet.
// Data never goes through here (Supabase calls go straight to the network; the snapshot is cached by the app).
// Bump VERSION whenever app files change, so phones pick up the new version.
const VERSION = 'fcl-v6';
const FILES = ['./', 'index.html', 'app.js', 'config.js', 'manifest.webmanifest', 'css/app.css', 'css/fonts.css',
  'assets/logo.jpg', 'assets/logo-mark.jpg', 'assets/icon-192.png', 'assets/icon-512.png',
  'assets/fonts/archivo-latin.woff2', 'assets/fonts/archivo-latin-ext.woff2',
  'lib/supabase.js', 'lib/qrcode.min.js', 'lib/jsQR.js', 'lib/html5-qrcode.min.js', 'lib/excel-plan.js',
  'api/client.js', 'api/auth.js', 'api/store.js',
  'ui/dom.js', 'ui/icons.js', 'ui/feedback.js', 'ui/charts.js', 'ui/print.js', 'ui/specs.js', 'ui/words.js',
  'views/common.js', 'views/home.js', 'views/stock.js', 'views/addlot.js', 'views/scan.js', 'views/laptop.js', 'views/people.js',
  'views/service.js', 'views/more.js', 'views/reports.js', 'views/backup.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;   // Supabase, Cloudinary: always network
  // config.js and index.html: network first (so a new key or version shows up), cache when offline
  if (url.pathname.endsWith('/config.js') || url.pathname.endsWith('/') || url.pathname.endsWith('/index.html')) {
    e.respondWith(fetch(e.request).then(r => { const copy = r.clone(); caches.open(VERSION).then(c => c.put(e.request, copy)); return r; })
      .catch(() => caches.match(e.request).then(r => r || caches.match('index.html'))));
    return;
  }
  e.respondWith(caches.match(e.request).then(r => r || fetch(e.request)));
});
