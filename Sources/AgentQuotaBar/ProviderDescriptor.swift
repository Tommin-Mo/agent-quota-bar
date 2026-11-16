import AppKit

/// 一家 Agent 的静态描述。UI、调度器、前台 App 识别都从这里取，
/// 不再各自维护一份 provider 列表。
struct ProviderDescriptor {
    let id: String
    let shortName: String
    let nativeAppBundleIDs: [String]
    let supportsSubscription: Bool
    let supportsCost: Bool
    let supportsMultipleAccounts: Bool

    var style: ProviderStyle { ProviderStyles.style(for: id) }
}

enum ProviderRegistry {
    static let all: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: "codex", shortName: "Codex",
            nativeAppBundleIDs: ["com.openai.codex"],
            supportsSubscription: true, supportsCost: true, supportsMultipleAccounts: true),
        ProviderDescriptor(
            id: "opencode", shortName: "OpenCode",
            nativeAppBundleIDs: ["ai.opencode.desktop"],
            supportsSubscription: false, supportsCost: true, supportsMultipleAccounts: true),
        ProviderDescriptor(
            id: "deepseek", shortName: "DeepSeek",
            nativeAppBundleIDs: [],
            supportsSubscription: false, supportsCost: true, supportsMultipleAccounts: true),
        ProviderDescriptor(
            id: "workbuddy", shortName: "WorkBuddy",
            nativeAppBundleIDs: ["com.tencent.workbuddy.mac"],
            supportsSubscription: false, supportsCost: false, supportsMultipleAccounts: true),
        ProviderDescriptor(
            id: "trae", shortName: "Trae",
            nativeAppBundleIDs: ["cn.trae.app"],
            supportsSubscription: false, supportsCost: false, supportsMultipleAccounts: true),
    ]

    static func provider(withID id: String) -> ProviderDescriptor? {
        all.first { $0.id == id }
    }

    static func provider(forBundleID bundleID: String?) -> ProviderDescriptor? {
        guard let bundleID else { return nil }
        return all.first { $0.nativeAppBundleIDs.contains(bundleID) }
    }

    static var ids: [String] { all.map(\.id) }
}
