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
        // 不补 frame 窗口就是一片空白（实测复现）。尺寸取内容实测高度（Form 已声明
        // 竖向 fixedSize，见 SettingsView），并以屏幕高度的 80% 封顶兜底。
        let fitting = hosting.sizeThatFits(in: NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude))
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) * 0.8
        let contentSize = NSSize(width: 340, height: min(max(fitting.height, 120), maxHeight))
        hosting.view.frame = NSRect(origin: .zero, size: contentSize)
        hosting.view.autoresizingMask = [.width, .height]
        panel.setContentSize(contentSize)

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
            explained("顶部 FOCUS 区最多显示的条数") {
                Stepper("Focus 条数：\(settings.focusMaxItems)", value: $settings.focusMaxItems, in: 1...5)
            }
            explained("距截止进入该天数后：任务卡的天数环变橙，并产生「临近截止」建议") {
                Stepper("截止临近提醒：\(settings.dueApproachingDays) 天内", value: $settings.dueApproachingDays, in: 1...7)
            }
            explained("等待超过该天数：任务卡的橙色弧长满，并产生「等太久」建议与清理提案") {
                Stepper("等待超时：\(settings.waitingTooLongDays) 天", value: $settings.waitingTooLongDays, in: 2...14)
            }
            explained("进行中超过该天数未更新，产生「做太久」建议与清理提案") {
                Stepper("进行中停滞：\(settings.doingTooLongDays) 天", value: $settings.doingTooLongDays, in: 3...21)
            }
            explained("Backlog 超过该天数未动，智能清理时提议处置") {
                Stepper("Backlog 停滞：\(settings.backlogStaleDays) 天", value: $settings.backlogStaleDays, in: 14...90)
            }
            explained("呼出/收起面板；关闭后只能从菜单栏图标打开") {
                Toggle("全局快捷键 ⌥Space", isOn: $settings.hotkeyEnabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 340)
        // 声明竖向固有尺寸：grouped Form 默认会吃满任何给定高度（实测 2000 上限被照单全收、
        // 面板撑满整屏），fixedSize 后 sizeThatFits 才返回内容真实高度
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: settings.hotkeyEnabled) { _, enabled in
            onHotkeyToggle(enabled)
        }
    }

    /// 设置项 + 常驻说明文字（非激活面板上 hover tooltip 不可靠，说明直接摆出来）
    private func explained<Content: View>(_ caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
