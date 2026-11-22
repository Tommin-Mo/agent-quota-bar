import AppKit

if CommandLine.arguments.dropFirst().elementsEqual(["--read-doubao-quota"]) {
    let reader = NSApplication.shared
    reader.setActivationPolicy(.prohibited)
    Task {
        print(await DoubaoQuota.read())
        exit(0)
    }
    reader.run()
}

// A reidentified preview reopened by Launch Services loses its fixture environment.
if Bundle.main.bundleIdentifier != "com.tommin.agentquotabar",
   Bundle.main.bundleURL.pathExtension == "app",
   (ProcessInfo.processInfo.environment["AGENT_QUOTA_CONFIG"] == nil ||
    ProcessInfo.processInfo.environment["AGENT_QUOTA_COLLECTOR"] == nil) {
    NSLog("AgentQuotaBar: refusing reidentified bundle %@; set AGENT_QUOTA_CONFIG and AGENT_QUOTA_COLLECTOR for previews.",
          Bundle.main.bundleIdentifier ?? "<nil>")
    exit(1)
}

if CommandLine.arguments.contains("--usage-sample") {
    UsageSampler.run()
    exit(0)
}

// 单实例：从 dist 和 /Applications 各启动一次时，只保留一个菜单栏图标。
let bundleID = Bundle.main.bundleIdentifier ?? "com.tommin.agentquotabar"
if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .first(where: { $0.processIdentifier != getpid() }) {
    existing.activate(options: [.activateIgnoringOtherApps])
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

// 最小主菜单：保证设置窗口里的复制/粘贴/全选快捷键可用。
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(
    withTitle: "关于 Agent 额度",
    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
    keyEquivalent: ""
)
appMenu.addItem(withTitle: "设置…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",").target = delegate
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "退出 Agent 额度", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let editItem = NSMenuItem()
mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "编辑")
editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu

app.mainMenu = mainMenu
app.run()
