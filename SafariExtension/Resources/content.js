// Catches clicks on download links before Safari starts them and hands them to Drift.
// Safari can't tell extensions about downloads, so links are recognised by their download attribute or
// file extension. Types Safari shows in the tab (PDFs, text, common audio and video) are left alone
// unless the link asks to be downloaded; "Download with Drift" in the context menu covers everything else.
const EXTENSIONS = new Set([
  'mkv', 'avi', 'wmv', 'flv', 'mpg', 'mpeg', 'ts', '3gp',
  'flac', 'ogg', 'opus', 'aiff', 'wma', 'alac',
  'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'zst', 'iso', 'lz', 'cab',
  'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'epub', 'rtf', 'pages', 'numbers', 'key',
  'dmg', 'pkg', 'exe', 'msi', 'apk', 'deb', 'rpm', 'appimage', 'mpkg',
  'torrent', 'bin', 'img', 'jar',
]);

let ready = false;
browser.storage.local.get('driftReady').then(({ driftReady = false }) => { ready = driftReady; });
browser.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && 'driftReady' in changes) ready = changes.driftReady.newValue === true;
});

// Links Drift couldn't take, clicked again so Safari downloads them itself.
const handedBack = new WeakSet();

function looksLikeDownload(link, url) {
  if (link.hasAttribute('download')) return true;
  const name = url.pathname.split('/').pop();
  return name.includes('.') && EXTENSIONS.has(name.split('.').pop().toLowerCase());
}

document.addEventListener('click', (event) => {
  if (!ready || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const link = event.composedPath().find((el) => el instanceof HTMLAnchorElement && el.href);
  if (!link || handedBack.delete(link)) return;
  let url;
  try { url = new URL(link.href); } catch { return; }
  if (!/^https?:$/.test(url.protocol) || !looksLikeDownload(link, url)) return;

  event.preventDefault();
  event.stopImmediatePropagation();
  const handBack = () => { handedBack.add(link); link.click(); };
  browser.runtime
    .sendMessage({ type: 'add', url: url.href, filename: link.getAttribute('download') || undefined, referrer: location.href })
    .then((ok) => { if (!ok) handBack(); }, handBack);
}, true);
