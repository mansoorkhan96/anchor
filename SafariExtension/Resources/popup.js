const toggle = document.getElementById('enabled');

browser.storage.local.get('enabled').then(({ enabled = true }) => { toggle.checked = enabled; });
toggle.addEventListener('change', () => browser.storage.local.set({ enabled: toggle.checked }));

fetch('http://127.0.0.1:47821/ping', { signal: AbortSignal.timeout(800) })
  .then((r) => r.json())
  .then((j) => {
    document.getElementById('dot').classList.toggle('on', j.enabled);
    document.getElementById('status').textContent = j.enabled ? 'Connected to Drift' : 'Browser downloads are off in Drift';
  })
  .catch(() => { document.getElementById('status').textContent = 'Drift is not running'; });
