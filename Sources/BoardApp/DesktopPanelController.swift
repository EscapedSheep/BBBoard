import AppKit
import QuartzCore
import RuleEngine
import SwiftUI

/// 桌面挂板的展开/交互状态，供 SwiftUI 视图响应式读取与回写。
@Observable
final class DesktopBoardState {
    var isExpanded = false
    var isEditing = false
    var isFieldFocused = false
    /// 头部块实测高度（原生拖拽区域判定用），由 SwiftUI 侧测量回报
    var headerHeight: CGFloat = 44
}

/// 桌面层挂板窗口：位于桌面图标之上、普通窗口之下，行为对齐 Sonoma 桌面小组件。
/// 非激活面板：点击可操作但绝不激活 App；不主动 makeKey，
/// 只在被用户直接点击（如点进输入框）时由系统置为 key，点击他处后自动交还。
private final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true } // 输入框/行内重命名需要 key 状态
    override var canBecomeMain: Bool { false }
}

/// 自有的容器视图：跟踪区域挂在它上面（而非 NSHostingView，避免宿主视图被替换/事件路径不明的隐患）。
private final class TrackingContainerView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    /// 接受首击：App 常驻非激活态，不覆写则首个点击会被系统当作“激活点击”吞掉。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    // 注：拖拽由 BoardApplication.sendEvent 拦截 → NSWindow.performDrag 原生实现
    // （performDrag 接受首击，窗口非 key 也能首按即拖，且系统移动路径无残影）。
    // SwiftUI DragGesture / NSPanGestureRecognizer 在非 key 窗口的首击上均实测无效。
}

/// 桌面挂板窗口管理：
/// - 默认紧凑（仅头部），hover 展开完整看板，移开后延迟收起；
/// - hover 检测双通道：容器视图的 NSTrackingArea（主）+ 全局/本地 mouseMoved 监听比对窗口 frame（备，App 非激活也可靠）；
/// - 拖拽移动：sendEvent 拦截命中头部区域的 mouseDown → 系统原生拖拽，落定后钳制并持久化。
/// 可变状态全部只在主线程访问，故标记 @unchecked Sendable。
@MainActor
final class DesktopPanelController: NSObject, @unchecked Sendable {
    static let compactWidth: CGFloat = 340
    /// 展开态横向三列看板需要的宽度
    static let expandedWidth: CGFloat = 620
    static let margin: CGFloat = 20
    static let maxHeightRatio: CGFloat = 0.62
    /// 移出后的收起宽限，避免指针短暂滑出边缘时抖动
    static let collapseGrace: TimeInterval = 0.4
    /// UserDefaults 键：面板左上角锚点 "x,y"（屏幕坐标系）
    static let anchorDefaultsKey = "BBBoard.desktopBoardAnchor"
    /// UserDefaults 键：指针移出后是否自动收缩（false = 保持展开）
    static let autoCollapseDefaultsKey = "BBBoard.desktopAutoCollapse"

    /// 自动收缩开关（菜单栏可切，持久化）。关闭后 hover 展开照常，移出不收起。
    var autoCollapse: Bool {
        didSet { UserDefaults.standard.set(autoCollapse, forKey: Self.autoCollapseDefaultsKey) }
    }

    private let panel: DesktopPanel
    private let viewModel: BoardViewModel
    private let state = DesktopBoardState()
    private let container = TrackingContainerView(frame: .zero)
    private var hostingController: FirstMouseHostingController<BoardView>?

    /// 面板左上角锚点（屏幕坐标），内容伸缩/窗口动画都以此为基准
    private var anchorTopLeft: NSPoint
    private var collapseWorkItem: DispatchWorkItem?
    private var menuTrackingCount = 0
    private var didInitialLayout = false
    private var pointerInside = false
    private var isDragging = false
    private var activatedForKeyboard = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init(viewModel: BoardViewModel) {
        self.viewModel = viewModel
        self.autoCollapse = UserDefaults.standard.object(forKey: Self.autoCollapseDefaultsKey) as? Bool ?? true
        let anchor = Self.restoredAnchor() ?? Self.defaultAnchor()
        self.anchorTopLeft = anchor
        let panel = DesktopPanel(
            contentRect: Self.frame(height: 480, anchor: anchor, expanded: false),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // 桌面图标层 +1：桌面图标之上、普通窗口之下（与 Apple 桌面小组件同层）。
        // 此前的 desktopWindow+1 位于 Finder 图标窗口（desktop+100）之下，
        // 全屏的图标层先行命中测试，导致点击永远到不了本面板。
        // 代价：与图标重叠处会盖住图标（Apple 小组件亦然），可接受。
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        // 全 Space 可见、Space 切换时保持不动、不进 ⌘Tab / 窗口循环
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // 材质本身提供与壁纸的分隔，不再加投影
        panel.hidesOnDeactivate = false // 点击桌面他处不隐藏——它就住在那里
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        self.panel = panel
        super.init()
        NSLog("BoardApp[desktop]: panel configured level=\(panel.level.rawValue) ignoresMouseEvents=\(panel.ignoresMouseEvents)")

        let hosting = FirstMouseHostingController(rootView: BoardView(
            viewModel: viewModel,
            style: .desktop,
            maxHeight: Self.maxBoardHeight(),
            desktopState: state,
            onIdealHeightChange: { [weak self] idealHeight in
                self?.resize(toIdealHeight: idealHeight)
            },
            onInteractionChange: { [weak self] in
                self?.handleInteractionChange()
            },
            onRequestKeyboard: { [weak self] in
                self?.prepareForKeyboard()
            }
        ))
        hostingController = hosting
        container.onHoverChange = { [weak self] inside in
            self?.handlePointerTransition(inside: inside, source: "trackingArea")
        }
        panel.contentView = container
        hosting.view.frame = container.bounds
        hosting.view.autoresizingMask = [.width, .height]
        container.addSubview(hosting.view)

        // 拖拽：BoardApplication.sendEvent 拦截命中头部区域的 leftMouseDown → performDrag。
        // （SwiftUI 宿主视图会消费 mouseDown，视图层任何拦截都到不了；sendEvent 必然经过。）
        (NSApp as? BoardApplication)?.desktopDragInterception = BoardApplication.DragInterception(
            panel: panel,
            dragZoneHeight: { [weak self] in self?.state.headerHeight ?? 44 },
            onDragBegin: { [weak self] in self?.nativeDragBegin() },
            onDragEnd: { [weak self] in self?.nativeDragEnd() }
        )
        // 以钳制后的实际位置为准（跨启动恢复时屏幕配置可能已变）
        anchorTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)

        installMouseMonitors()

        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidBeginTracking),
            name: NSMenu.didBeginTrackingNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidEndTracking),
            name: NSMenu.didEndTrackingNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil
        )
    }

    var isVisible: Bool { panel.isVisible }

    /// orderFront 而非 makeKeyAndOrderFront：出现时不抢焦点。
    func show() {
        panel.orderFront(nil)
    }

    func hide() {
        cancelScheduledCollapse()
        panel.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// 切换自动收缩。关闭时立即展开给出反馈；重新打开时若指针已在面板外则走正常延迟收起。
    func toggleAutoCollapse() {
        autoCollapse.toggle()
        if autoCollapse {
            evaluateCollapseAfterSuppressionChange()
        } else {
            cancelScheduledCollapse()
            setExpanded(true)
        }
    }

    // MARK: - hover 检测（双通道）

    /// 全局监听在 App 非激活时收事件副本（桌面挂板的常态），本地监听覆盖 App 激活的情形。
    /// 鼠标事件的监听不需要辅助功能权限（键盘监听才需要）。
    private func installMouseMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.updatePointerLocation(NSEvent.mouseLocation, source: "globalMonitor")
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updatePointerLocation(NSEvent.mouseLocation, source: "localMonitor")
            return event
        }
        NSLog("BoardApp[desktop]: mouse monitors installed global=\(globalMouseMonitor != nil) local=\(localMouseMonitor != nil)")
    }

    /// 边沿触发：只有“指针是否在面板内”这一状态翻转时才产生进出事件，天然节流。
    private func updatePointerLocation(_ point: NSPoint, source: String) {
        let inside = panel.frame.contains(point)
        guard inside != pointerInside else { return }
        handlePointerTransition(inside: inside, source: source)
    }

    private func handlePointerTransition(inside: Bool, source: String) {
        // 两个通道（trackingArea / 全局监听）去重：状态未翻转的事件直接丢弃
        guard inside != pointerInside else { return }
        pointerInside = inside
        NSLog("BoardApp[desktop]: pointer \(inside ? "entered" : "exited") via \(source)")
        inside ? hoverEntered() : hoverExited()
    }

    private func hoverEntered() {
        cancelScheduledCollapse()
        // 空看板也展开——否则无法从桌面形态添加第一条任务
        // 拖拽/按压中不做展开切换，避免布局在手指（按键）下方变化
        guard !isDragging else { return }
        setExpanded(true)
    }

    private func hoverExited() {
        scheduleCollapse()
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.isExpanded != expanded else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            state.isExpanded = expanded
        }
    }

    // MARK: - 延迟收起与抑制

    private func scheduleCollapse() {
        guard autoCollapse else { return }
        cancelScheduledCollapse()
        let work = DispatchWorkItem { [weak self] in
            self?.collapseNow()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseGrace, execute: work)
    }

    private func cancelScheduledCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    private func collapseNow() {
        guard !collapseSuppressed else { return }
        setExpanded(false)
    }

    /// 交互中不收起：拖拽移动 / 行内重命名 / 输入框持焦点 / 面板菜单打开中 /
    /// 本 App 其他弹出窗口为 key（复用 peek 面板的“菜单成为 key window”守卫思路）。
    private var collapseSuppressed: Bool {
        if isDragging { return true }
        if state.isEditing || state.isFieldFocused { return true }
        if menuTrackingCount > 0 { return true }
        if let keyWindow = NSApp.keyWindow, keyWindow !== panel { return true }
        return false
    }

    /// 抑制因素消失后补判：指针已在面板外则重新走延迟收起。
    private func evaluateCollapseAfterSuppressionChange() {
        guard state.isExpanded, !collapseSuppressed else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) {
            scheduleCollapse()
        }
    }

    // MARK: - 键盘输入的激活管理

    /// 文本输入需要 key window：用户点击输入框/双击重命名时由 SwiftUI 侧回调触发。
    /// 这是主动的输入意图，激活 + 置 key 是预期行为（“不抢焦点”只针对被动悬停与点击任务）。
    private func prepareForKeyboard() {
        NSLog("BoardApp[desktop]: activate + makeKey for text input")
        // 只在自己发起激活时记账：App 已被激活（如 Peek 面板激活的）时不得代为 deactivate
        if !NSApp.isActive { activatedForKeyboard = true }
        NSApp.activate()
        panel.makeKey()
    }

    /// 交互状态变化入口：进入文本输入（重命名/输入框聚焦）时确保窗口可接收键盘；
    /// 输入结束后交还激活状态；最后补判收起。
    private func handleInteractionChange() {
        if state.isEditing || state.isFieldFocused {
            if !panel.isKeyWindow { prepareForKeyboard() }
        } else if activatedForKeyboard {
            activatedForKeyboard = false
            if panel.isKeyWindow {
                NSLog("BoardApp[desktop]: yield activation after text input")
                NSApp.deactivate()
            }
        }
        evaluateCollapseAfterSuppressionChange()
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        menuTrackingCount += 1
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        menuTrackingCount = max(0, menuTrackingCount - 1)
        evaluateCollapseAfterSuppressionChange()
    }

    // MARK: - 拖拽移动与位置持久化（系统原生 performDrag）

    /// performDrag 模态循环开始前调用：抑制收起与展开切换。
    private func nativeDragBegin() {
        isDragging = true
        cancelScheduledCollapse()
    }

    /// performDrag 返回（松手）后调用：钳制 + 持久化 + 补判收起。
    /// 移动本身是系统路径完成的，这里只做落定。
    private func nativeDragEnd() {
        let clamped = Self.clampedToVisibleFrame(panel.frame)
        if clamped != panel.frame {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            panel.setFrame(clamped, display: true)
            NSAnimationContext.endGrouping()
        }
        anchorTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        Self.saveAnchor(anchorTopLeft)
        NSLog("BoardApp[desktop]: drag settled, anchor=\(self.anchorTopLeft)")
        isDragging = false
        evaluateCollapseAfterSuppressionChange()
    }

    @objc private func appWillTerminate(_ notification: Notification) {
        Self.saveAnchor(anchorTopLeft)
    }

    private static func saveAnchor(_ point: NSPoint) {
        UserDefaults.standard.set("\(point.x),\(point.y)", forKey: anchorDefaultsKey)
    }

    private static func restoredAnchor() -> NSPoint? {
        guard let raw = UserDefaults.standard.string(forKey: anchorDefaultsKey) else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return NSPoint(x: parts[0], y: parts[1])
    }

    /// 默认位置：主屏右上角，留出边距。
    private static func defaultAnchor() -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - compactWidth - margin, y: visible.maxY - margin)
    }

    /// 把窗口完整钳制进“与其交集最大的屏幕”的可见区内。
    private static func clampedToVisibleFrame(_ frame: NSRect) -> NSRect {
        NSRect(origin: clampedOrigin(for: frame.size, target: frame.origin, reference: frame), size: frame.size)
    }

    /// 只钳制 origin（拖拽路径专用：大小不变，避免额外布局）。
    private static func clampedOrigin(for size: NSSize, target: NSPoint, reference: NSRect? = nil) -> NSPoint {
        let reference = reference ?? NSRect(origin: target, size: size)
        var bestScreen = NSScreen.main
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = screen.visibleFrame.intersection(reference)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }
        guard let visible = bestScreen?.visibleFrame else { return target }
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        return NSPoint(
            x: min(max(target.x, visible.minX), visible.maxX - width),
            y: min(max(target.y, visible.minY), visible.maxY - height)
        )
    }

    // MARK: - 尺寸与布局

    /// 内容驱动的窗口尺寸：首次布局即时设定，之后用短动画过渡（展开/收起/任务增删共用）。
    /// 宽度随展开态变化（紧凑 340 / 展开三列 620），拖拽进行中不做动画，直接落位（动画中途改 frame 会产生残影）。
    private func resize(toIdealHeight height: CGFloat) {
        let frame = Self.frame(height: height, anchor: anchorTopLeft, expanded: state.isExpanded)
        let changed = abs(frame.height - panel.frame.height) > 0.5
            || abs(frame.width - panel.frame.width) > 0.5
            || frame.origin != panel.frame.origin
        guard changed else { return }
        // 宽度变化经钳制可能左移：以实际 frame 更新锚点，避免收起/展开来回跳
        if !isDragging {
            anchorTopLeft = NSPoint(x: frame.minX, y: frame.maxY)
        }
        guard didInitialLayout else {
            panel.setFrame(frame, display: false)
            didInitialLayout = true
            return
        }
        guard !isDragging else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private static func maxBoardHeight() -> CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) * maxHeightRatio
    }

    /// 以左上角锚点为基准向下/向右生长，并钳制在屏幕可见区内。
    private static func frame(height: CGFloat, anchor: NSPoint, expanded: Bool) -> NSRect {
        let height = min(max(height, 160), maxBoardHeight())
        let width = expanded ? expandedWidth : compactWidth
        let frame = NSRect(x: anchor.x, y: anchor.y - height, width: width, height: height)
        return clampedToVisibleFrame(frame)
    }
}
