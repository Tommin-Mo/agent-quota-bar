async function load() {
  const list = document.getElementById('list');
  let connected = false;
  try {
    const res = await fetch('http://127.0.0.1:17890/snapshot', { cache: 'no-store' });
    connected = true;
    const data = await res.json();
    if (!res.ok || data.ok === false || !Array.isArray(data.providers)) throw new Error('unavailable');
    const providers = (data.providers || []).filter(p => p.presentation?.visible !== false && p.status !== 'disabled');

    list.innerHTML = '';
    if (!providers.length) list.textContent = '没有启用的服务';
    for (const p of providers) {
      const value = p.presentation?.primary || (p.status === 'error' ? '获取失败' : '暂无额度数据');
      const row = document.createElement('div');
      row.className = 'row';
      row.innerHTML = `<span class="name"></span><span class="val"></span>`;
      row.querySelector('.name').textContent = p.name;
      row.querySelector('.val').textContent = value;
      list.appendChild(row);
    }
    document.getElementById('time').textContent = data.sampledAt || data.updatedAt ? new Date(data.sampledAt || data.updatedAt).toLocaleTimeString() : '';
  } catch {
    document.getElementById('time').textContent = '';
    list.textContent = connected ? '额度读取失败，稍后会重试。' : '无法连接本机额度服务。';
  }
}
load();
setInterval(load, 30000);
