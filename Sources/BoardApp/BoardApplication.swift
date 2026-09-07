import AppKit

/// 自定义 NSApplication 的唯一理由：在 sendEvent 拦截桌面挂板的拖拽首击
/// （SwiftUI 的内部命中视图自行消费 mouseDown，不会冒泡到 NSHostingView 子类——
/// sendEvent 是每次首击必然经过的最后一道关口）。
final class BoardApplication: NSApplication {
    /// 桌面挂板拖拽拦截配置（DesktopPanelController 启动时注入）。
    struct DragInterception {
        weak var panel: NSPanel?
        let dragZoneHeight: @MainActor () -> CGFloat
        let onDragBegin: @MainActor () -> Void
    }

    var desktopDragInterception: DragInterception?

    override func sendEvent(_ event: NSEvent) {
        // 桌面挂板：命中头部拖拽区域的 leftMouseDown 直接转系统原生拖拽。
        // performDrag 接受首击（文档行为）。
        // macOS 26 起 performDrag 是异步的：启动 WindowServer 拖拽后立刻返回，
        // 窗口移动在其返回之后才发生——拖拽结束（松手）由 DesktopPanelController
        // 轮询 pressedMouseButtons 判定，这里不再同步回调 onDragEnd。
        if event.type == .leftMouseDown,
           let interception = desktopDragInterception,
           let panel = interception.panel,
           event.window === panel
        {
            // locationInWindow：y 自窗口左下角向上；头部在顶部
            let fromTop = panel.frame.height - event.locationInWindow.y
            if fromTop <= interception.dragZoneHeight() + 8 {
                interception.onDragBegin()
                NSLog("BoardApp[desktop]: drag via performDrag start")
                panel.performDrag(with: event)
                return // 事件已消费，不走正常分发
            }
        }

        super.sendEvent(event)
    }
}
