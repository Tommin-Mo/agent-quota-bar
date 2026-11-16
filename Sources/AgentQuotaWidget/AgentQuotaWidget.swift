import SwiftUI
import WidgetKit

@available(macOS 14.0, *)
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: Snapshot.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: Date(), snapshot: Snapshot.load() ?? .preview)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

@available(macOS 14.0, *)
struct Entry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot
}

@available(macOS 14.0, *)
struct Snapshot: Decodable {
    let providers: [Provider]
    static let preview = Snapshot(providers: [
        Provider(id: "codex", name: "Codex", remaining: 37, detail: "2 天后重置"),
        Provider(id: "opencode", name: "OpenCode", remaining: 86, detail: "22 分钟后重置"),
    ])

    struct Provider: Decodable {
        let id: String
        let name: String
        let remaining: Double?
        let detail: String?
    }

    static func load() -> Snapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shared = home.appendingPathComponent("Library/Application Support/AgentQuotaBar/last-snapshot.json")
        let fallback = home.appendingPathComponent(".config/agent-quota/last-snapshot.json")
        let url = FileManager.default.fileExists(atPath: shared.path) ? shared : fallback
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = raw["providers"] as? [[String: Any]] else { return nil }
        let mapped: [Provider] = providers.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let metrics = item["metrics"] as? [[String: Any]] ?? []
            let percent = metrics.first { ($0["kind"] as? String) == "percent" }
            let remaining = percent?["remainingPercent"] as? Double
            let detail = percent?["detail"] as? String
            return Provider(id: id, name: name, remaining: remaining, detail: detail)
        }
        guard !mapped.isEmpty else { return nil }
        return Snapshot(providers: mapped)
    }
}

@available(macOS 14.0, *)
struct AgentQuotaWidgetView: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent 额度").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(entry.date, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(entry.snapshot.providers.prefix(4), id: \.id) { provider in
                HStack(spacing: 8) {
                    Text(provider.name).font(.system(size: 11, weight: .medium))
                    Spacer()
                    if let remaining = provider.remaining {
                        Text("\(Int(remaining.rounded()))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(remaining <= 20 ? .red : (remaining <= 45 ? .orange : .teal))
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@available(macOS 14.0, *)
struct AgentQuotaWidget: Widget {
    let kind = "AgentQuotaWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            AgentQuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("Agent 额度")
        .description("显示最近一家的 Agent 剩余额度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@available(macOS 14.0, *)
@main
struct AgentQuotaWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentQuotaWidget()
    }
}
