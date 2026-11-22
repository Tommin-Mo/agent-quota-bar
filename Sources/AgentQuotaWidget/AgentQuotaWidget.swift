import SwiftUI
import WidgetKit

@available(macOS 14.0, *)
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: context.isPreview ? .preview : (Snapshot.load() ?? Snapshot(providers: []))))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: Date(), snapshot: Snapshot.load() ?? Snapshot(providers: []))
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
        Provider(id: "codex", name: "Codex", value: "本周剩 37%", sampledAt: "", cached: false),
        Provider(id: "opencode", name: "OpenCode", value: "5 小时剩 86%", sampledAt: "", cached: false),
    ])

    struct Provider: Decodable {
        let id: String
        let name: String
        let value: String
        let sampledAt: String
        let cached: Bool
    }

    static func load() -> Snapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent("Library/Application Support/AgentQuotaBar/widget-values.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}

@available(macOS 14.0, *)
struct AgentQuotaWidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            Text("额度概览")
                .font(.headline)
                .foregroundStyle(colorScheme == .dark ? Color(red: 134/255, green: 198/255, blue: 189/255) : Color(red: 11/255, green: 107/255, blue: 94/255))
            Divider()
            if entry.snapshot.providers.isEmpty {
                Text("等待额度数据").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.snapshot.providers, id: \.id) { provider in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(provider.name).fontWeight(.medium)
                    Spacer(minLength: 2)
                    Text(provider.value + (provider.cached ? "（缓存）" : ""))
                        .monospacedDigit()
                        .help(provider.sampledAt)
                }
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            colorScheme == .dark ? Color(red: 0.07, green: 0.10, blue: 0.09) : Color(red: 0.96, green: 0.95, blue: 0.94)
        }
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
        .description("查看已启用服务的剩余额度。")
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
