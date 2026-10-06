const CACHE='chef-pocket-shell-v1';
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(['/','/manifest.webmanifest','/icon.svg'])));});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))));});
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(u.origin!==self.location.origin||e.request.method!=='GET'||u.pathname.startsWith('/api/')||u.pathname.includes('chatgpt')||u.pathname==='/callback')return;
 if(e.request.mode==='navigate'&&u.pathname==='/')e.respondWith(fetch(e.request).then(r=>{if(r.ok){const copy=r.clone();caches.open(CACHE).then(c=>c.put('/',copy));}return r;}).catch(()=>caches.match('/')));
 else if(u.pathname.startsWith('/_next/')||u.pathname.startsWith('/assets/')||['/icon.svg','/manifest.webmanifest'].includes(u.pathname))e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request).then(v=>{if(v.ok)caches.open(CACHE).then(c=>c.put(e.request,v.clone()));return v;})));
});
