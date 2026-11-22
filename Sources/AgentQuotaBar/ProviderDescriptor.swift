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
    static let traeEditions = [("cn", "Trae CN（国内版）"), ("solo", "TRAE SOLO CN"), ("sg", "Trae（国际版）"), ("solo-sg", "TRAE SOLO（国际版）")]
    static let builtins: [ProviderDescriptor] = [
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
        ProviderDescriptor(
            id: "doubao", shortName: "豆包",
            nativeAppBundleIDs: [DoubaoQuota.bundleID],
            supportsSubscription: false, supportsCost: false, supportsMultipleAccounts: false),
    ]

    private static var local: [ProviderDescriptor] = []
    static var all: [ProviderDescriptor] { builtins + local }

    static func update(from rows: [ProviderStatus]) {
        let reserved = Set(builtins.map(\.id))
        local = rows.filter { !reserved.contains($0.id) }.map {
            ProviderDescriptor(id: $0.id, shortName: $0.name, nativeAppBundleIDs: [],
                               supportsSubscription: false, supportsCost: false, supportsMultipleAccounts: false)
        }.sorted { $0.id < $1.id }
    }

    static func usesLocalQuota(_ id: String) -> Bool {
        id == "doubao" || !builtins.contains { $0.id == id }
    }

    static func provider(withID id: String) -> ProviderDescriptor? {
        all.first { $0.id == id }
    }

    static func provider(forBundleID bundleID: String?) -> ProviderDescriptor? {
        guard let bundleID else { return nil }
        return all.first { $0.nativeAppBundleIDs.contains(bundleID) }
    }

    static var ids: [String] { all.map(\.id) }
}
