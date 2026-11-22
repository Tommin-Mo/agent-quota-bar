import Foundation

/// 仅用于开发排查：AQB_LOG=1 时写入 /tmp/aqb.log。
func log(_ message: String) {
    guard ProcessInfo.processInfo.environment["AQB_LOG"] == "1" else { return }
    // Standard error is owned by the launcher; do not create a shared plaintext log.
    FileHandle.standardError.write(Data(("[AgentQuotaBar] " + message + "\n").utf8))
}
