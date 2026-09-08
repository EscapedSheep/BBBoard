import AppKit
import SwiftUI
import XCTest
@testable import BoardApp

/// 回归测试：macOS 26 下经 `window.contentViewController` 安装的 NSHostingView
/// 初始 frame 是 0×0（实测：设置面板打开一片空白），必须显式补 frame。
/// 这里固化"补 frame + autoresizingMask"的写法，并断言内容真的渲染出来。
@MainActor
final class SettingsRenderTests: XCTestCase {
    func testSettingsViewRendersNonBlank() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "SettingsRenderTests")!)
        let hosting = NSHostingController(rootView: SettingsView(settings: settings) { _ in })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        // 与控制器同款写法：frame 取内容实测大小（写死高度会裁掉控件）
        let fitting = hosting.sizeThatFits(in: NSSize(width: 340, height: 2000))
        let contentSize = NSSize(width: 340, height: max(fitting.height, 120))
        hosting.view.frame = NSRect(origin: .zero, size: contentSize)
        hosting.view.autoresizingMask = [.width, .height]
        window.setContentSize(contentSize)
        window.orderBack(nil)
        window.layoutIfNeeded()
        hosting.view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        let bounds = hosting.view.bounds
        XCTAssertEqual(bounds.width, 340)
        XCTAssertEqual(bounds.height, contentSize.height)
        // 5 个 Stepper + Toggle 的 grouped Form 实测高度应在合理区间（写死 280 会裁掉内容）
        XCTAssertGreaterThan(fitting.height, 280, "内容实测高度异常偏小，fitting size 不可信")

        guard let rep = hosting.view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return XCTFail("无法创建位图")
        }
        hosting.view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("无法导出 PNG")
        }
        XCTAssertGreaterThan(data.count, 4000, "渲染结果疑似空白（PNG 过小）")
    }
}
