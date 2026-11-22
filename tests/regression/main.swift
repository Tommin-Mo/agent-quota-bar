import AppKit

// All disk-backed stores below are confined to the disposable test configuration.
guard let fixture = ProcessInfo.processInfo.environment["AGENT_QUOTA_CONFIG"],
      URL(fileURLWithPath: fixture).lastPathComponent == "regression-config.json" else { fatalError("test configuration required") }
let service = QuotaService(publishWidgets: false)
QuotaStyle.apply(service.config)
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func window(_ name: String, _ remaining: Double) -> [String: Any] {
    ["label": name, "kind": "percent", "remainingPercent": remaining, "usedPercent": 100 - remaining]
}
func credit(_ value: String, _ currency: String = "") -> [String: Any] {
    ["label": currency.isEmpty ? "积分" : "余额", "kind": "credit", "headlineValue": value, "currency": currency]
}
func provider(_ id: String, _ metrics: [[String: Any]], _ extra: [String: Any] = [:]) -> ProviderStatus {
    var object: [String: Any] = ["id": id, "name": id, "status": "ok", "metrics": metrics]
    object.merge(extra) { _, value in value }
    return try! JSONDecoder().decode(ProviderStatus.self, from: JSONSerialization.data(withJSONObject: object))
}
let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(10)
func snap(_ providers: [ProviderStatus], _ offset: Double = 0) -> QuotaSnapshot {
    let stamp = ISO8601DateFormatter.flexible.string(from: start.addingTimeInterval(offset))
    return QuotaSnapshot(schema: 1, updatedAt: stamp, sampledAt: stamp, providers: providers)
}
let codex = provider("codex", [window("5 小时", 85), window("本周", 100)])
check(codex.displayPrimaryValue == "100%" && snap([provider("codex", [window("本周", 100)])]).menuBarItem(for: "codex")?.value == "100", "Codex weekly / full")
check(DoubaoQuota.amount(in: "3,020入") == 3020 && DoubaoQuota.amount(in: "0 ↗") == 0, "Doubao sidebar quota handles grouped values and real zero")
for invalid in ["", "3,02", "1.001", "12%", "3,020 次", "-2", "3 020", "2.50"] {
    check(DoubaoQuota.amount(in: invalid) == nil, "Doubao rejects non-quota token " + invalid)
}
let doubao = provider("doubao", [["label": "可用额度", "kind": "credit", "value": 3020, "headlineValue": "3020"]])
check(doubao.unitSuffix == "额度" && doubao.displayPrimaryValue == "3,020", "Doubao has its native unit and grouped value")
var doubaoDay = UsageHistoryEntry(date: "2026-11-21", provider: "doubao")
doubaoDay.dailyTotals = ["额度": 302]
doubaoDay.balanceUnit = "额度"
doubaoDay.openingBalances = ["account": 3020]
check(doubaoDay.consumptionPercent == 10 && HistoryWindowController.consumptionLines(doubaoDay) == ["302 额度"], "Doubao wallet consumption drives calendar heat and details")
let feedAgent = provider("demo-agent", [window("本周", 83), window("5 小时", 0)], ["name": "Demo"])
service.apply(snap([doubao, feedAgent]))
check(ProviderRegistry.provider(withID: "demo-agent")?.shortName == "Demo" &&
      ProviderStyles.style(for: "demo-agent").letter == "D" && feedAgent.hasExpandableWindows,
      "external agent becomes a named multi-window service")
check(service.snapshot?.menuBarItem(for: "demo-agent")?.value == "0" &&
      service.snapshot?.menuBarItem(for: "doubao")?.value == "3,020", "dynamic and native quotas reach the menu bar")
let noSidebar = provider("doubao", [], ["status": "error", "error": "请展开豆包侧栏的可用额度"])
service.apply(snap([noSidebar], 1), only: ["doubao"])
check(service.snapshot?.provider(withID: "doubao")?.cached == true &&
      service.snapshot?.provider(withID: "doubao")?.displayPrimaryValue == "3,020", "unreadable sidebar preserves amount as cached")
service.apply(snap([], 2))
check(ProviderRegistry.provider(withID: "demo-agent") == nil, "removed feeds disappear after a full refresh")
for weekly in [10.0, 83.0] {
    let windows = [window("5 小时", 96), window("本周", weekly), window("本月", 90)]
    for metrics in [windows, Array(windows.reversed())] {
        let go = provider("opencode", metrics)
        check(go.primaryMetric?.label == "本周" && go.displayPrimaryValue == "\(Int(weekly))%" && snap([go]).menuBarItem(for: "opencode")?.value == "\(Int(weekly))", "OpenCode weekly \(weekly) order \(metrics.first?["label"] ?? "")")
    }
}
let periodLedger = HistoryStore(configURL: URL(fileURLWithPath:fixture).deletingLastPathComponent().appendingPathComponent("period-probe/config.json"))
try! FileManager.default.createDirectory(at: URL(fileURLWithPath:fixture).deletingLastPathComponent().appendingPathComponent("period-probe"), withIntermediateDirectories:true)
for (i, pair) in [(100.0,100.0),(60.0,90.0),(100.0,80.0)].enumerated() {
    let sample = provider("opencode",[window("5 小时",pair.0),window("本周",pair.1)])
    periodLedger.record(snapshot:snap([sample],Double(i)),now:start.addingTimeInterval(Double(i)))
}
let ledger = periodLedger.latest(provider:"opencode")
check(ledger?.dailyTotals?["周期：5 小时"] == 40 && ledger?.dailyTotals?["周期：本周"] == 20 && ledger?.activity == 2, "independent period denominators through reset")
check(NotificationService.quotaAlert(for:provider("opencode",[credit("$0","USD")]),percentLimit:20) != nil, "Zen exhaustion without configured credit line")
let secondaryAlert = provider("opencode", [window("5 小时",90),window("本周",10),window("本月",80)])
check(NotificationService.quotaAlert(for:secondaryAlert,percentLimit:20)?.1.contains("本周剩 10%") == true, "notification names limiting window")
let heatLedger = periodLedger
for (i, numbers) in [(1000.0, 10.0), (900.0, 8.0), (1000.0, 12.0)].enumerated() {
    let pts = provider("workbuddy", [credit(String(numbers.0))])
    let cny = provider("deepseek", [credit(String(numbers.1), "CNY")], ["balance": numbers.1])
    heatLedger.record(snapshot: snap([pts,cny], Double(i)), now: start.addingTimeInterval(Double(i)))
}
let heatRecords = ["opencode","workbuddy","deepseek"].compactMap { heatLedger.latest(provider:$0) }
var boundaryFirst = UsageHistoryEntry(date:"2026-01-01",provider:"a")
boundaryFirst.dailyTotals = ["周期：本周": 9.999999999999998]
check(UsageHistoryEntry.averageConsumption([boundaryFirst]) == 10 && HistoryWindowController.percentText(9.99) == "9.9%", "ten percent boundary resists floating-point noise and rounding across levels")
check(heatRecords.compactMap(\.consumptionPercent) == [20,10,20], "one weekly denominator and opening balances survive top-ups")
check(abs((UsageHistoryEntry.averageConsumption(heatRecords) ?? -1) - 50.0/3) < 0.0001, "three providers contribute equal weight")
let resetTime = start.addingTimeInterval(4).timeIntervalSince1970 * 1000
for (offset, used, reset) in [(3.0,30.0,resetTime),(5.0,12.0,resetTime + 86400000)] {
    var cycle = window("本周",100-used)
    cycle["resetAt"] = reset
    heatLedger.record(snapshot: snap([provider("codex",[cycle])],offset), now: start.addingTimeInterval(offset))
}
check(heatLedger.latest(provider:"codex")?.consumptionPercent == 12, "post-reset use starts with the new cycle even below previous usage")
var missingBase = UsageHistoryEntry(date:"2026-01-01",provider:"deepseek")
missingBase.dailyTotals = ["CNY":2]
missingBase.balanceUnit = "CNY"
check(missingBase.consumptionPercent == nil && UsageHistoryEntry.averageConsumption(heatRecords + [missingBase]) == UsageHistoryEntry.averageConsumption(heatRecords), "missing opening amount is excluded without diluting the mean")
missingBase.openingBalances = ["fixture":0]
check(missingBase.consumptionPercent == nil,"a zero opening amount has no defined percentage")
for (id, steps) in [("sparse",1),("frequent",75)] {
    for i in 0...steps {
        let remaining = 100.0 - Double(i) * 30.0 / Double(steps)
        let sample = provider(id,[window("每日",remaining),window("本周",99)])
        heatLedger.record(snapshot:snap([sample], Double(i)), preferredWindows:[id:"每日"], now:start.addingTimeInterval(Double(i)))
    }
}
check(heatLedger.latest(provider:"frequent")?.consumptionPercent == 30 && heatLedger.latest(provider:"sparse")?.consumptionPercent == 30, "75 small changes and one large change give the same daily heat using the chosen period")
var knownZero = boundaryFirst
knownZero.dailyTotals = ["周期：本周":0]
check(UsageHistoryEntry.averageConsumption([knownZero, missingBase]) == 0 && UsageLevel.forDay([knownZero, missingBase]) == .spent, "only the comparable zero enters the mean and confirmed spending remains visible")
let zen = provider("opencode", [credit("$0.50", "USD")])
let trae = provider("trae", [window("快速",55), window("慢速",45), window("基础",40), credit("12")])
let zero = provider("deepseek", [credit("¥0","CNY")], ["balance": 0])
check(zen.category == "现金余额" && trae.displayPrimaryValue == "12" && trae.riskMetric?.kind == "credit", "Zen / mixed Trae")
let debt = provider("deepseek", [credit("¥-12.00","CNY")])
check(QuotaStyle.remainingNumber(debt) == -12 && snap([debt]).menuBarItem(for: debt.id)?.value.contains("-12") == true, "signed debt")
for list in [[codex, trae, zero], [zero, trae, codex]] {
    check(snap(list).worstProviderID() == "deepseek", "exhaustion wins")
}
check(snap([zero, provider("opencode",[window("本周",0)])]).mostUrgent.count == 2, "equal exhaustion")
func cash(_ id: String, _ balance: Double) -> ProviderStatus {
    provider("deepseek",[credit("$\(balance)","USD")],["localAccountID":id,"balance":balance])
}
service.config.set("providers.deepseek.activeAccount","A")
service.apply(snap([cash("A",100),codex]))
service.config.set("providers.deepseek.activeAccount","B")
service.apply(snap([cash("B",1)],1), only:["deepseek"])
check(UsageTracker.shared.todaySpent(for:"deepseek") == 0, "A100 to B1 no false spending")
service.apply(snap([cash("B",0.5)],2), only:["deepseek"])
check(UsageTracker.shared.todaySpent(for:"deepseek") == 0.5, "same account delta")
let fail = provider("deepseek",[],["status":"error","error":"network is unreachable","localAccountID":"B"])
service.apply(snap([fail],3), only:["deepseek"])
check(service.snapshot?.provider(withID:"deepseek")?.cached == true && service.snapshot?.provider(withID:"deepseek")?.sampledAt == snap([],2).updatedAt && service.snapshot?.worstProviderID() == "codex", "partial failure excludes stale balance")
let point = provider("workbuddy",[credit("700")],["consumed":300])
service.apply(snap([point],4))
service.apply(snap([point],5))
let entry = HistoryStore.shared.latest(provider:"workbuddy")
check(entry?.activity == 0 && entry?.dailyDelta == 0, "unchanged lifetime counter")
let legacy = UsageHistoryEntry(date:"2026-11-01", provider:"workbuddy", usedPercent:88, consumed:900)
check(!legacy.hasObservation && legacy.activity == 0, "legacy cumulative values are unknown")
check(HistoryStore.shared.latest(provider:"deepseek")?.deltaUnit == "USD", "history currency")
let small = MenuBarIcon.make(provider:"codex", value:"83", remaining:83, scale:1.43 * 1.2)
let large = MenuBarIcon.make(provider:"codex", value:"83", remaining:83, scale:1.43 * 1.5)
check(small.size.width < large.size.width, "relative scale 1.20 and 1.50")

for (amount, unit, expected) in [(2.0, "周期：本周", "本周 2%"), (0.5, "周期：本日", "本日 0.5%"), (2, "积分", "2 积分")] {
    check(HistoryWindowController.displayConsumption(amount, unit: unit) == expected, "history display " + expected)
}
var mixedUsage = UsageHistoryEntry(date:"2026-11-18",provider:"codex")
mixedUsage.dailyTotals = ["周期：本周":3, "个百分点":6]
check(HistoryWindowController.consumptionLines(mixedUsage) == ["本周 3%"], "only the known three percent appears in history")
mixedUsage.dailyTotals = ["周期：本周":0, "周期：5 小时":0, "周期：本月":0]
check(HistoryWindowController.consumptionLines(mixedUsage) == ["0%"], "three unused windows produce one zero")
mixedUsage.dailyTotals = ["个百分点":6]
check(HistoryWindowController.consumptionLines(mixedUsage) == ["已使用"], "unscoped spend remains visible without inventing a percentage")
check(UsageLevel.forDay([mixedUsage, knownZero]) == .spent && UsageLevel.forDay([]) == .unrecorded && UsageLevel.forDay([knownZero]) == .none, "November 17: spending, no record and measured zero have distinct fills")
mixedUsage.dailyTotals = ["个百分点":6, "周期：本周":6]
mixedUsage.referenceWindow = "本周"
check(mixedUsage.consumptionPercent == 6 && HistoryWindowController.consumptionLines(mixedUsage) == ["本周 6%"], "November 18: weekly six survives an unscoped six without adding the two")
check(UsageHistoryEntry.averageConsumption([mixedUsage, knownZero, missingBase]) == 3 && UsageLevel.forDay([mixedUsage, knownZero, missingBase]) == .light, "six and a comparable zero average to three even with an unconvertible wallet")
var oldTagged = mixedUsage
oldTagged.dailyTotals = nil
oldTagged.dailyDelta = 6
oldTagged.deltaUnit = "周期：本周"
check(oldTagged.consumptionPercent == 6, "stored daily delta with a named period matches the detail ledger")
oldTagged.deltaUnit = "个百分点"
check(oldTagged.consumptionPercent == nil, "a reference window never relabels an unscoped delta")
for (amount, expected) in [(0.01,UsageLevel.light),(9.999,.light),(10,.medium),(29.99,.medium),(30,.dark)] {
    var entry = knownZero
    entry.dailyTotals = ["周期：本周":amount]
    check(UsageLevel.forDay([entry]) == expected,"calendar boundary " + String(amount))
}
mixedUsage.dailyTotals = ["周期：本周":0, "周期：5 小时":5]
mixedUsage.referenceWindow = "本周"
check(UsageLevel.forDay([mixedUsage]) == .spent, "activity outside a zero reference window does not paint an unused day")
let menuSample = MenuBarIcon.make(provider:"codex", value:"78", remaining:78)
let walletSample = MenuBarIcon.make(provider:"deepseek", value:"¥8", remaining:nil)
check(menuSample.foreground.isTemplate && walletSample.foreground.isTemplate, "logo, ring digits and plain balance use native status item tint")
check(menuSample.progress != nil && menuSample.progress?.isTemplate == false && walletSample.progress == nil, "only a quota arc is separately colored")
let november = FlexibleDateParser.date(from: "2026-11-17")!
let dates = Set((0..<18).map { HistoryStore.dayKey(Calendar.current.date(byAdding: .day, value: -$0, to: november)!) })
check(dates.filter { $0.hasPrefix("2026-11") }.count == 17 &&
      HistoryWindowController.currentStreak(activeDates: dates, now: november) == 18, "October 31 through November 17")
let _ = NSApplication.shared
func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
func labels(_ root: NSView) -> [String] { views(root).compactMap { ($0 as? NSTextField)?.stringValue } }
let settings = SettingsWindowController(service:service, checkin:CheckinService(service:service), onSaved:{}, onOpenSetup:{ _ in }, onAppearanceChanged:{}, onCheckin:{})
settings.selectPageForDebug("alerts")
let settingsRoot = settings.window!.contentView!
let descendants = views(settingsRoot)
let threshold = descendants.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "DeepSeek CNY阈值" }!
for (input, expected) in [("abc",5.0), ("235000",5), ("",5), ("-1",5), ("0.5",0.5), ("0",0)] {
    threshold.stringValue = input
    _ = threshold.sendAction(threshold.action, to:threshold.target)
    check(service.config.double("style.thresholds.deepseek",default:5) == expected && Double(threshold.stringValue) == expected, "threshold '\(input)'")
}
let thresholdWidths = descendants.compactMap { $0 as? QuotaTextField }.filter { $0.accessibilityLabel()?.hasSuffix("阈值") == true }.map { $0.constraints.first { $0.firstAttribute == .width }?.constant ?? 0 }
check(thresholdWidths.count == 3 && Set(thresholdWidths) == [88], "88 pt aligned native fields")
for mode in [NSAppearance.Name.aqua, .darkAqua] {
    let previous = NSApp.appearance
    NSApp.appearance = NSAppearance(named: mode)
    let expected = mode == .aqua ? "#0B6B5E" : "#FFFFFF"
    let logos = ProviderRegistry.ids.compactMap { id -> String? in
        let mark = ProviderMarkView(provider: id, size: 24)
        guard let image = mark.subviews.first as? NSImageView, image.image != nil,
              let ink = image.contentTintColor else { return nil }
        return QuotaStyle.hex(ink.resolvedForAppearance())
    }
    check(logos.count == 6 && Set(logos) == [expected], "six theSVG marks share theme ink in " + mode.rawValue)
    NSApp.appearance = previous
}
var brandMasks = Set<Data>()
for descriptor in ProviderRegistry.builtins {
    let icon = ProviderLogo.image(for: descriptor.id, size: 24, color: .black)
    guard let tiff = icon?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
        check(false, descriptor.id + " SVG rasterizes"); continue
    }
    let mask = Data((0..<bitmap.pixelsHigh).flatMap { y in
        (0..<bitmap.pixelsWide).map { x in UInt8((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 ? 1 : 0) }
    })
    if descriptor.id == "codex" {
        func filled(_ x: Int, _ y: Int) -> Bool {
            mask[(bitmap.pixelsHigh * y / 24) * bitmap.pixelsWide + bitmap.pixelsWide * x / 24] == 1
        }
        check(filled(12, 2) && filled(12, 21) && filled(3, 12) && filled(21, 12)
            && !filled(15, 15), "Codex silhouette surrounds its transparent terminal prompt")
    }
    let fraction = Double(mask.filter { $0 == 1 }.count) / Double(mask.count)
    check(fraction > 0.03 && fraction < 0.85 && brandMasks.insert(mask).inserted,
          descriptor.shortName + " has a distinct transparent SVG silhouette")
}
do {
    let directory = service.config.url.deletingLastPathComponent().appendingPathComponent("agents")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("logo-test.svg")
    try Data(contentsOf: URL(fileURLWithPath: "Resources/TheSVG/doubao.svg")).write(to: url)
    check(ProviderLogo.image(for: "logo-test", size: 24, color: .white) != nil, "external agent accepts an original theSVG asset")
    try Data("<svg/>".utf8).write(to: url)
    check(ProviderLogo.image(for: "logo-test", size: 24, color: .white) == nil, "external agent rejects an unlisted asset")
    try FileManager.default.removeItem(at: url)
} catch { check(false, "external SVG fixture setup") }
func luminance(_ color: NSColor, _ appearance: NSAppearance) -> Double {
    let rgb = color.resolvedForAppearance(appearance).usingColorSpace(.sRGB)!
    let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
        $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
}
let navigation = ThemedSurfaceView()
navigation.isNavigationSurface = true
navigation.wantsLayer = true
for design in DesignTheme.allCases {
    Theme.design = design
    for mode in [NSAppearance.Name.aqua, .darkAqua] {
        let a = NSAppearance(named: mode)!
        let pairs = [Theme.text, Theme.secondary, Theme.tertiary, Theme.accent].flatMap { ink in
            [Theme.background, Theme.surface, Theme.sidebar].map { (ink, $0) }
        } + [(Theme.text, Theme.heatMedium), (Theme.mint, Theme.forest)]
        check(pairs.allSatisfy { ink, fill in
            let x = luminance(ink, a), y = luminance(fill, a)
            return (max(x, y) + 0.05) / (min(x, y) + 0.05) >= 4.5
        }, "text contrast at least 4.5:1 for " + design.title + " " + mode.rawValue)
    }
    for (reduced, contrast) in [(false, false), (true, false), (false, true), (false, false)] {
        navigation.updateMaterial(reduceTransparency: reduced, increaseContrast: contrast)
        let expected = design == .glass && !reduced && !contrast
        check(navigation.subviews.count == (expected ? 1 : 0), "material follows theme and display options")
    }
}
Theme.design = .original
let legacyStyle = ConfigStore()
legacyStyle.set("style.healthyColor", "#14B8A6")
legacyStyle.set("style.warningColor", "#F59E0B")
legacyStyle.set("style.dangerColor", "#DC2626")
QuotaStyle.apply(legacyStyle)
check(QuotaStyle.hex(QuotaStyle.healthyColor.resolvedForAppearance(NSAppearance(named: .aqua))) == "#0B6B5E" &&
      QuotaStyle.hex(QuotaStyle.warningColor.resolvedForAppearance(NSAppearance(named: .darkAqua))) == "#F5B544",
      "legacy defaults follow semantic colors without rewriting stored settings")
legacyStyle.set("style.warningColor", "#994400")
QuotaStyle.apply(legacyStyle)
check(QuotaStyle.hex(QuotaStyle.warningColor) == "#994400", "explicit user warning tint is retained")
QuotaStyle.apply(service.config)
let switches = descendants.compactMap { $0 as? AccentSwitch }
check(!switches.isEmpty && descendants.contains { $0 is NSSlider } && descendants.contains { $0 is NSPopUpButton }, "native switch / slider / popup")
final class ActionProbe: NSObject { var count = 0; @objc func change() { count += 1 } }
let probe = ActionProbe()
let toggle = AccentSwitch()
toggle.target = probe
toggle.action = #selector(ActionProbe.change)
toggle.isOn = false; toggle.isOn = true
check(probe.count == 0, "hydration sends no action")
let switchWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
toggle.setAccessibilityLabel("测试开关")
switchWindow.contentView = toggle
switchWindow.orderFront(nil)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
if let control = views(toggle).compactMap({ $0 as? NSSwitch }).first {
    _ = control.accessibilityPerformPress()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    check(!toggle.isOn && probe.count == 1, "pressing the native switch changes state and sends exactly one action")
    _ = control.accessibilityPerformPress()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    check(toggle.isOn && probe.count == 2, "native switch reverses with one additional action")
} else { check(false, "tinted switch hosts a native switch") }
switchWindow.orderOut(nil)
let setup = SetupWindowController(provider:"opencode",service:service,onSaved:{})
let setupRoot = setup.window!.contentView!
if let segments = views(setupRoot).compactMap({ $0 as? NSSegmentedControl }).first {
    for index in [1, 0] {
        segments.selectedSegment = index; _ = segments.sendAction(segments.action,to:segments.target)
        let buttons = views(setupRoot).compactMap { $0 as? NSButton }.map(\.title)
        check(buttons.contains(index == 1 ? "登录并自动获取" : "打开 opencode.ai"), "OpenCode mode \(index)")
    }
} else { check(false, "OpenCode mode control") }
let proxy = descendants.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "系统代理" }
check(proxy?.usesSingleLineMode == true, "single-line proxy")
service.config.set("hiddenProviders", ["trae"]); try! service.config.save()
let history = HistoryWindowController()
let historyRoot = history.window!.contentView!
historyRoot.layoutSubtreeIfNeeded()
let weekdayStrip = views(historyRoot).first { $0.identifier?.rawValue == "history-weekdays" } as! NSStackView
let firstDate = views(historyRoot).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue.hasSuffix("-01") == true }!
let historyDateFormat = DateFormatter()
historyDateFormat.locale = Locale(identifier:"en_US_POSIX")
historyDateFormat.dateFormat = "yyyy-MM-dd"
let firstWeekday = Calendar.current.component(.weekday, from:historyDateFormat.date(from:firstDate.identifier!.rawValue)!)
let weekday = weekdayStrip.arrangedSubviews[(firstWeekday + 5) % 7]
check(firstDate.bounds.width >= 40 && abs(firstDate.convert(firstDate.bounds,to:historyRoot).midX - weekday.convert(weekday.bounds,to:historyRoot).midX) < 1,"calendar dates have usable width and align with weekdays")
let historyMenu = historyRoot.menu!
check(!views(historyRoot).contains { $0 is NSPopUpButton } && historyMenu.item(withTitle:"Trae") == nil && historyMenu.item(withTitle:"整体历史")?.state == .on, "history defaults to overall without a filter button or hidden services")
if let item = historyMenu.item(withTitle:"Codex") {
    NSApp.sendAction(item.action!,to:item.target,from:item)
    check(labels(historyRoot).contains("Codex 用量历史"), "history context menu switches service and shows scope")
}
if let item = historyMenu.item(withTitle:"整体历史") {
    NSApp.sendAction(item.action!,to:item.target,from:item)
    check(labels(historyRoot).contains("用量历史"), "history context menu restores overall")
}
check(views(historyRoot).compactMap { $0 as? NSButton }.contains { $0.toolTip?.contains("当天没有用量记录") == true && $0.action != nil }, "calendar day opens accessible detail")

let todayKey = HistoryStore.dayKey(Date())
service.config.set("checkin.resultDate", todayKey)
service.config.set("checkin.results", ["trae":"already","workbuddy":"failed"])
check(CheckinService.result(for:"trae",in:service.config) == "已签到" && CheckinService.result(for:"workbuddy",in:service.config) == "签到失败", "independent check-in results")
let accounts = AccountManagerWindowController(provider:"deepseek",service:service,onChanged:{})
accounts.beginFormForDebug()
let accountButtons = views(accounts.window!.contentView!).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.title)
check(accountButtons.contains("保存账户") && !accountButtons.contains("完成") && !accountButtons.contains("添加账户"), "account form has one submit path")
let fake = URL(fileURLWithPath:fixture).deletingLastPathComponent().appendingPathComponent("verify.js")
try! """
const fs = require('fs');
const candidate = JSON.parse(fs.readFileSync(0,'utf8'));
const ok = process.argv.includes('--verify-stdin') && candidate.apiKey === 'accepted-fixture';
process.stdout.write(JSON.stringify({updatedAt:new Date().toISOString(),providers:[{id:'deepseek',name:'DeepSeek',status:ok?'ok':'error',metrics:[],error:ok?null:'验证失败'}]}));
""".write(to:fake,atomically:true,encoding:.utf8)
setenv("AGENT_QUOTA_COLLECTOR", fake.path, 1)
service.config.set("providers.deepseek.apiKey","previous-fixture")
try! service.config.save()
let replacement = SetupWindowController(provider:"deepseek",service:service,onSaved:{})
let form = views(replacement.window!.contentView!)
let keyField = form.compactMap { $0 as? NSSecureTextField }.first!
let submit = form.compactMap { $0 as? NSButton }.first { $0.title == "保存并验证" }!
for (input, expected) in [("rejected-fixture","previous-fixture"), ("accepted-fixture","accepted-fixture")] {
    keyField.stringValue = input
    _ = submit.sendAction(submit.action,to:submit.target)
    let deadline = Date().addingTimeInterval(12)
    while !submit.isEnabled && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    let resultText = labels(replacement.window!.contentView!)
    let response = resultText.contains { $0.contains(input == "accepted-fixture" ? "已连接" : "✗") }
    check(submit.isEnabled && response && ConfigStore().string("providers.deepseek.apiKey") == expected, "candidate verification \(input == "accepted-fixture" ? "commit" : "rollback")")
}

for n in [0,1,50,99,100] {
    let bar = BarView(progress:CGFloat(n)/100, color:.systemGreen)
    check(bar.accessibilityValue() as? Int == n, "remaining bar \(n)%")
}
service.config.set("providers.deepseek.quotaRevision","")
service.config.set("providers.deepseek.activeAccount","A")
service.apply(snap([cash("A",90)],8))
check(UsageTracker.shared.todaySpent(for:"deepseek") == 0, "switch back rebases")
service.config.set("providers.deepseek.activeAccount","B")
service.apply(snap([cash("B",0.25)],9))
check(UsageTracker.shared.todaySpent(for:"deepseek") == 0.5, "switch back preserves observed spend")

let partial = provider("opencode",[window("本周",0.4)])
check(partial.displayPrimaryValue != "0%" && provider("opencode",[window("本周",99.6)]).displayPrimaryValue != "100%", "fractional quota preserves endpoints")
let oldDate = ISO8601DateFormatter.flexible.string(from:Date().addingTimeInterval(-86400))
let stale = provider("codex",[window("本周",83)],["sampledAt":oldDate,"cached":true])
check(NotificationService.stalenessMessage(snapshot:QuotaSnapshot(schema:1,updatedAt:ISO8601DateFormatter.flexible.string(from:Date()),sampledAt:nil,providers:[stale]), staleHours:12) != nil,"failed refresh cannot renew old sample")
func mixed(_ remaining:Double) -> ProviderStatus {
    provider("trae",[window("快速",remaining),credit("12")],["consumed":88])
}
HistoryStore.shared.record(snapshot:snap([mixed(95)],30))
HistoryStore.shared.record(snapshot:snap([mixed(70)],31))
let mixedEntry = HistoryStore.shared.latest(provider:"trae")
check(mixedEntry?.dailyTotals?["周期：快速"] == 25 && mixedEntry?.activity == 1, "mixed counters record intervals once")
HistoryStore.shared.record(snapshot:snap([provider("opencode",[credit("$10","USD")])],32))
HistoryStore.shared.record(snapshot:snap([provider("opencode",[credit("$8","USD")])],33))
check(HistoryStore.shared.latest(provider:"opencode")?.dailyTotals?["USD"] == 2,"Zen credit records USD spend")
service.config.set("providers.deepseek.activeAccount","B")
service.apply(snap([cash("A",20)],35),only:["deepseek"])
check(service.snapshot?.provider(withID:"deepseek")?.localAccountID != "A","late account result rejected")
let accountStore = AccountStore(config:service.config)
do {
    _ = try accountStore.addAccount(for:"opencode", label:"Incomplete", credentials:["workspaceId":"fixture-id"])
    check(false,"workspace alone cannot activate")
} catch { check(true,"workspace alone cannot activate") }
service.config.set("providers.opencode.mode","zen")
_ = try! accountStore.addAccount(for:"opencode",label:"Go",credentials:["apiKey":"example-fixture"])
check(service.config.string("providers.opencode.mode") == "go","Go account restores Go mode")


check(!LaunchAgentInstaller.ownsBackgroundTasks, "fixture cannot own background tasks")
let staleFirst = snap([cash("A",10)],38)
let switchedBack: [String:Any] = ["deepseek":["activeAccount":"A","selectionRevision":"again"]]
check(staleFirst.currentAccounts(in:switchedBack).providers.isEmpty, "A to B to A rejects first selection")
check(staleFirst.currentAccounts(in:["deepseek":["activeAccount":"A","quotaRevision":"new"]]).providers.isEmpty, "credential replacement rejects previous result")
let both = provider("trae",[window("快速",60),credit("10")],["consumed":90])
HistoryStore.shared.record(snapshot:snap([both],40))
let combined = HistoryStore.shared.latest(provider:"trae")
check(combined?.activity == 2 && combined?.dailyTotals?["积分"] == 2 && combined?.dailyTotals?["周期：快速"] == 35,"two units in one interval count once")
HistoryStore.shared.record(snapshot:snap([zen],41))
HistoryStore.shared.record(snapshot:snap([provider("opencode",[credit("¥200","CNY")])],42))
check(HistoryStore.shared.latest(provider:"opencode")?.dailyTotals?["CNY"] == nil, "currency switch rebases")
let healthySet = snap([provider("codex",[window("本周",100)]),provider("opencode",[window("本周",100)])])
let emptySet = snap([provider("codex",[window("本周",0)]),provider("opencode",[window("本周",0)])])
check(healthySet.riskSummary.contains("未触发警戒") && emptySet.riskSummary == "2 家已耗尽", "summary distinguishes healthy and tied exhaustion")
let panel = QuotaPopoverViewController(service:service)
_ = panel.view
let weekly83 = window("本周", 83).merging(["detail": "周五重置"]) { _, new in new }
panel.update(snapshot:snap([provider("opencode", [window("5 小时", 96), weekly83])]),error:nil,isRefreshing:false)
func togglePanel(_ id: String) {
    let button = views(panel.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "toggle-" + id }
    button?.performClick(nil)
}
check(!labels(panel.view).contains("已用 17%"), "quota details start closed")
togglePanel("opencode")
let anchoredRow = views(panel.view).compactMap { $0 as? ProviderRowView }.first { $0.providerID == "opencode" }!
let anchoredLogo = views(anchoredRow).first { $0 is ProviderMarkView }!
togglePanel("opencode")
togglePanel("opencode")
check(views(panel.view).contains { $0 === anchoredLogo } && anchoredRow.toggleButton.accessibilityLabel() == "收起 OpenCode", "repeated disclosure keeps the same logo and live button")
panel.update(snapshot:nil,error:nil,isRefreshing:true)
check(labels(panel.view).contains("83%") && labels(panel.view).contains("正在刷新…"), "in-flight refresh preserves the last available quota")
let weeklyLabels = labels(panel.view)
check(weeklyLabels.filter { $0.contains("83%") }.count == 1 && !weeklyLabels.contains("已用 17%") && weeklyLabels.contains("周五重置"), "weekly remaining and reset appear once together")
check(views(panel.view).compactMap { $0 as? BarView }.contains { $0.accessibilityLabel() == "5 小时剩余额度" }, "each quota bar identifies its window")
let windows = snap([provider("opencode", [window("5 小时", 96), weekly83, window("每日", 91)])])
settings.updateProviderStatuses(windows)
let period = views(settingsRoot).compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == "OpenCode 主额度周期" }!
period.selectedSegment = (0..<period.segmentCount).first { period.label(forSegment: $0) == "每日" }!
_ = period.sendAction(period.action, to:period.target)
panel.update(snapshot:windows,error:nil,isRefreshing:false)
togglePanel("opencode")
check(labels(panel.view).contains("每日剩余") && labels(panel.view).contains("91%") && !labels(panel.view).contains("已用 17%") && ConfigStore().string("panelWindow.opencode") == "每日", "daily choice persists and drives compact row")
panel.update(snapshot:snap([provider("opencode",[weekly83])]),error:nil,isRefreshing:false)
check(labels(panel.view).contains("本周剩余") && labels(panel.view).contains("83%"), "missing preferred window falls back with the real window name")
let oneWindow = window("本周", 82).merging(["detail":"6 天后重置"]) { _,value in value }
panel.update(snapshot:snap([provider("codex",[oneWindow]), provider("opencode",[weekly83,window("5 小时",96)])]),error:nil,isRefreshing:false)
panel.expandForSnapshot("opencode")
panel.view.layoutSubtreeIfNeeded()
func fieldFrame(_ value: String) -> NSRect? {
    guard let item = views(panel.view).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == value }) else { return nil }
    return item.convert(item.bounds, to: panel.view)
}
for design in [DesignTheme.claude, .glass, .original] {
    Theme.design = design
    panel.refreshAppearance()
    panel.view.layoutSubtreeIfNeeded()
    let number = fieldFrame("83%")!, name = fieldFrame("OpenCode")!
    check(number.midX > name.midX, "primary value and name follow the theme layout: " + design.title)
    check(labels(panel.view).contains("周五重置") && labels(panel.view).contains("剩 96%"), "theme switch preserves reset and expanded windows")
}
do {
    let savedDesign = Theme.design, savedAppearance = NSApp.appearance
    defer { Theme.design = savedDesign; NSApp.appearance = savedAppearance }
    for design in [DesignTheme.original, .glass, .claude] {
        Theme.design = design
        for mode in [NSAppearance.Name.aqua, .darkAqua] {
            let look = NSAppearance(named: mode)!
            NSApp.appearance = look
            look.performAsCurrentDrawingAppearance {
                let cards = QuotaPopoverViewController(service: service)
                let cardWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
                cardWindow.contentView = cards.view
                cards.availableHeight = 1000
                cards.update(snapshot: snap([provider("opencode", [weekly83, window("5 小时", 96)]),
                    provider("codex", [oneWindow]), doubao, cash("A", 1),
                    provider("trae", [credit("3600")]), provider("workbuddy", [credit("3903")])]),
                    error: nil, isRefreshing: false)
                cardWindow.setContentSize(cards.preferredContentSize)
                func cardSizes() -> [NSSize] {
                    cards.view.layoutSubtreeIfNeeded()
                    return views(cards.view).compactMap { ($0 as? ProviderRowView)?.frame.size }
                }
                func alignedPrimaryValues() -> Bool {
                    cards.view.layoutSubtreeIfNeeded()
                    var rightEdges: [CGFloat] = []
                    var captionedTopInsets: [CGFloat] = []
                    for row in views(cards.view).compactMap({ $0 as? ProviderRowView }) {
                        guard let field = views(row).first(where: { $0.identifier?.rawValue == "primary-quota" }),
                              let column = views(row).compactMap({ $0 as? NSStackView }).first(where: { stack in
                                  stack.orientation == .vertical && stack.arrangedSubviews.first.map { field.isDescendant(of: $0) } == true && stack.alignment == .trailing
                              }) else { return false }
                        let frame = field.convert(field.bounds, to: row)
                        rightEdges.append(frame.maxX)
                        if column.arrangedSubviews.count == 1 {
                            guard abs(frame.midY - row.bounds.midY) <= 1 else { return false }
                        } else {
                            captionedTopInsets.append(row.bounds.maxY - frame.maxY)
                        }
                    }
                    return rightEdges.count == 6 && Set(rightEdges).count == 1 && Set(captionedTopInsets).count == 1
                }
                let sizes = cardSizes()
                check(alignedPrimaryValues(), "primary values share trailing and vertical positions " + design.title + mode.rawValue)
                check(sizes.count == 6 && sizes.allSatisfy { $0 == sizes.first }, "equal collapsed card frames " + design.title + mode.rawValue)
                cards.expandForSnapshot("opencode")
                check(cardSizes().filter { $0 == sizes.first }.count == 5, "only expanded card grows")
                views(cards.view).compactMap { $0 as? ProviderRowView }.first { $0.providerID == "opencode" }?.toggleButton.performClick(nil)
                check(cardSizes() == sizes, "collapse restores card frames")
                for id in ["doubao", "trae", "workbuddy"] {
                    let cached = provider(id, [credit("3020")], ["cached": true, "sampledAt": oldDate])
                    let row = ProviderRowView(provider: cached, todaySpent: nil, checkinDone: false, checkinStreak: 0, onConfigure: {}, onCheckin: {})
                    let fields = views(row).compactMap { $0 as? NSTextField }
                    let ink = fields.first { $0.stringValue == "3,020" }?.textColor
                    let dot = views(row).compactMap { $0 as? StatusDotView }.first
                    check(ink.map { QuotaStyle.hex($0) } == QuotaStyle.hex(Theme.text)
                        && !fields.contains { $0.stringValue.contains("缓存") }
                        && dot?.toolTip?.contains("缓存") == true,
                        "cached wallet row " + id + " " + design.title + " " + mode.rawValue)
                }
            }
        }
    }
}
let alignedValues = ["82%", "83%", "6 天后重置", "周五重置", "剩 96%"].compactMap(fieldFrame)
let rightEdges = alignedValues.map(\.maxX)
check(rightEdges.count == 5 && (rightEdges.max()! - rightEdges.min()!) < 1.1, "both primary quotas, both resets and expanded window share one trailing rail")
for expandedID in ["opencode", "codex"] {
    panel.update(snapshot:snap([provider("codex",[oneWindow,window("5 小时",62)]), provider("opencode",[weekly83,window("5 小时",96)])]),error:nil,isRefreshing:false)
    panel.expandForSnapshot(expandedID)
    panel.view.layoutSubtreeIfNeeded()
    let providerRows = views(panel.view).compactMap { $0 as? ProviderRowView }
    let aligned = providerRows.compactMap { row -> (CGFloat,CGFloat,CGFloat)? in
        let children = views(row)
        guard let logo = children.first(where: { $0 is ProviderMarkView }),
              let name = children.compactMap({ $0 as? NSTextField }).first(where: { ["Codex","OpenCode"].contains($0.stringValue) }),
              let button = children.first(where: { $0.identifier?.rawValue.hasPrefix("toggle-") == true }) else { return nil }
        let mark = logo.convert(logo.bounds,to:row), title = name.convert(name.bounds,to:row), action = button.convert(button.bounds,to:row)
        guard abs(mark.midY - title.midY) <= 1 && abs(action.midY - title.midY) <= 1 else { return nil }
        return (mark.minX,title.minX,action.maxX)
    }
    check(aligned.count == 2 && aligned[0].0 == aligned[1].0 && aligned[0].1 == aligned[1].1 && aligned[0].2 == aligned[1].2, "logos, names and disclosure buttons align when expanding " + expandedID)
}
let toolsInHeader = views(panel.view).compactMap { $0 as? HeaderIconButton }
check(toolsInHeader.filter { $0.accessibilityLabel() == "用量历史" }.count == 1, "history has a dedicated header action")
var unknownConsumption = UsageHistoryEntry(date:todayKey,provider:"codex")
check(!unknownConsumption.observedZero,"unknown history stays visible")
unknownConsumption.dailyTotals = ["个百分点":0]
check(unknownConsumption.observedZero,"observed zero is foldable")
unknownConsumption.dailyTotals = ["积分":0, "个百分点":2]
check(!unknownConsumption.observedZero,"mixed nonzero history stays visible")
let crowded = snap([provider("opencode",[window("5 小时",96),weekly83]),provider("codex",[weekly83]),provider("deepseek",[credit("0.50","CNY")]),provider("workbuddy",[credit("300")]),provider("trae",[credit("700")])])
panel.availableHeight = 270
panel.update(snapshot:crowded,error:nil,isRefreshing:false)
panel.expandForSnapshot("opencode")
panel.view.layoutSubtreeIfNeeded()
func displayedServices() -> Set<String> {
    let rows = views(panel.view).compactMap { $0 as? ProviderRowView }.filter { !$0.isHiddenOrHasHiddenAncestor }
    for row in rows {
        let frame = row.convert(row.bounds, to: panel.view)
        check(panel.view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "current service fits short viewport: " + row.providerID)
    }
    return Set(rows.map(\.providerID))
}
check(!views(panel.view).contains { $0 is NSScrollView } && panel.view.frame.height <= 270, "short screen has no quota scroll view")
let nextServices = views(panel.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "下一页服务" }!
let previousServices = views(panel.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "上一页服务" }!
for _ in 0..<5 where previousServices.isEnabled { previousServices.performClick(nil) }
panel.view.layoutSubtreeIfNeeded()
var reached = displayedServices()
for _ in 0..<5 where nextServices.isEnabled {
    nextServices.performClick(nil)
    panel.view.layoutSubtreeIfNeeded()
    reached.formUnion(displayedServices())
}
check(reached == Set(crowded.providers.map(\.id)), "every service reachable without scrolling at 270 pt")
panel.availableHeight = 235
let manyWindows = [weekly83, window("5 小时",96), window("每日",71), window("本月",88)]
panel.update(snapshot:snap([provider("opencode",manyWindows)]),error:nil,isRefreshing:false)
if views(panel.view).compactMap({ $0 as? NSButton }).contains(where: { $0.accessibilityLabel() == "展开 OpenCode" }) {
    panel.expandForSnapshot("opencode")
}
for _ in 0..<6 where previousServices.isEnabled && !previousServices.isHiddenOrHasHiddenAncestor { previousServices.performClick(nil) }
var detailValues = Set<String>()
for _ in 0..<6 {
    panel.view.layoutSubtreeIfNeeded()
    _ = displayedServices()
    for field in views(panel.view).compactMap({ $0 as? NSTextField }) where !field.isHiddenOrHasHiddenAncestor {
        detailValues.insert(field.stringValue)
    }
    guard !nextServices.isHiddenOrHasHiddenAncestor && nextServices.isEnabled else { break }
    nextServices.performClick(nil)
}
check(["96%", "71%", "83%", "88%"].allSatisfy { detailValues.contains($0) || detailValues.contains("剩 " + $0) }, "all expanded periods reachable at 235 pt")
panel.availableHeight = 720
let fourth = provider("trae",[window("一",70),window("二",50),window("三",30),window("第四窗口",0),credit("1200")])
panel.update(snapshot:snap([fourth]),error:nil,isRefreshing:false)
check(!views(panel.view).contains { $0.identifier?.rawValue == "toggle-trae" } && labels(panel.view).contains { $0.contains("第四窗口") },"limiting fourth window has row detail")
let marks = views(panel.view).compactMap { $0 as? ProviderMarkView }
check(marks.count == 1 && marks.allSatisfy { mark in
    let hasLogo = mark.subviews.contains { ($0 as? NSImageView)?.image != nil }
    return hasLogo && (mark.layer?.backgroundColor?.alpha ?? 0) == 0 && (mark.layer?.borderWidth ?? 0) == 0
}, "panel service marks display only the logo on a transparent surface")
check(labels(panel.view).contains("额度概览") && !labels(panel.view).contains("当前最紧张"), "low quota never replaces the overview title")
panel.update(snapshot:emptySet,error:nil,isRefreshing:false)
let tiedLabels = labels(panel.view)
check(tiedLabels.contains { $0.contains("已显示 2 项服务") } && !tiedLabels.contains("并列"), "overview counts displayed services without ranking tied accounts")
panel.update(snapshot:nil,error:nil,isRefreshing:true,isOffline:true)
check(views(panel.view).compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue == "网络未连接" }, "offline overview state remains visible without a snapshot")
panel.update(snapshot:snap([]),error:nil,isRefreshing:false)
var selectedServices = false
panel.onSelectServices = { selectedServices = true }
let choose = views(panel.view).compactMap { $0 as? NSButton }.first { $0.title == "选择显示的服务…" }
_ = choose?.sendAction(choose?.action,to:choose?.target)
check(selectedServices,"empty state opens service selection")

let cfg = service.config
cfg.set("refreshSeconds",120)
cfg.set("proxy","auto")
try! cfg.save()
let settings2 = SettingsWindowController(service:service,checkin:CheckinService(service:service),onSaved:{},onOpenSetup:{_ in},onAppearanceChanged:{},onCheckin:{})
let settingsViews = views(settings2.window!.contentView!)
let proxy2 = settingsViews.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "系统代理" }!
let interval = settingsViews.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "刷新频率" }!
let modePicker = settingsViews.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "代理模式" }!
func pickProxyMode(_ index: Int) {
    modePicker.selectItem(at: index)
    _ = modePicker.sendAction(modePicker.action, to: modePicker.target)
}
check(proxy2.isHidden, "system proxy hides the address editor")
pickProxyMode(2)
check(!proxy2.isHidden && ConfigStore().string("proxy") == "auto", "choosing custom waits for a valid address")
func endProxy(_ input:String) {
    proxy2.stringValue = input
    settings2.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:proxy2))
}
endProxy("bad proxy input")
check(ConfigStore().string("proxy") == "auto" && labels(settings2.window!.contentView!).contains("代理地址无效"),"invalid proxy preserves configuration and explains inline")
settings2.selectPageForDebug("alerts")
settings2.selectPageForDebug("general")
check(labels(settings2.window!.contentView!).contains("代理地址无效，已保留上次设置"), "returning to invalid proxy draft preserves its save feedback")
endProxy("http://127.0.0.1:7897")
check(ConfigStore().refreshSeconds == 120 && interval.titleOfSelectedItem == "120 秒","proxy edit preserves supported custom interval")
pickProxyMode(1)
check(proxy2.isHidden && ConfigStore().string("proxy") == "off", "off mode saves without typing a sentinel")
pickProxyMode(0)
check(ConfigStore().string("proxy") == "auto", "system proxy restores existing configuration format")
let tabs = settingsViews.compactMap { $0 as? SettingsTabButton }
check(tabs.map(\.keyEquivalent) == (1...6).map(String.init) && tabs.allSatisfy { $0.keyEquivalentModifierMask.contains(.command) }, "six settings pages have command-number shortcuts")
if let win = settings2.window, let serviceTab = tabs.first(where: { $0.title == "菜单栏" }),
   let jump = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                               timestamp: 0, windowNumber: win.windowNumber, context: nil,
                               characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18) {
    win.makeKeyAndOrderFront(nil)
    let handled = win.performKeyEquivalent(with: jump)
    check(handled && serviceTab.selected, "command-one opens the menu bar page through the window")
    tabs.first(where: { $0.title == "运行与签到" })?.performClick(nil)
    check(tabs.first(where: { $0.title == "运行与签到" })?.selected == true, "clicking General restores its page")
    win.orderOut(nil)
}
let appearance = settingsViews.compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == "明暗外观" }!
let themes = settingsViews.compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == "界面主题" }!
if let window = settings2.window, let canvas = window.contentView {
    check(!window.styleMask.contains(.fullSizeContentView) &&
          [.closeButton, .miniaturizeButton, .zoomButton].allSatisfy { window.standardWindowButton($0)?.isEnabled == true },
          "settings reserves a native title bar with three working window controls")
    let savedDesign = Theme.design
    var stableBacking = true
    for design in [DesignTheme.glass, .claude, .original, .glass] {
        Theme.design = design
        Theme.refreshViews(canvas)
        stableBacking = stableBacking && !window.isOpaque && window.backgroundColor == .clear
    }
    Theme.design = savedDesign
    Theme.refreshViews(canvas)
    check(stableBacking, "hot switches preserve the window backing that hosts native controls")
    check(themes.focusRingType == .none && appearance.focusRingType == .none &&
          themes.acceptsFirstResponder && appearance.acceptsFirstResponder,
          "appearance pickers keep keyboard focus without a second native ring")
}
for (index, mode) in ["system", "light", "dark"].enumerated().reversed() {
    appearance.selectedSegment = index
    _ = appearance.sendAction(appearance.action, to: appearance.target)
    check(appearance.trackingMode == .selectOne && ConfigStore().string("appearance") == mode, "native appearance selection saves " + mode)
    for (choice, theme) in DesignTheme.allCases.enumerated() {
        themes.selectedSegment = choice
        _ = themes.sendAction(themes.action, to: themes.target)
        let restored = ConfigStore()
        check(restored.string("designTheme") == theme.rawValue && restored.string("appearance") == mode,
              "design and brightness restore independently: " + theme.title + "/" + mode)
    }
}
check(DesignTheme(setting: "") == .original && DesignTheme(setting: "future-theme") == .original, "missing and unsupported themes use the original design")
let permissionLabel = settingsViews.compactMap { $0 as? ThemedLabel }.first { $0.accessibilityLabel() == "通知权限状态" }!
settings2.selectPageForDebug("alerts")
settings2.presentNotificationPermission(.authorized, presentation: "允许横幅")
let permissionIcon = settingsViews.compactMap { $0 as? StatusMarkView }.first { $0.state == .authorized }!
for design in DesignTheme.allCases {
    Theme.design = design
    for mode in [NSAppearance.Name.aqua, .darkAqua] {
        NSApp.appearance = NSAppearance(named: mode)
        settings2.reloadForAppearance()
        let expected = QuotaStyle.hex(Theme.accent.resolvedForAppearance())
        check(permissionLabel.stringValue == "允许横幅" && QuotaStyle.hex(permissionLabel.textColor!) == expected &&
              QuotaStyle.hex(permissionIcon.ink.resolvedForAppearance()) == expected, "permission glyph and text share accent in " + design.title + "/" + mode.rawValue)
    }
}
let colored = settingsViews.compactMap { $0 as? QuotaTextField }
let warn = colored.first { $0.accessibilityLabel() == "警戒阈值（%）" }!
let danger = colored.first { $0.accessibilityLabel() == "危险阈值（%）" }!
settings2.selectPageForDebug("alerts")
check(warn.isHiddenOrHasHiddenAncestor, "advanced thresholds start hidden")
let initialFrame = settings2.window!.frame
var stablePages = true
var unneededScroll = false
for _ in 0..<10 {
    for tab in tabs {
        tab.performClick(nil)
        settings2.window!.contentView!.layoutSubtreeIfNeeded()
        unneededScroll = unneededScroll || views(settings2.window!.contentView!).contains { $0 is NSScrollView }
        stablePages = stablePages && settings2.window!.frame == initialFrame && tab.selected
    }
}
check(!unneededScroll, "all six standard settings pages fit the visible height")
let viewport = settingsViews.first { $0.identifier?.rawValue == "settings-content" }!
for design in DesignTheme.allCases {
    Theme.design = design
    settings2.reloadForAppearance()
    for tab in tabs {
        tab.performClick(nil)
        settings2.window!.contentView!.layoutSubtreeIfNeeded()
        let page = views(viewport).first { $0.identifier?.rawValue == "settings-page" && !$0.isHiddenOrHasHiddenAncestor }!
        check(viewport.bounds.insetBy(dx: -1, dy: -1).contains(page.convert(page.bounds, to: viewport)),
              "all rows above footer in " + design.title + "/" + tab.title)
    }
}
check(stablePages, "60 settings transitions preserve window frame and selection")
tabs.first { $0.title == "额度颜色" }!.performClick(nil)
check(!warn.isHiddenOrHasHiddenAncestor, "advanced thresholds remain editable")
func submitNumber(_ field: NSTextField, _ input: String) {
    field.stringValue = input
    _ = field.sendAction(field.action, to: field.target)
}
submitNumber(warn, "54.945605")
check(warn.stringValue == "54.9" && ConfigStore().double("style.warningPercent", default: 0) == 54.9, "legacy precision agrees with persisted warning")
let warningScale = settingsViews.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "警戒阈值滑块" }!
warningScale.doubleValue = 63.368674
_ = warningScale.sendAction(warningScale.action, to: warningScale.target)
check(warn.stringValue == "63.4" && warningScale.doubleValue == ConfigStore().double("style.warningPercent", default: 0), "slider, field and persisted threshold agree")
let wells = settingsViews.compactMap { $0 as? NSColorWell }.sorted { $0.tag < $1.tag }
let resetColors = settingsViews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "恢复主题额度颜色" }!
func switchPalette(_ design: DesignTheme) {
    Theme.design = design
    QuotaStyle.apply(service.config)
    settings2.reloadForAppearance()
}
service.config.set("style.healthyColor", "#14B8A6")
var palettes = Set<String>()
for design in DesignTheme.allCases {
    switchPalette(design)
    palettes.insert(QuotaStyle.hex(wells[0].color))
}
check(palettes.count == 3 && !resetColors.isEnabled, "saved historical default follows all three designs")
wells[0].color = Theme.hex(0x14B8A6)
_ = wells[0].sendAction(wells[0].action, to: wells[0].target)
switchPalette(.glass)
check(QuotaStyle.hex(wells[0].color) == "#14B8A6" && ConfigStore().bool("style.customColors.healthyColor", default: false), "explicit historical default stays custom across designs")
resetColors.performClick(nil)
check(!resetColors.isEnabled && QuotaStyle.hex(wells[0].color) == QuotaStyle.hex(Theme.quotaHealthy.resolvedForAppearance()), "reset restores theme role immediately")
for input in ["44.5", "46", "47"] {
    submitNumber(warn, input)
    check(Double(warn.stringValue) == Double(input) && ConfigStore().double("style.warningPercent", default:0) == Double(input), "native percent field commits " + input)
}
submitNumber(warn, "1")
check(Double(warn.stringValue) == 47, "out of range percent restores saved value")
submitNumber(warn, "2")
check(QuotaStyle.warningPercent == 2 && Double(danger.stringValue) == 1, "warning and danger boundaries stay ordered")
let configureNames = settingsViews.compactMap { $0 as? NSButton }.filter { $0.title == "配置…" }.compactMap { $0.accessibilityLabel() }
check(settingsViews.compactMap { $0 as? NSButton }.filter { $0.title == "配置…" }.allSatisfy { $0.isBordered && $0.fittingSize.height >= 24 }, "service configuration actions have a visible target at least 24 pt high")
check(Set(configureNames).count == 5, "five configuration buttons identify their service")
let dateButtons = views(historyRoot).compactMap { $0 as? NSButton }.filter { $0.isEnabled && $0.identifier?.rawValue.hasPrefix(String(todayKey.prefix(7))) == true }
if dateButtons.count > 1 {
    for day in dateButtons.suffix(2) { _ = day.sendAction(day.action,to:day.target) }
    let detail = views(historyRoot).first { $0.identifier?.rawValue == "selected-history-date" } as? NSTextField
    let parts = dateButtons.last!.identifier!.rawValue.split(separator: "-").compactMap { Int($0) }
    check(history.window?.attachedSheet == nil && detail?.stringValue == "\(parts[1])月\(parts[2])日","consecutive days have in-window details")
}
history.refreshForExternalSnapshot()
let todayCell = views(historyRoot).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == todayKey }
check(todayCell?.toolTip?.contains(" · ") == true,"day explains observed activity")

let files = URL(fileURLWithPath:fixture).deletingLastPathComponent().appendingPathComponent("import-fixture")
let target = files.appendingPathComponent("input.json")
let backup = target.appendingPathExtension("agent-quota.bak")
let previousBytes = Data("previous fixture".utf8)
let validBytes = Data("validated fixture".utf8)
try! SetupWindowController.installVerifiedLogin(previousBytes,at:target)
try! FileManager.default.createDirectory(at:backup,withIntermediateDirectories:false)
do {
    try SetupWindowController.installVerifiedLogin(validBytes,at:target)
    check(false,"backup failure blocks import")
} catch { check((try? Data(contentsOf:target)) == previousBytes,"backup failure blocks import") }
try! FileManager.default.removeItem(at:backup)
try! SetupWindowController.installVerifiedLogin(validBytes,at:target)
let permissions = try! FileManager.default.attributesOfItem(atPath:target.path)[.posixPermissions] as? Int
check((try? Data(contentsOf:backup)) == previousBytes && (try? Data(contentsOf:target)) == validBytes && permissions == 0o600,"verified import preserves original and private file mode")

try! """
const fs = require('fs');
const id = process.argv.find(x => x.startsWith('--only=')).slice(7);
const c = JSON.parse(fs.readFileSync(0, 'utf8'));
const ok = id === 'opencode' ? ((c.mode === 'zen' && c.cookie === 'fixture-cookie' && !c.workspaceId) || c.apiKey === 'fixture-good') : c.apiKey === 'fixture-first';
setTimeout(() => console.log(JSON.stringify({updatedAt:new Date().toISOString(),providers:[{id,name:id,status:ok?'ok':'error',metrics:[]}]})),70);
""".write(to:fake,atomically:true,encoding:.utf8)
func waitFor(_ predicate: () -> Bool) {
    let end = Date().addingTimeInterval(8)
    while !predicate() && Date() < end { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
}
cfg.set("providers.opencode",["mode":"zen","cookie":"fixture-cookie","workspaceId":"old-workspace"])
try! cfg.save()
let zenSetup = SetupWindowController(provider:"opencode",service:service,onSaved:{})
let zViews = views(zenSetup.window!.contentView!)
let work = zViews.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel()?.contains("Workspace ID") == true }!
let verifyZen = zViews.compactMap { $0 as? NSButton }.first { $0.title == "保存并验证" }!
work.stringValue = ""
_ = verifyZen.sendAction(verifyZen.action,to:verifyZen.target)
waitFor { verifyZen.isEnabled }
check(ConfigStore().string("providers.opencode.workspaceId").isEmpty && labels(zenSetup.window!.contentView!).contains { $0.contains("✓ 已连接") },"blank workspace verifies and clears stored ID")
let initialKey = cfg.string("providers.deepseek.apiKey")
keyField.stringValue = "fixture-first"
_ = submit.sendAction(submit.action,to:submit.target)
keyField.stringValue = "fixture-second"
waitFor { submit.isEnabled }
check(cfg.string("providers.deepseek.apiKey") == initialKey && labels(replacement.window!.contentView!).contains { $0.contains("请重新验证") }, "changed draft cannot receive previous success")

cfg.set("providers.opencode",["mode":"go"])
try! cfg.save()
let accountForm = AccountManagerWindowController(provider:"opencode",service:service,onChanged:{})
accountForm.beginFormForDebug()
let aRoot = accountForm.window!.contentView!
let fields = views(aRoot).compactMap { $0 as? NSTextField }
func namedField(_ label:String) -> NSTextField { fields.first { $0.accessibilityLabel() == label }! }
let accountSubmit = views(aRoot).compactMap { $0 as? NSButton }.first { $0.title == "保存账户" }!
let emptyHelp = fields.first { $0.stringValue.contains("还没有账户") }
check(emptyHelp?.isHiddenOrHasHiddenAncestor == true,"open form hides obsolete empty state")
namedField("账户名称").stringValue = "Fixture"
let workspace = fields.first { $0.isEditable && $0.accessibilityLabel()?.contains("Workspace") == true }!
workspace.stringValue = "workspace-only"
_ = accountSubmit.sendAction(accountSubmit.action,to:accountSubmit.target)
check(cfg.string("providers.opencode.activeAccount").isEmpty && labels(aRoot).contains { $0.contains("请填写 Go") },"account form rejects auxiliary ID alone")
namedField("API Key").stringValue = "fixture-bad"
_ = accountSubmit.sendAction(accountSubmit.action,to:accountSubmit.target)
waitFor { labels(aRoot).contains { $0.contains("验证失败") } }
check(cfg.string("providers.opencode.activeAccount").isEmpty && labels(aRoot).contains { $0.contains("验证失败") }, "rejected candidate cannot activate")
namedField("API Key").stringValue = "fixture-good"
_ = accountSubmit.sendAction(accountSubmit.action,to:accountSubmit.target)
waitFor { !cfg.string("providers.opencode.activeAccount").isEmpty }
check(ConfigStore().string("providers.opencode.apiKey") == "fixture-good" && !cfg.string("providers.opencode.activeAccount").isEmpty,"verified account and mirror saved together")
let noteThreshold = cfg.double("notifications.percent",default:20)
let originalColors = cfg.dictionary("style") ?? [:]
submitNumber(warn, "60")
check(cfg.double("notifications.percent",default:20) == noteThreshold && (cfg.dictionary("style")?["healthyColor"] as? String) == originalColors["healthyColor"] as? String,"threshold change leaves unrelated colors and notifications alone")

let typed = provider("deepseek",[["label":"说明","kind":"text","value":"示例","headlineValue":"示例"],
                               ["label":"余额","kind":"credit","value":0.25,"currency":"USD","headlineValue":"$0.25"]])
check(QuotaStyle.remainingNumber(typed) == 0.25,"text and numeric metrics decode together")
do {
    try SetupWindowController.installVerifiedLogin(Data("another fixture".utf8), at:target) { throw POSIXError(.EACCES) }
    check(false,"failed import commit rolls back")
} catch { check((try? Data(contentsOf:backup)) == previousBytes && (try? Data(contentsOf:target)) == validBytes,"failed import commit rolls back") }

let recentStamp = ISO8601DateFormatter.flexible.string(from:Date())
let partlyStale = QuotaSnapshot(schema:1,updatedAt:recentStamp,sampledAt:recentStamp,providers:[stale,provider("deepseek",[credit("$5","USD")],["sampledAt":recentStamp])])
let staleNames = NotificationService.stalenessMessage(snapshot:partlyStale,staleHours:12)?.body ?? ""
check(staleNames.contains("codex") && !staleNames.contains("deepseek"), "stale notice identifies only stale provider")
let coverageDay = views(historyRoot).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == todayKey }
check(coverageDay != nil && coverageDay?.toolTip?.contains("未注明") == false && coverageDay?.accessibilityLabel()?.contains("比例不完整") == false,"aggregate day reports observation coverage explicitly")
let fractionalBar = BarView(progress:0.004,color:.systemRed)
check(fractionalBar.accessibilityValueDescription() == "<1%" && (fractionalBar.accessibilityValue() as? NSNumber)?.doubleValue == 0.4, "fractional accessibility value agrees with visible quota")
let board = NSPasteboard.withUniqueName()
board.clearContents()
board.setData(Data([1,2,3]), forType:.png)
keyField.stringValue = "fixture-kept"
replacement.pasteCredential(from:board)
check(keyField.stringValue == "fixture-kept" && labels(replacement.window!.contentView!).contains("剪贴板中没有可粘贴的文本"), "image clipboard preserves entry and explains failure")
board.clearContents()
replacement.pasteCredential(from:board)
check(keyField.stringValue == "fixture-kept", "empty clipboard preserves entry")
board.releaseGlobally()
let accountModeControl = views(aRoot).compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == "账户额度模式" }!
accountForm.beginFormForDebug()
for _ in 0..<30 {
    accountModeControl.selectedSegment = 1
    _ = accountModeControl.sendAction(accountModeControl.action,to:accountModeControl.target)
    precondition(namedField("API Key").isHiddenOrHasHiddenAncestor && !namedField("Console Cookie").isHiddenOrHasHiddenAncestor)
    accountModeControl.selectedSegment = 0
    _ = accountModeControl.sendAction(accountModeControl.action,to:accountModeControl.target)
}
check(!namedField("API Key").isHiddenOrHasHiddenAncestor && namedField("Console Cookie").isHiddenOrHasHiddenAncestor,"60 Go and Zen switches expose only relevant fields")
let editionForm = AccountManagerWindowController(provider:"trae",service:service,onChanged:{})
editionForm.beginFormForDebug()
let edition = views(editionForm.window!.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Trae 版本" }!
check(edition.itemArray.compactMap { $0.representedObject as? String } == ProviderRegistry.traeEditions.map { $0.0 }, "Trae account and setup use identical finite editions")
// Stress the real notification qualification and dedupe path, replacing only OS delivery.
var sent: [(String,String)] = []
var acknowledgements: [(Bool) -> Void] = []
let notices = NotificationService { title, body, reply in
    sent.append((title,body))
    acknowledgements.append(reply)
}
cfg.set("notifications.enabled",true)
cfg.set("notifications.staleHours",48)
cfg.set("notifications.percent",20)
try! cfg.save()
let tomorrow = ISO8601DateFormatter.flexible.string(from: Date().addingTimeInterval(86400))
func expiring(_ left: Double, _ account: String) -> ProviderStatus {
    provider("codex",[window("本周",left)],["localAccountID":account,"subscriptionUntil":tomorrow,"subscriptionWillRenew":false])
}
notices.check(snapshot:snap([expiring(83,"fixture-A")]),config:cfg)
for ack in acknowledgements { ack(true) }; acknowledgements.removeAll()
for _ in 0..<240 { notices.check(snapshot:snap([expiring(1,"fixture-A")]),config:cfg) }
check(sent.count == 2 && sent.last?.0.contains("额度偏低") == true, "expiry does not suppress low quota; 240 in-flight repeats coalesce")
for ack in acknowledgements { ack(true) }; acknowledgements.removeAll()
for _ in 0..<120 { notices.check(snapshot:snap([expiring(0,"fixture-B")]),config:cfg) }
for ack in acknowledgements { ack(true) }; acknowledgements.removeAll()
notices.check(snapshot:snap([expiring(1,"fixture-A")]),config:cfg)
check(sent.count == 3, "second account delivers once; switching back retains dedupe")
check(NotificationService.presentationText(alertsEnabled:true,style:.none).contains("未开启") && NotificationService.presentationText(alertsEnabled:true,style:.banner).contains("横幅") && NotificationService.presentationText(alertsEnabled:false,style:.banner).contains("未开启"),"OS alert setting and banner style are independent")
for (currency, value, alerts) in [("CNY", 2.0, true),("USD", 2.0, false),("USD",0.0,true)] {
    cfg.set("style.thresholds.deepseek",5.0)
    QuotaStyle.apply(cfg)
    let candidate = provider("deepseek",[credit(String(value),currency)],["balance":value])
    let notice = NotificationService.quotaAlert(for:candidate,percentLimit:20)
    check((notice != nil) == alerts && (notice?.1.contains(currency) ?? true),"threshold scope " + currency + " " + String(value))
}
var baselineOnly = UsageHistoryEntry(date:todayKey,provider:"opencode")
baselineOnly.cost = 0
baselineOnly.activeIntervals = 8
check(!baselineOnly.hasQuotaSpend, "refresh counts alone never create a spending day")
check(!baselineOnly.observedZero,"a free first sample has unknown quota consumption")
for offset in 3...242 {
    let phase = Double(offset % 2)
    let sample = provider("opencode",[window("5 小时", 100 - phase * 10),window("本周", 80 - Double(offset) / 10)])
    let sampleTime = start.addingTimeInterval(Double(offset))
    let batch = snap([sample],Double(offset))
    _ = periodLedger.record(snapshot:batch,now:sampleTime)
    _ = periodLedger.record(snapshot:batch,now:sampleTime)
}
let stressed = periodLedger.latest(provider:"opencode")
check(stressed?.activity == 242 && abs((stressed?.dailyTotals?["周期：5 小时"] ?? 0) - 1240) < 0.00001 && abs((stressed?.dailyTotals?["周期：本周"] ?? 0) - 44.2) < 0.00001,"480 history writes with resets and duplicates preserve each denominator")

settings2.selectPageForDebug("menubar")
let orderPicker = settingsViews.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "调整服务顺序" }!
let up = settingsViews.compactMap { $0 as? NSButton }.first { $0.title == "上移" }!
orderPicker.selectItem(at:2)
_ = orderPicker.sendAction(orderPicker.action,to:orderPicker.target)
let moved = orderPicker.selectedItem!.representedObject as! String
for _ in 0..<2 { _ = up.sendAction(up.action,to:up.target) }
check(ConfigStore().stringArray("providerOrder").first == moved && !up.isEnabled, "two keyboard-equivalent moves persist third service in first place")
let systemMode = settingsViews.compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == "菜单栏显示方式" }!
let fixtureURL = URL(fileURLWithPath:fixture)
let fixtureDir = fixtureURL.deletingLastPathComponent()
let originalPermissions = try! FileManager.default.attributesOfItem(atPath:fixtureDir.path)[.posixPermissions]!
let durableMode = systemMode.selectedSegment
try! FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:fixtureDir.path)
systemMode.selectedSegment = 1
_ = systemMode.sendAction(systemMode.action,to:systemMode.target)
let rolledBack = systemMode.selectedSegment
try! FileManager.default.setAttributes([.posixPermissions:originalPermissions],ofItemAtPath:fixtureDir.path)
check(rolledBack == durableMode && labels(settings2.window!.contentView!).contains { $0.contains("保存失败") },"failed write rolls back displayed mode and reports failure")
let minSize = history.window!.contentMinSize
history.window!.setContentSize(minSize)
history.window!.contentView!.layoutSubtreeIfNeeded()
check(history.window!.styleMask.contains(.resizable) && minSize.width < 840 && todayCell?.accessibilityLabel()?.contains("\\n") == false,"narrow resizable history with compact date accessibility names")
history.window!.makeKeyAndOrderFront(nil)
let countDays: () -> Int = {
    views(historyRoot).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix(String(todayKey.prefix(7)) + "-") == true }.count
}
let originalDayCount = countDays()
var intactGrid = true
var readableDetail = true
for i in 0..<30 {
    history.window!.setContentSize(i.isMultiple(of:2) ? minSize : NSSize(width:900,height:580))
    for title in ["Codex", "整体历史"] {
        guard let item = historyMenu.item(withTitle:title), let action = item.action else { intactGrid = false; continue }
        _ = NSApp.sendAction(action,to:item.target,from:item)
        historyRoot.layoutSubtreeIfNeeded()
        if let strip = views(historyRoot).first(where: { $0.identifier?.rawValue == "history-weekdays" }) as? NSStackView {
            for cell in views(historyRoot).compactMap({ $0 as? NSButton }) {
                guard let key = cell.identifier?.rawValue, let stamp = historyDateFormat.date(from:key) else { continue }
                let column = (Calendar.current.component(.weekday,from:stamp) + 5) % 7
                let header = strip.arrangedSubviews[column]
                intactGrid = intactGrid && abs(header.convert(header.bounds,to:historyRoot).midX - cell.convert(cell.bounds,to:historyRoot).midX) < 1
            }
        }
        let viewport = views(historyRoot).compactMap { $0 as? NSScrollView }.first
        readableDetail = readableDetail && (viewport?.contentSize.height ?? 0) >= 120
        intactGrid = intactGrid && countDays() == originalDayCount && originalDayCount >= 28
    }
}
history.window!.orderOut(nil)
check(readableDetail, "day detail keeps a usable viewport through service navigation and resizing")
check(intactGrid,"60 visible history transitions while resizing preserve every date cell")
check(labels(historyRoot).contains("轻轻路过") && labels(historyRoot).contains("卷王模式"),"history uses original rating vocabulary")
QuotaStyle.warningPercent = 45
QuotaStyle.dangerPercent = 20
let edgeCases: [(Double,QuotaSeverity)] = [(19.9,.critical),(20,.critical),(20.1,.tight),(45,.tight),(45.1,.healthy)]
check(edgeCases.allSatisfy { QuotaSeverity.from(remaining:$0.0) == $0.1 } && !views(panel.view).contains { $0.toolTip?.hasPrefix("颜色按剩余比例") == true }, "five threshold boundaries agree; timestamp has no conflicting legend")
let missingDay = views(historyRoot).compactMap { $0 as? NSButton }.first { $0.toolTip?.contains("当天没有用量记录") == true }
check(missingDay.map { labels($0).contains { Int($0) != nil } } == true, "unrated date contains only its day number")
let baseTextFields = views(settingsRoot).compactMap { $0 as? QuotaTextField }
check(baseTextFields.filter { $0.accessibilityLabel()?.contains("阈值") == true }.count == 6, "all six numeric thresholds share one native editing control")
// Exercise the disclosure through its native buttons in a disposable two-day history.
let yesterday = Calendar.current.date(byAdding:.day,value:-1,to:start)!
let priorKey = HistoryStore.dayKey(yesterday)
let zeroDays = [priorKey,todayKey].map { key -> UsageHistoryEntry in
    var entry = UsageHistoryEntry(date:key,provider:"codex")
    entry.dailyTotals = ["周期：本周":0]
    return entry
}
try! JSONEncoder().encode(zeroDays).write(to:HistoryStore.shared.fileURL)
let disclosureWindow = HistoryWindowController()
let disclosureRoot = disclosureWindow.window!.contentView!
func historyButton(_ matches: (NSButton) -> Bool) -> NSButton? {
    views(disclosureRoot).compactMap { $0 as? NSButton }.first(where:matches)
}
func disclosure(_ prefix: String) -> NSButton? { historyButton { $0.title.hasPrefix(prefix + "零消耗服务") } }
func selectYesterday() {
    if priorKey.prefix(7) != todayKey.prefix(7) { historyButton { $0.accessibilityLabel() == "上个月" }?.performClick(nil) }
    historyButton { $0.identifier?.rawValue == priorKey }?.performClick(nil)
}
func selectToday() { historyButton { $0.accessibilityLabel() == "回到今天" }?.performClick(nil) }
disclosureWindow.showWindow(nil)
check(disclosure("展开") != nil,"history opens with zero services folded")
disclosure("展开")?.performClick(nil)
selectYesterday()
check(disclosure("收起") != nil && labels(disclosureRoot).contains("0%"),"expanded zero rows stay visible on another date")
selectToday()
disclosureWindow.refreshForExternalSnapshot()
check(disclosure("收起") != nil,"return and refresh preserve expanded zero rows")
disclosure("收起")?.performClick(nil)
selectYesterday()
check(disclosure("展开") != nil && !labels(disclosureRoot).contains("0%"),"manually folded zero rows stay folded on another date")
disclosure("展开")?.performClick(nil)
disclosureWindow.close()
disclosureWindow.refreshForExternalSnapshot()
disclosureWindow.showWindow(nil)
check(disclosure("展开") != nil,"reopening the history window starts folded")
disclosureWindow.close()
// Compare accounting paths when an old service sample arrives in a new envelope.
let faultLedger = HistoryStore(configURL: URL(fileURLWithPath: fixture).deletingLastPathComponent()
    .appendingPathComponent("fault-ledger/config.json"))
for (i, balance, observed) in [(0, 100, 0), (1, 90, 1), (2, 100, 0), (3, 90, 3), (4, 150, -86400), (5, 90, 5)] {
    let stamp = ISO8601DateFormatter.flexible.string(from: start.addingTimeInterval(Double(3600 + observed)))
    let sample = provider("deepseek", [credit(String(balance), "CNY")],
                          ["balance": balance, "account": "clock-fixture", "sampledAt": stamp])
    let batch = snap([sample], Double(3600 + i))
    UsageTracker.shared.record(snapshot: batch, only: ["deepseek"])
    check(faultLedger.record(snapshot: batch, now: start), "accept history batch " + String(i))
}
check(UsageTracker.shared.todaySpent(for: "deepseek") == 10 &&
      faultLedger.latest(provider: "deepseek")?.dailyTotals?["CNY"] == 10,
      "late, duplicate and yesterday's samples cannot re-bill today's wallet")
let savedHistory = try! Data(contentsOf: faultLedger.fileURL)
try! FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: faultLedger.fileURL.path)
let whileUnreadable = faultLedger.record(snapshot: snap([codex]), now: start)
try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: faultLedger.fileURL.path)
check(!whileUnreadable && (try? Data(contentsOf: faultLedger.fileURL)) == savedHistory,
      "unreadable history refuses writes and preserves original bytes")
check(faultLedger.record(snapshot: snap([codex]), now: start) &&
      faultLedger.latest(provider: "deepseek") != nil && faultLedger.latest(provider: "codex") != nil,
      "restoring permission allows appending alongside original history")
// A new store for each observation exercises the persisted restart boundary.
func replayCodex(_ name: String, _ readings: [(Int, Int, Int)]) -> Double? {
    let url = URL(fileURLWithPath: fixture).deletingLastPathComponent().appendingPathComponent(name + "/config.json")
    for (second, used, end) in readings {
        let metric = window("本周", Double(100 - used)).merging(["resetAt": start.addingTimeInterval(Double(end)).timeIntervalSince1970 * 1000]) { _, new in new }
        let store = HistoryStore(configURL: url)
        guard store.record(snapshot: snap([provider("codex", [metric])], Double(second)), now: start) else { return nil }
    }
    return HistoryStore(configURL: url).latest(provider: "codex")?.dailyTotals?["周期：本周"]
}
let jitter = (0...101).map { ($0, 18 + $0 % 2, 1000) }
check(replayCodex("codex-jitter", jitter) == 1, "51 rebounds to 19 percent count once across restarts")
check(replayCodex("codex-reset", [(0, 90, 10), (5, 95, 10), (11, 2, 1000), (12, 3, 1000)]) == 8, "confirmed reset counts five plus two plus one")
check(replayCodex("codex-restart", [(0, 18, 1000), (1, 19, 1000), (1, 19, 1000), (2, 19, 1000)]) == 1, "restart with duplicate and unchanged samples")
exit(failures == 0 ? 0 : 1)





