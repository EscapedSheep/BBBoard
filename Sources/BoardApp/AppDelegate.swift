import AppKit
import RuleEngine
import ServiceManagement
import SwiftUI
import TaskStore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var viewModel: BoardViewModel?
    private var desktopController: DesktopPanelController?
    private var panelController: PanelController?
    private var hotKeyManager: HotKeyManager?
    private weak var desktopMenuItem: NSMenuItem?
    private weak var autoCollapseMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 无 Dock 图标、无菜单栏菜单的 accessory 形态（开发期免 Info.plist）。
        NSApp.setActivationPolicy(.accessory)
        // accessory 应用没有 mainMenu，⌘V/⌘C/⌘X/⌘A 等键等价无处路由（输入框不吃粘贴）。
        // 程序化补一个最小 mainMenu：不可见，但键等价由此进入响应链。
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        guard let store = Self.makeStore() else { return }
        let viewModel = BoardViewModel(store: store)
        self.viewModel = viewModel
        // 主形态：常驻桌面的看板
        desktopController = DesktopPanelController(viewModel: viewModel)
        desktopController?.show()
        // 次级形态：⌥Space 呼出的 Peek 面板
        panelController = PanelController(viewModel: viewModel)
        setupStatusItem()

        let hotKey = HotKeyManager { [weak self] in self?.togglePanel() }
        if !hotKey.register() {
            NSLog("BoardApp: 全局快捷键 ⌥Space 注册失败，面板仍可从菜单栏打开")
        }
        hotKeyManager = hotKey
    }

    /// 优先使用 Application Support，失败时回退到 ~/.bbboard-dev（已知开发路径）。
    /// 两条路径都失败时弹 NSAlert 说明原因后退出，不 fatalError 硬崩。
    private static func makeStore() -> TaskStore? {
        do {
            return try TaskStore.open(at: TaskStore.defaultDatabaseURL())
        } catch {
            NSLog("BoardApp: 默认库路径不可用（\(error)），回退到 ~/.bbboard-dev")
            let fallback = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".bbboard-dev/board.sqlite")
            do {
                return try TaskStore.open(at: fallback)
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法打开任务数据库"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "退出")
                alert.runModal()
                NSApp.terminate(nil)
                return nil
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Board")
        }
        let menu = NSMenu()
        let desktopItem = NSMenuItem(title: "显示桌面看板", action: #selector(toggleDesktopAction), keyEquivalent: "")
        desktopItem.target = self
        desktopItem.state = .on
        desktopMenuItem = desktopItem

        let autoCollapseItem = NSMenuItem(title: "自动收缩看板", action: #selector(toggleAutoCollapseAction), keyEquivalent: "")
        autoCollapseItem.target = self
        autoCollapseItem.state = (desktopController?.autoCollapse ?? true) ? .on : .off
        autoCollapseMenuItem = autoCollapseItem

        let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLoginAction(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let openItem = NSMenuItem(title: "打开面板 (⌥Space)", action: #selector(togglePanelAction), keyEquivalent: "")
        openItem.target = self
        let cleanupItem = NSMenuItem(title: "智能清理…", action: #selector(smartCleanupAction), keyEquivalent: "")
        cleanupItem.target = self
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(desktopItem)
        menu.addItem(autoCollapseItem)
        menu.addItem(loginItem)
        menu.addItem(openItem)
        menu.addItem(cleanupItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleLaunchAtLoginAction(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("BoardApp: 切换开机自启失败: \(error.localizedDescription)")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleAutoCollapseAction() {
        desktopController?.toggleAutoCollapse()
        autoCollapseMenuItem?.state = (desktopController?.autoCollapse ?? true) ? .on : .off
    }

    @objc private func toggleDesktopAction() {
        desktopController?.toggle()
        desktopMenuItem?.state = (desktopController?.isVisible ?? false) ? .on : .off
    }

    @objc private func togglePanelAction() { togglePanel() }

    /// 跑一次智能清理（重复/停滞/成组检测）并打开 Peek 面板展示提案卡片。
    @objc private func smartCleanupAction() {
        viewModel?.runSmartCleanup()
        panelController?.show()
    }

    @objc private func quitAction() { NSApp.terminate(nil) }

    func togglePanel() { panelController?.toggle() }
}
