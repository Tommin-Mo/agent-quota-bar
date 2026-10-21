import AppKit

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
