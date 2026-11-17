// Office Meal Tracker service worker: shows the 8:30 reminder notification.
// It deliberately does not cache the app, so everyone always gets the latest version.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  event.waitUntil(
    self.registration.showNotification('আজ মিল নেবেন? / Meal today?', {
      body: 'সকাল ১১:৩০ এর আগে জানান / Answer before 11:30 am',
      icon: 'icons/icon-192.png',
      badge: 'icons/badge-96.png',
      tag: 'meal-reminder',
      renotify: true,
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const appUrl = self.registration.scope;
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if (c.url.startsWith(appUrl) && 'focus' in c) return c.focus();
      }
      return self.clients.openWindow(appUrl);
    })
  );
});
