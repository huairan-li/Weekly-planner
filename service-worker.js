const CACHE = 'weekly-planner-v1';

const LOCAL_ASSETS = [
  './',
  './index.html',
  './manifest.json',
  './icon-192.svg',
  './icon-512.svg',
  './icon-maskable.svg',
];

// ── Install: pre-cache all local assets ──────────────────────────────────────
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE).then(cache => cache.addAll(LOCAL_ASSETS))
  );
  self.skipWaiting();
});

// ── Activate: delete stale caches ────────────────────────────────────────────
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys.filter(k => k !== CACHE).map(k => caches.delete(k))
      )
    )
  );
  self.clients.claim();
});

// ── Fetch ─────────────────────────────────────────────────────────────────────
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  // Google Fonts: stale-while-revalidate so offline still works after first load
  if (
    url.hostname === 'fonts.googleapis.com' ||
    url.hostname === 'fonts.gstatic.com'
  ) {
    event.respondWith(
      caches.open(CACHE).then(cache =>
        cache.match(event.request).then(cached => {
          const network = fetch(event.request).then(response => {
            cache.put(event.request, response.clone());
            return response;
          });
          return cached ?? network;
        })
      )
    );
    return;
  }

  // Everything else (local files): cache-first, network fallback
  event.respondWith(
    caches.match(event.request).then(cached => {
      if (cached) return cached;
      return fetch(event.request).then(response => {
        // Cache successful same-origin responses opportunistically
        if (
          response.ok &&
          url.origin === self.location.origin
        ) {
          caches.open(CACHE).then(cache =>
            cache.put(event.request, response.clone())
          );
        }
        return response;
      });
    }).catch(() =>
      // Full offline fallback: serve the app shell
      caches.match('./index.html')
    )
  );
});
