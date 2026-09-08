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
        // 与控制器同款写法：frame 取内容实测高度（Form 已声明竖向 fixedSize），屏幕 80% 封顶
        let fitting = hosting.sizeThatFits(in: NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude))
        let contentSize = NSSize(width: 340, height: min(max(fitting.height, 120), 800))
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
        // 5 个 Stepper + Toggle 的 grouped Form 真实内容高度应在合理区间：
        // 低于 280 是 fitting size 不可信；高于 600 是 fixedSize 失效（又把提案高度照单全收）
        XCTAssertGreaterThan(fitting.height, 280, "内容实测高度异常偏小，fitting size 不可信")
        XCTAssertLessThan(fitting.height, 600, "内容实测高度异常偏大，fixedSize 可能失效")

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
