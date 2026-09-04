import AppKit
import SwiftUI

/// Peek 面板：非激活浮层，失焦自动收起，可浮于全屏 App 之上。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    /// 首次显示时居中过一次后保留用户拖拽的位置
    private var didCenterOnFirstShow = false

    init(viewModel: BoardViewModel) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // 透明窗口，圆角材质背景由 SwiftUI 视图提供
        panel.isOpaque = false
        panel.backgroundColor = .clear
        self.panel = panel
        super.init()
        panel.delegate = self
        // peek 面板同为非激活面板：文本输入前确保 App 激活且面板为 key；
        // 宿主视图接受首击（App 常驻非激活态，否则首个点击被系统吞掉）
        panel.contentViewController = FirstMouseHostingController(rootView: BoardView(
            viewModel: viewModel,
            onRequestKeyboard: { [weak panel] in
                NSApp.activate()
                panel?.makeKey()
            }
        ))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        if !didCenterOnFirstShow {
            panel.center()
            didCenterOnFirstShow = true
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    @objc private func appDidResignActive() {
        hide()
    }

    // 失焦自动收起；但收起动作不应发生在本 App 的弹出菜单成为 key window 时。
    func windowDidResignKey(_ notification: Notification) {
        if let keyWindow = NSApp.keyWindow, keyWindow !== panel { return }
        hide()
    }
}
