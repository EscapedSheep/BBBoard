import AppKit
import SwiftUI

/// 首次启动引导：仅展示一次（UserDefaults 标记），介绍三个入口。
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

        let view = OnboardingView { [weak self] in
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
    var onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("欢迎使用 BBBoard")
                .font(.title2.bold())

            Text("BBBoard 是你的桌面常驻任务看板，三个入口随用随取：\n· 桌面看板：常驻桌面边缘，鼠标悬停即展开\n· ⌥Space：随时呼出 Peek 面板快速倾倒想法\n· 菜单栏图标：打开面板、智能清理与设置")
                .font(.body)

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
}
