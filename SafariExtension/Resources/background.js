// Hands Safari downloads over to the Anchor app through its local bridge on 127.0.0.1.
// Safari has no downloads API, so content.js catches clicks on download links and asks this page to send them.
const API = 'http://127.0.0.1:47821';

async function isEnabled() {
  const { enabled = true } = await browser.storage.local.get('enabled');
  return enabled;
}

async function appAvailable() {
  try {
    const res = await fetch(`${API}/ping`, { signal: AbortSignal.timeout(800) });
    const json = await res.json();
    return json.enabled === true;
  } catch {
    return false;
  }
}

async function sendToAnchor(url, filename, referrer) {
  let cookies = '';
  try {
    cookies = (await browser.cookies.getAll({ url })).map((c) => `${c.name}=${c.value}`).join('; ');
  } catch {}
  try {
    const res = await fetch(`${API}/add`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url, filename, referrer, cookies, userAgent: navigator.userAgent }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

// Whether Anchor is running with browser downloads on. Kept in local storage so content scripts can
// decide synchronously, inside the click handler, whether to take a link.
async function refresh() {
  const anchorReady = (await isEnabled()) && (await appAvailable());
  await browser.storage.local.set({ anchorReady });
}

browser.runtime.onMessage.addListener((message) => {
  if (message?.type !== 'add') return;
  return sendToAnchor(message.url, message.filename, message.referrer).then((ok) => {
    if (!ok) refresh(); // Anchor went away: stop taking links until it is back.
    return ok;
  });
});

browser.alarms.create('anchor-ping', { periodInMinutes: 0.5 });
browser.alarms.onAlarm.addListener((alarm) => { if (alarm.name === 'anchor-ping') refresh(); });
browser.runtime.onStartup.addListener(refresh);
browser.storage.onChanged.addListener((changes, area) => { if (area === 'local' && 'enabled' in changes) refresh(); });
refresh();

browser.runtime.onInstalled.addListener(() => {
  refresh();
  browser.contextMenus.create({
    id: 'anchor-download',
    title: 'Download with Anchor',
    contexts: ['link', 'video', 'audio', 'image'],
  });
});

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  const url = info.linkUrl || info.srcUrl;
  if (url) await sendToAnchor(url, undefined, tab?.url);
});
