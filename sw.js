// Service worker: keeps the app's own files so it opens fast and without internet.
// Data never goes through here (Supabase calls go straight to the network; the snapshot is cached by the app).
// Bump VERSION whenever app files change, so phones pick up the new version.
const VERSION = 'fcl-v10';
const SHARE = 'fcl-share';   // a photo shared into the app waits here until the app reads it
const FILES = ['./', 'index.html', 'app.js', 'config.js', 'manifest.webmanifest', 'css/app.css', 'css/fonts.css',
  'assets/logo.jpg', 'assets/logo-mark.jpg', 'assets/icon-192.png', 'assets/icon-512.png',
  'assets/fonts/archivo-latin.woff2', 'assets/fonts/archivo-latin-ext.woff2',
  'lib/supabase.js', 'lib/qrcode.min.js', 'lib/jsQR.js', 'lib/html5-qrcode.min.js', 'lib/excel-plan.js',
  'api/client.js', 'api/auth.js', 'api/store.js',
  'ui/dom.js', 'ui/icons.js', 'ui/feedback.js', 'ui/charts.js', 'ui/print.js', 'ui/specs.js', 'ui/words.js', 'ui/exporters.js',
  'views/common.js', 'views/home.js', 'views/stock.js', 'views/addlot.js', 'views/accessories.js', 'views/scan.js', 'views/laptop.js', 'views/people.js',
  'views/service.js', 'views/more.js', 'views/reports.js', 'views/backup.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION && k !== SHARE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // Share → First Choice (Android): keep the photo, then open the Scan screen, which reads it
  if (e.request.method === 'POST' && url.origin === location.origin && url.pathname.endsWith('/share-target')) {
    e.respondWith((async () => {
      try {
        const f = (await e.request.formData()).get('photo');
        if (f && f.size) await (await caches.open(SHARE)).put(new URL('shared-photo', self.registration.scope).href, new Response(f, { headers: { 'Content-Type': f.type || 'image/jpeg' } }));
      } catch (x) { /* nothing shared */ }
      return Response.redirect(new URL('./?shared=1', self.registration.scope).href, 303);
    })());
    return;
  }
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;   // Supabase, Cloudinary: always network
  // config.js and index.html: network first (so a new key or version shows up), cache when offline
  if (url.pathname.endsWith('/config.js') || url.pathname.endsWith('/') || url.pathname.endsWith('/index.html')) {
    e.respondWith(fetch(e.request).then(r => { const copy = r.clone(); caches.open(VERSION).then(c => c.put(e.request, copy)); return r; })
      .catch(() => caches.match(e.request).then(r => r || caches.match('index.html'))));
    return;
  }
  e.respondWith(caches.match(e.request).then(r => r || fetch(e.request)));
});

// Tapping a low-stock phone notification opens the app on Notifications
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
    const c = cs.find(x => 'focus' in x);
    if (c) { c.postMessage({ type: 'open-notifs' }); return c.focus(); }
    return self.clients.openWindow(new URL('./?notifs=1', self.registration.scope).href);
  }));
});
