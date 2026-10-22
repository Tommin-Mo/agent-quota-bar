import Foundation
import Network

/// 网络恢复时立即触发刷新；DNS 恢复但路径仍 satisfied 的情况由离线重试定时器兜底。
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.tommin.agentquotabar.network")
    var onChange: ((Bool) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.onChange?(online) }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
