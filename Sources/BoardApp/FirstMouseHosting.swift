import AppKit
import SwiftUI

/// 首击穿透：本 App 常驻非激活态（.accessory），窗口又是 .nonactivatingPanel——
/// 系统把“点击非激活 App 的窗口”默认当作激活点击吞掉，而面板不会触发激活，
/// 结果点击被完全丢弃（实测症状：所有点击面包屑均无输出）。
/// 让承载 SwiftUI 内容的视图接受首击，点击才能正常投递。
///
/// 注：不要在这里覆写 mouseDown 做拖拽——SwiftUI 的内部命中视图会自行消费
/// mouseDown，不会冒泡到本类（实测零回调）。拖拽拦截在 BoardApplication.sendEvent。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = FirstMouseHostingView(rootView: rootView)
    }
}
