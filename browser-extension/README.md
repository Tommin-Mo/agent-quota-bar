# AgentQuotaBar 浏览器扩展

这是一个**只读查看器**，不是 Cookie 采集器：

1. 在本机启动：
   ```bash
   node scripts/quota-server.js
   ```
2. Chrome → `chrome://extensions` → 开发者模式 → 加载已解压的扩展 → 选这个目录。
3. 点扩展图标查看当前额度。

它只访问 `http://127.0.0.1:17890/snapshot`，不读取网页 Cookie，不上传任何数据。
