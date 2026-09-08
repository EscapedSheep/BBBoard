import AppKit
import SwiftUI

/// 设置面板：非激活 NSPanel，失焦自动隐藏，阈值与快捷键开关绑定 AppSettings.shared。
@MainActor
final class SettingsController: NSObject {
    /// 快捷键开关变化时回调（由 AppDelegate 重新注册/注销全局快捷键）
    var onHotkeyToggle: (@MainActor (Bool) -> Void)?

    private let panel: NSPanel
    private var didCenterOnFirstShow = false

    override init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 280),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "设置"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        super.init()

        let settingsView = SettingsView(settings: .shared) { [weak self] enabled in
            self?.onHotkeyToggle?(enabled)
        }
        let hosting = NSHostingController(rootView: settingsView)
        panel.contentViewController = hosting
        // macOS 26：经 contentViewController 安装的 NSHostingView 初始 frame 是 0×0，
        // 不补 frame 窗口就是一片空白（实测复现）；autoresizingMask 跟随后续尺寸变化
        hosting.view.frame = NSRect(origin: .zero, size: NSSize(width: 340, height: 280))
        hosting.view.autoresizingMask = [.width, .height]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    func show() {
        if !didCenterOnFirstShow {
            panel.center()
            didCenterOnFirstShow = true
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func appDidResignActive() {
        panel.orderOut(nil)
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onHotkeyToggle: (Bool) -> Void

    var body: some View {
        Form {
            Stepper("Focus 条数：\(settings.focusMaxItems)", value: $settings.focusMaxItems, in: 1...5)
            Stepper("截止临近提醒：\(settings.dueApproachingDays) 天内", value: $settings.dueApproachingDays, in: 1...7)
            Stepper("等待超时：\(settings.waitingTooLongDays) 天", value: $settings.waitingTooLongDays, in: 2...14)
            Stepper("进行中停滞：\(settings.doingTooLongDays) 天", value: $settings.doingTooLongDays, in: 3...21)
            Stepper("Backlog 停滞：\(settings.backlogStaleDays) 天", value: $settings.backlogStaleDays, in: 14...90)
            Toggle("全局快捷键 ⌥Space", isOn: $settings.hotkeyEnabled)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 340)
        .onChange(of: settings.hotkeyEnabled) { _, enabled in
            onHotkeyToggle(enabled)
        }
    }
}
