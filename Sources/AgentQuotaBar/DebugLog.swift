import Foundation

/// 仅用于开发排查：AQB_LOG=1 时写入 /tmp/aqb.log。
func log(_ message: String) {
    guard ProcessInfo.processInfo.environment["AQB_LOG"] == "1" else { return }
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/aqb.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}
