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
        hosting.view.frame = NSRect(origin: .zero, size: NSSize(width: 340, height: 280))
        hosting.view.autoresizingMask = [.width, .height]
        window.orderBack(nil)
        window.layoutIfNeeded()
        hosting.view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        let bounds = hosting.view.bounds
        XCTAssertEqual(bounds.width, 340)
        XCTAssertEqual(bounds.height, 280)

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
