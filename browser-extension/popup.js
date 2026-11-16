async function load() {
  const list = document.getElementById('list');
  try {
    const res = await fetch('http://127.0.0.1:17890/snapshot', { cache: 'no-store' });
    const data = await res.json();
    const providers = data.providers || [];
    if (!providers.length) throw new Error('empty');
    list.innerHTML = '';
    for (const p of providers) {
      const percent = (p.metrics || []).find(m => m.kind === 'percent');
      const credit = (p.metrics || []).find(m => m.kind === 'credit');
      const value = percent ? `剩 ${Math.round(percent.remainingPercent)}%` : (credit?.headlineValue || p.headline || p.status || '—');
      const row = document.createElement('div');
      row.className = 'row';
      row.innerHTML = `<span class="name"></span><span class="val"></span>`;
      row.querySelector('.name').textContent = p.name;
      row.querySelector('.val').textContent = value;
      list.appendChild(row);
    }
    document.getElementById('time').textContent = new Date().toLocaleTimeString();
  } catch {
    list.innerHTML = '<p class="muted">本地服务未启动。先运行：node scripts/quota-server.js</p>';
  }
}
document.getElementById('open').addEventListener('click', () => {
  window.open('agentquotabar://open', '_blank');
});
load();
setInterval(load, 30000);
