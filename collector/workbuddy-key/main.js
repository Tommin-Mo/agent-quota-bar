// 由 WorkBuddy 自带的 Electron 运行，调用其 secure-storage binding 读取 at-rest 密钥。
// 只输出一行 AQBKEY:<json>，不写任何文件。
try {
  const binding = process._linkedBinding('electron_browser_workbuddy_storage');
  const value = binding.loggerGet();
  process.stdout.write('AQBKEY:' + value + '\n');
} catch (error) {
  process.stderr.write('AQBKEY_ERR:' + (error && error.message ? error.message : String(error)) + '\n');
}
setTimeout(() => process.exit(0), 120);
