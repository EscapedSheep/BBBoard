import AIParser
import AppKit
import SwiftUI

/// 首次启动引导：仅展示一次（UserDefaults 标记），介绍三个入口与 AI 可用性。
@MainActor
final class OnboardingController {
    private static let didCompleteKey = "BBBoard.didCompleteOnboarding"

    private var panel: NSPanel?

    func showOnceIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didCompleteKey) else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "欢迎使用 BBBoard"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        self.panel = panel

        let view = OnboardingView(availability: AIAvailabilityProbe.current) { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.didCompleteKey)
            self?.panel?.close()
            self?.panel = nil
        }
        let hosting = NSHostingController(rootView: view)
        panel.contentViewController = hosting
        // 同 SettingsController：macOS 26 下 hosting view 初始 frame 为 0×0 必须补齐；
        // 尺寸取内容实测高度，并以屏幕高度的 80% 封顶兜底
        let fitting = hosting.sizeThatFits(in: NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) * 0.8
        let contentSize = NSSize(width: 380, height: min(max(fitting.height, 120), maxHeight))
        hosting.view.frame = NSRect(origin: .zero, size: contentSize)
        hosting.view.autoresizingMask = [.width, .height]
        panel.setContentSize(contentSize)

        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    let availability: AIAvailability
    var onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("欢迎使用 BBBoard")
                .font(.title2.bold())

            Text("BBBoard 是你的桌面常驻任务看板，三个入口随用随取：\n· 桌面看板：常驻桌面边缘，鼠标悬停即展开\n· ⌥Space：随时呼出 Peek 面板快速倾倒想法\n· 菜单栏图标：打开面板、智能清理与设置")
                .font(.body)

            Text(aiDescription)
                .font(.body)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("开始使用", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var aiDescription: String {
        if availability == .available {
            return "Apple Intelligence 可用：倾倒想法会自动整理成任务。"
        }
        let hint = availability.hint ?? "本地 AI 暂不可用"
        return "\(hint)：倾倒想法会自动降级为规则解析，功能不受影响；开启 Apple Intelligence 后将自动启用智能整理。"
    }
}
