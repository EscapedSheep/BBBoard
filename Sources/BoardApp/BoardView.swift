import RuleEngine
import SwiftUI
import TaskStore

/// 看板主界面：桌面挂板（.desktop）与 ⌥Space 呼出面板（.peek）共用同一份内容。
/// 视觉方向：Sonoma 桌面小组件——半透明材质、连续圆角、克制的分区与状态色。
struct BoardView: View {
    enum Style { case desktop, peek }

    let viewModel: BoardViewModel
    var style: Style = .peek
    /// desktop 模式下面板整体高度上限（由窗口层按屏幕高度计算）。
    var maxHeight: CGFloat = .infinity
    /// desktop 模式的展开/交互状态（hover 展开收起由窗口层驱动）。
    var desktopState: DesktopBoardState?
    /// desktop 模式下回报理想内容高度，供窗口层自适应尺寸。
    var onIdealHeightChange: (@MainActor (CGFloat) -> Void)?
    /// desktop 模式下交互抑制状态变化时回调（供窗口层补判收起）。
    var onInteractionChange: (@MainActor () -> Void)?
    /// 文本输入前回调（非激活面板需要先激活 App + 置 key，输入框才能拿到焦点）。
    var onRequestKeyboard: (@MainActor () -> Void)?

    @State private var newTitle = ""
    @State private var newStatus: TaskStatus = .today
    @State private var hasDueDate = false
    @State private var newDueDate = Date()
    @State private var editingTaskID: Int64?
    @State private var editText = ""
    @State private var editingNoteTaskID: Int64?
    @State private var noteText = ""
    /// 行内截止日期编辑中的任务（⋯ 菜单「选择日期…」触发）
    @State private var editingDueTaskID: Int64?
    @State private var addingSubtaskTo: Int64?
    @State private var subtaskText = ""
    @State private var hoveredTaskID: Int64?
    /// Finder 式选中：单击选中卡片（高亮），再单击已选中的卡片进入重命名编辑
    @State private var selectedTaskID: Int64?
    @State private var chromeHeight: CGFloat = 0
    @State private var sectionsHeight: CGFloat = 0
    @State private var dropTargetSection: TaskStatus?
    @State private var showClearDoneConfirm = false
    @State private var brainDumpOpen = false
    @State private var brainDumpText = ""
    @State private var focusedProposalIDs: Set<UUID> = []
    /// 悬停延时展开的被截断文本（标题/说明/子任务），见 HoverExpandText
    @State private var expandedText: ExpandedTextKey?
    @FocusState private var newTaskFieldFocused: Bool
    @FocusState private var editFieldFocused: Bool
    @FocusState private var noteFieldFocused: Bool
    @FocusState private var subtaskFieldFocused: Bool
    @FocusState private var brainDumpFieldFocused: Bool
    @FocusState private var cleanupNameFocused: Bool

    private let cornerRadius: CGFloat = 18

    init(
        viewModel: BoardViewModel,
        style: Style = .peek,
        maxHeight: CGFloat = .infinity,
        desktopState: DesktopBoardState? = nil,
        onIdealHeightChange: (@MainActor (CGFloat) -> Void)? = nil,
        onInteractionChange: (@MainActor () -> Void)? = nil,
        onRequestKeyboard: (@MainActor () -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.style = style
        self.maxHeight = maxHeight
        self.desktopState = desktopState
        self.onIdealHeightChange = onIdealHeightChange
        self.onInteractionChange = onInteractionChange
        self.onRequestKeyboard = onRequestKeyboard
    }

    /// 桌面挂板默认紧凑（只有头部），hover 才展开；peek 面板始终展开。
    private var isCompact: Bool {
        style == .desktop && !(desktopState?.isExpanded ?? true)
    }

    var body: some View {
        content
        .frame(width: style == .desktop ? (isCompact ? 340 : 620) : 620, height: style == .peek ? 560 : nil)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0; reportIdealHeight() }
        .onPreferenceChange(SectionsHeightKey.self) { sectionsHeight = $0; reportIdealHeight() }
        .onPreferenceChange(HeaderHeightKey.self) { desktopState?.headerHeight = $0 }
        .onAppear { viewModel.refreshFocusIfDayChanged() }
        // 设置页调整阈值/Focus 条数后重算派生数据
        .onChange(of: viewModel.settings.thresholdsSignature) { _, _ in viewModel.recomputeDerived() }
        .onChange(of: isCompact) { _, compact in
            reportIdealHeight()
            if !compact { viewModel.refreshFocusIfDayChanged() }
        }
        .onChange(of: editingTaskID != nil) { _, _ in syncEditingState() }
        .onChange(of: editingDueTaskID != nil) { _, _ in syncEditingState() }
        // 被编辑的任务可能被删除/改区消失：校验编辑目标仍存在，否则编辑态卡死永不收起
        .onChange(of: viewModel.tasks.map(\.id)) { _, ids in
            // 输入框在聚焦态被移除时 @FocusState 可能残留 true（非激活面板实测复现，
            // 表现为 isFieldFocused 卡死、面板永不收起），一律先落回 false
            if let editingTaskID, !ids.contains(editingTaskID) {
                editFieldFocused = false
                self.editingTaskID = nil
            }
            if let editingNoteTaskID, !ids.contains(editingNoteTaskID) {
                noteFieldFocused = false
                self.editingNoteTaskID = nil
            }
            if let addingSubtaskTo, !ids.contains(addingSubtaskTo) {
                subtaskFieldFocused = false
                self.addingSubtaskTo = nil
            }
            if let editingDueTaskID, !ids.contains(editingDueTaskID) {
                self.editingDueTaskID = nil
            }
            if let selectedTaskID, !ids.contains(selectedTaskID) {
                self.selectedTaskID = nil
            }
        }
        .onChange(of: newTaskFieldFocused) { _, _ in syncFieldFocus() }
        .onChange(of: editFieldFocused) { _, _ in syncFieldFocus() }
        .onChange(of: noteFieldFocused) { _, _ in syncFieldFocus() }
        .onChange(of: subtaskFieldFocused) { _, _ in syncFieldFocus() }
        .onChange(of: brainDumpFieldFocused) { _, _ in syncFieldFocus() }
        .onChange(of: cleanupNameFocused) { _, _ in syncFieldFocus() }
        // 提案卡片被确认/丢弃时其焦点状态随之消失，清理残留 id 再补判
        .onChange(of: viewModel.proposals.map(\.id)) { _, ids in
            focusedProposalIDs.formIntersection(ids)
            syncFieldFocus()
        }
    }

    /// 重命名/截止日期编辑中都抑制面板收起（desktop 模式）。
    private func syncEditingState() {
        desktopState?.isEditing = editingTaskID != nil || editingDueTaskID != nil
        onInteractionChange?()
    }

    /// 任一文本输入框（新建/重命名/说明/子任务/brain dump/提案卡片）聚焦都算"输入中"，抑制面板收起。
    private func syncFieldFocus() {
        let focused = newTaskFieldFocused || editFieldFocused || noteFieldFocused || subtaskFieldFocused || brainDumpFieldFocused || cleanupNameFocused || !focusedProposalIDs.isEmpty
        desktopState?.isFieldFocused = focused
        onInteractionChange?()
    }

    /// 卡片内被截断文本（标题/说明/子任务）的悬停展开标识
    private func expandKey(_ task: Task, _ kind: ExpandedTextKey.Kind) -> ExpandedTextKey {
        ExpandedTextKey(taskID: task.id ?? 0, kind: kind)
    }

    /// 紧凑与展开共用同一视图树：头部始终在场、身份稳定，展开只是在其下方追加内容。
    /// 头部拖拽由 BoardApplication.sendEvent → performDrag 原生实现（首击可用、无残影），
    /// 这里只负责回报头部高度供拖拽区域判定。
    private var content: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: HeaderHeightKey.self, value: geo.size.height)
                    })
                if isCompact {
                    // 紧凑态可选常驻 FOCUS 区（AppSettings 开关，菜单栏可切），纯展示
                    if viewModel.settings.focusPinnedInCompact, !viewModel.focusItems.isEmpty {
                        focusSection
                    }
                } else {
                    if !viewModel.focusItems.isEmpty {
                        focusSection
                    }
                    if !viewModel.suggestions.isEmpty {
                        suggestionsSection
                    }
                    newTaskRow
                    brainDumpSection
                    if !viewModel.proposals.isEmpty {
                        proposalsSection
                    }
                    if !viewModel.cleanupProposals.isEmpty {
                        cleanupSection
                    }
                    if let notice = viewModel.brainDumpNotice ?? viewModel.cleanupNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 4)
                    }
                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }
                    Divider()
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: ChromeHeightKey.self, value: geo.size.height)
            })

            if !isCompact {
                ScrollView {
                    sections
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: SectionsHeightKey.self, value: geo.size.height)
                        })
                }
                .scrollIndicators(style == .desktop ? .hidden : .automatic)
            }
        }
    }

    private func reportIdealHeight() {
        guard style == .desktop, chromeHeight > 0 else { return }
        let ideal: CGFloat
        if isCompact {
            ideal = chromeHeight
        } else {
            let budget = maxHeight.isFinite ? max(160, maxHeight - chromeHeight) : sectionsHeight
            ideal = chromeHeight + min(sectionsHeight, budget)
        }
        onIdealHeightChange?(ideal)
    }

    // MARK: - 状态字形与配色（呼应概念稿的 □ / ● / ◌ 语言）

    private func glyph(for status: TaskStatus) -> String { statusGlyph(status) }

    private func accent(for status: TaskStatus) -> Color { statusAccent(status) }

    /// 状态字形 + 天数环（任务卡与 FOCUS 行共用同一视觉语言）。
    /// 环顶小球 = 已越过该卡应遵守的时间线（逾期红 / 超阈值橙，阈值与建议区同一套）。
    @ViewBuilder
    private func statusGlyphWithRing(_ task: Task, ringSize: CGFloat = 22, glyphSize: CGFloat = 12) -> some View {
        ZStack {
            if let ring = timeRing(for: task) {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1.5)
                // 上一圈浅色整圈留底（年龄环多圈制的"资历层"）
                if let underlay = ring.underlay {
                    Circle()
                        .stroke(underlay.opacity(0.35), lineWidth: 1.5)
                }
                Circle()
                    .trim(from: 0, to: ring.progress)
                    .stroke(ring.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // 越线警报球：钉在 12 点的环线上
                if let marker = ring.marker {
                    Circle()
                        .fill(marker)
                        .frame(width: ringSize * 0.28, height: ringSize * 0.28)
                        .offset(y: -ringSize / 2)
                }
            }
            Image(systemName: glyph(for: task.status))
                .font(.system(size: glyphSize))
                .foregroundStyle(accent(for: task.status))
        }
        .frame(width: ringSize, height: ringSize)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(headerDate)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if viewModel.tasks.isEmpty {
                Text("无任务")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Todo \(viewModel.tasks(in: .today).count) · Doing \(viewModel.tasks(in: .doing).count) · Waiting \(viewModel.tasks(in: .waiting).count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var headerDate: String {
        let zh = Locale(identifier: "zh_CN")
        let day = Date().formatted(.dateTime.month(.wide).day().locale(zh))
        let weekday = Date().formatted(.dateTime.weekday(.wide).locale(zh))
        return "\(day) \(weekday)"
    }

    // MARK: - Daily Focus

    /// FOCUS 区：Top 3 + 主因标签。纯展示（点击挪 DOING 容易误触；改状态用拖拽或菜单）。
    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "flame")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                Text("FOCUS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            ForEach(viewModel.focusItems) { item in
                HStack(spacing: 8) {
                    // 与任务卡同款"字形 + 天数环"；任务已消失则回退纯字形
                    if let task = viewModel.tasks.first(where: { $0.id == item.taskId }) {
                        statusGlyphWithRing(task, ringSize: 20, glyphSize: 11)
                    } else {
                        Image(systemName: glyph(for: .today))
                            .font(.system(size: 13))
                            .foregroundStyle(accent(for: .today))
                            .frame(width: 16, height: 16)
                    }
                    Text(item.taskTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.reason)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.10))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: - 建议区

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.suggestions) { suggestion in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: suggestionIcon(suggestion.kind))
                        .font(.caption)
                        .foregroundStyle(suggestionColor(suggestion.kind))
                        .padding(.top, 1)
                    Text("「\(suggestion.taskTitle)」\(suggestion.reason)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    HStack(spacing: 10) {
                        Button("去处理") { viewModel.handle(suggestion) }
                        Button("忽略") { viewModel.dismiss(suggestion) }
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func suggestionIcon(_ kind: Suggestion.Kind) -> String {
        switch kind {
        case .overdue: "exclamationmark.circle.fill"
        case .dueApproaching: "clock"
        case .waitingTooLong: "hourglass"
        case .doingTooLong: "tortoise.fill"
        }
    }

    private func suggestionColor(_ kind: Suggestion.Kind) -> Color {
        switch kind {
        case .overdue: .red
        case .dueApproaching, .waitingTooLong: .orange
        case .doingTooLong: .blue
        }
    }

    // MARK: - 新建任务

    private var newTaskRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.tertiary)
                TextField("新建任务，回车添加", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($newTaskFieldFocused)
                    .onSubmit(addTask)
                    // 非激活面板：点击时窗口尚非 key，先激活 + 置 key 再聚焦
                    // （acceptsFirstMouse 已为 true，首击即可到达这里）
                    .onTapGesture {
                        onRequestKeyboard?()
                        newTaskFieldFocused = true
                    }

                Button { hasDueDate.toggle() } label: {
                    Image(systemName: hasDueDate ? "calendar.badge.clock" : "calendar")
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasDueDate ? Color.orange : Color.secondary)
                .help("设置截止日期")

                Menu {
                    ForEach([TaskStatus.today, .doing, .waiting, .backlog], id: \.self) { status in
                        Button(status.displayName) { newStatus = status }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(newStatus.displayName)
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                if !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("添加", action: addTask)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if hasDueDate {
                HStack {
                    Text("截止")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: $newDueDate, displayedComponents: .date)
                        .labelsHidden()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func addTask() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        viewModel.addTask(
            title: title,
            status: newStatus,
            dueDate: hasDueDate ? newDueDate : nil,
            waitingOn: nil
        )
        newTitle = ""
        hasDueDate = false
        newStatus = .today
        newTaskFieldFocused = true
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
    }

    // MARK: - Brain Dump 输入与确认流

    private var brainDumpSection: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { brainDumpOpen.toggle() }
                if brainDumpOpen {
                    onRequestKeyboard?()
                    brainDumpFieldFocused = true
                } else {
                    brainDumpFieldFocused = false
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                    Text("倒一下脑子里的事…（自动整理）")
                        .font(.caption)
                    Spacer()
                    Image(systemName: brainDumpOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if brainDumpOpen {
                TextField("例如：明天跟进 PRG 的 API key，等 Peter 回复…", text: $brainDumpText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(2...4)
                    .focused($brainDumpFieldFocused)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { onRequestKeyboard?() }
                HStack {
                    Spacer()
                    Button("整理") { submitBrainDump() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .disabled(brainDumpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private func submitBrainDump() {
        viewModel.runBrainDump(brainDumpText)
        brainDumpText = ""
        withAnimation(.easeInOut(duration: 0.15)) { brainDumpOpen = false }
    }

    private var proposalsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("提案")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Text("\(viewModel.proposals.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("全部确认") { viewModel.confirmAllProposals() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            ForEach(viewModel.proposals) { proposal in
                ProposalCardView(
                    proposal: proposalBinding(proposal),
                    onConfirm: { viewModel.confirmProposal(proposal) },
                    onDiscard: { viewModel.discardProposal(proposal) },
                    onRequestKeyboard: onRequestKeyboard,
                    onFocusChange: { focused in
                        if focused {
                            focusedProposalIDs.insert(proposal.id)
                        } else {
                            focusedProposalIDs.remove(proposal.id)
                        }
                    }
                )
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func proposalBinding(_ proposal: TaskProposal) -> Binding<TaskProposal> {
        Binding(
            get: { viewModel.proposals.first(where: { $0.id == proposal.id }) ?? proposal },
            set: { viewModel.updateProposal($0) }
        )
    }

    // MARK: - 分区

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            if hasVisibleTasks {
                // 横向三列看板（对齐概念稿 TODAY | DOING | WAITING），整列都是拖放目标
                HStack(alignment: .top, spacing: 8) {
                    column(.today)
                    column(.doing)
                    column(.waiting)
                }
                backlogSection
                if !viewModel.tasks(in: .done).isEmpty {
                    doneSection
                }
            } else {
                // 空看板展开态：安静的占位，引导用上方输入框添加第一条
                Text("无任务，在上方输入第一条")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var hasVisibleTasks: Bool {
        viewModel.tasks.contains { $0.status != .done }
    }

    private func column(_ status: TaskStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(status)
            ForEach(viewModel.tasks(in: status)) { task in
                taskRow(task)
            }
            if viewModel.tasks(in: status).isEmpty {
                Text("拖任务到这里")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            // 空列也保持完整拖放面积（HStack 内各列等高，由最高列撑开）
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(4)
        .background(
            dropTargetSection == status ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
        // 点空白处取消选中（Finder 式）
        .onTapGesture { selectedTaskID = nil }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items, to: status)
        } isTargeted: { targeted in
            dropTargetSection = targeted ? status : nil
        }
    }

    /// 卡片拖入分区 = 改状态；跨区拖动与菜单改状态走同一入口（含 waiting_since 等字段维护）。
    private func handleDrop(_ items: [String], to status: TaskStatus) -> Bool {
        guard let first = items.first, let id = Int64(first),
              let task = viewModel.tasks.first(where: { $0.id == id })
        else { return false }
        viewModel.setStatus(task, to: status)
        return true
    }

    private var backlogSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.tasks(in: .backlog)) { task in
                    taskRow(task)
                }
            }
        } label: {
            sectionHeader(.backlog)
        }
        .tint(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            dropTargetSection == .backlog ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items, to: .backlog)
        } isTargeted: { targeted in
            dropTargetSection = targeted ? .backlog : nil
        }
    }

    // MARK: - 已完成分区

    /// 已完成任务：默认折叠，点状态图标可恢复回 today；头部提供"清空"（带确认）。
    /// 按完成时间倒序，最近完成的在最上。
    private var doneSection: some View {
        let doneTasks = viewModel.tasks(in: .done)
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(doneTasks) { task in
                    taskRow(task)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: glyph(for: .done))
                    .font(.system(size: 9))
                    .foregroundStyle(accent(for: .done))
                Text("DONE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Text("\(doneTasks.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button { showClearDoneConfirm = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                        Text("清空")
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("清空已完成任务")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .tint(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            dropTargetSection == .done ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items, to: .done)
        } isTargeted: { targeted in
            dropTargetSection = targeted ? .done : nil
        }
        .alert("清空已完成任务？", isPresented: $showClearDoneConfirm) {
            Button("清空 \(doneTasks.count) 条", role: .destructive) { viewModel.clearDone() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从看板和数据库中删除所有已完成任务，不可恢复。")
        }
    }

    private func sectionHeader(_ status: TaskStatus) -> some View {
        HStack(spacing: 5) {
            Image(systemName: glyph(for: status))
                .font(.system(size: 9))
                .foregroundStyle(accent(for: status))
            Text(status.displayName.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Text("\(viewModel.tasks(in: status).count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    // MARK: - 任务行

    /// 卡片可拖拽跨区改状态；重命名编辑中禁用拖拽，避免劫持文本选择。
    @ViewBuilder
    private func taskRow(_ task: Task) -> some View {
        if editingTaskID == task.id {
            taskRowContent(task)
        } else {
            taskRowContent(task)
                .draggable(task.id.map(String.init) ?? "")
        }
    }

    private func taskRowContent(_ task: Task) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            mainRow(task)
            if editingDueTaskID == task.id {
                // 行内截止日期编辑（⋯ 菜单「选择日期…」触发）
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    DatePicker("", selection: dueBinding(for: task), displayedComponents: .date)
                        .labelsHidden()
                        .controlSize(.small)
                    if task.dueDate != nil {
                        Button("清除") {
                            viewModel.setDueDate(task, to: nil)
                            editingDueTaskID = nil
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    Button("完成") { editingDueTaskID = nil }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.leading, 30)
                .padding(.top, 2)
            }
            subtaskArea(task)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            selectedTaskID == task.id ? Color.accentColor.opacity(0.12)
                : hoveredTaskID == task.id ? Color.primary.opacity(0.06) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hoveredTaskID = $0 ? task.id : nil }
    }

    /// 进入标题编辑（先激活 + 置 key，输入框 onAppear 时聚焦才有效）。
    private func startEditing(_ task: Task) {
        onRequestKeyboard?()
        editFieldFocused = false
        editText = task.title
        editingTaskID = task.id
    }

    /// 行内日期选择器的绑定：未设过截止的卡默认从今天起选。
    private func dueBinding(for task: Task) -> Binding<Date> {
        Binding(
            get: { task.dueDate ?? Date() },
            set: { viewModel.setDueDate(task, to: $0) }
        )
    }

    private func mainRow(_ task: Task) -> some View {
        HStack(spacing: 8) {
            // 状态字形不可点击（点击完成太容易误触）；外圈细环 = 天数进度（见 timeRing）
            statusGlyphWithRing(task)

            VStack(alignment: .leading, spacing: 2) {
                if editingTaskID == task.id {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain)
                        .font(.callout.weight(.medium))
                        .focused($editFieldFocused)
                        .onAppear { editFieldFocused = true }
                        .onSubmit {
                            viewModel.rename(task, to: editText)
                            editFieldFocused = false
                            editingTaskID = nil
                        }
                        .onExitCommand {
                            editFieldFocused = false
                            editingTaskID = nil
                        }
                } else {
                    Text(task.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(expandedText == expandKey(task, .title) ? nil : 2)
                        .modifier(HoverExpandText(key: expandKey(task, .title), expanded: $expandedText))
                }

                if editingNoteTaskID == task.id {
                    TextField("说明…", text: $noteText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .lineLimit(2...5)
                        .focused($noteFieldFocused)
                        .onAppear { noteFieldFocused = true }
                        .onSubmit {
                            viewModel.setNote(task, noteText)
                            noteFieldFocused = false
                            editingNoteTaskID = nil
                        }
                        .onExitCommand {
                            noteFieldFocused = false
                            editingNoteTaskID = nil
                        }
                        // 失焦即保存（多行模式下回车是换行，不再有 onSubmit 兜底）
                        .onChange(of: noteFieldFocused) { _, focused in
                            if !focused, editingNoteTaskID == task.id {
                                viewModel.setNote(task, noteText)
                                editingNoteTaskID = nil
                            }
                        }
                } else if let note = task.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(expandedText == expandKey(task, .note) ? 8 : 2)
                        .modifier(HoverExpandText(key: expandKey(task, .note), expanded: $expandedText))
                }
            }

            Spacer(minLength: 4)
            badges(for: task)

            Menu {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Button {
                        viewModel.setStatus(task, to: status)
                    } label: {
                        if status == task.status {
                            Label(status.displayName, systemImage: "checkmark")
                        } else {
                            Text(status.displayName)
                        }
                    }
                }
                Divider()
                Menu("截止时间…") {
                    Button("今天") { viewModel.setDueDate(task, to: Date()) }
                    Button("明天") { viewModel.setDueDate(task, to: Date().addingTimeInterval(86400)) }
                    Button("一周后") { viewModel.setDueDate(task, to: Date().addingTimeInterval(7 * 86400)) }
                    Divider()
                    Button("选择日期…") { editingDueTaskID = task.id }
                    if task.dueDate != nil {
                        Button("清除截止时间") { viewModel.setDueDate(task, to: nil) }
                    }
                }
                Button(task.note?.isEmpty == false ? "编辑说明" : "添加说明") {
                    onRequestKeyboard?()
                    noteFieldFocused = false
                    noteText = task.note ?? ""
                    editingNoteTaskID = task.id
                }
                Button("添加子任务") {
                    onRequestKeyboard?()
                    subtaskFieldFocused = false
                    subtaskText = ""
                    addingSubtaskTo = task.id
                }
                Divider()
                Button("删除", role: .destructive) {
                    if editingTaskID == task.id { editFieldFocused = false; editingTaskID = nil }
                    if editingNoteTaskID == task.id { noteFieldFocused = false; editingNoteTaskID = nil }
                    if addingSubtaskTo == task.id { subtaskFieldFocused = false; addingSubtaskTo = nil }
                    if editingDueTaskID == task.id { editingDueTaskID = nil }
                    viewModel.delete(task)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hoveredTaskID == task.id ? 1 : 0)
            .allowsHitTesting(hoveredTaskID == task.id)
        }
        .contentShape(Rectangle())
        // Finder 式重命名：单击选中卡片，再单击已选中的卡片进入编辑（快速双击同样生效）
        .onTapGesture {
            guard editingTaskID != task.id else { return }
            if selectedTaskID == task.id {
                startEditing(task)
            } else {
                selectedTaskID = task.id
            }
        }
    }

    // MARK: - Smart Cleanup 提案（M4）

    /// 清理结果区：重复合并 / 停滞处置 / 项目成组提案卡片，全部需用户确认才落库。
    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(.purple)
                Text("智能清理")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            ForEach(viewModel.cleanupProposals) { proposal in
                cleanupCard(proposal)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func cleanupCard(_ proposal: CleanupProposal) -> some View {
        switch proposal.kind {
        case .duplicate(let pair):
            duplicateCard(proposal, pair: pair)
        case .stagnant(let item):
            stagnantCard(proposal, item: item)
        case .project(_, let titles):
            projectCard(proposal, titles: titles)
        }
    }

    private func duplicateCard(_ proposal: CleanupProposal, pair: DuplicatePair) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.purple)
                Text("疑似重复")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(pair.candidate.firstTitle)
                .font(.callout.weight(.medium))
            Text(pair.candidate.secondTitle)
                .font(.callout.weight(.medium))
            Text(pair.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("保留前者") { viewModel.resolveDuplicate(proposal, keepFirst: true) }
                Button("保留后者") { viewModel.resolveDuplicate(proposal, keepFirst: false) }
                Spacer()
                Button("不是重复") { viewModel.dismissCleanup(proposal) }
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func stagnantCard(_ proposal: CleanupProposal, item: StagnantTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.taskTitle)
                .font(.callout.weight(.medium))
            Text(item.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("推进") { viewModel.resolveStagnant(proposal, action: .promote) }
                if item.kind != .backlogStale {
                    Button("降级 Backlog") { viewModel.resolveStagnant(proposal, action: .demote) }
                }
                Button("删除") { viewModel.resolveStagnant(proposal, action: .delete) }
                    .foregroundStyle(.red)
                Spacer()
                Button("忽略") { viewModel.dismissCleanup(proposal) }
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func projectCard(_ proposal: CleanupProposal, titles: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("这些任务看起来属于同一项目：")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(titles, id: \.self) { title in
                Text("· \(title)")
                    .font(.caption)
            }
            HStack(spacing: 10) {
                TextField("项目名", text: projectNameBinding(for: proposal))
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.medium))
                    .focused($cleanupNameFocused)
                    .onTapGesture { onRequestKeyboard?() }
                Spacer()
                Button("建项目") { viewModel.confirmProject(proposal) }
                Button("忽略") { viewModel.dismissCleanup(proposal) }
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 项目名就地编辑：写回 viewModel，确认时以最新状态为准
    private func projectNameBinding(for proposal: CleanupProposal) -> Binding<String> {
        Binding(
            get: { proposal.projectName },
            set: {
                var updated = proposal
                updated.projectName = $0
                viewModel.updateCleanupProposal(updated)
            }
        )
    }

    // MARK: - 子任务

    /// 父卡下挂的子任务列表 + 行内添加输入框。子任务不参与看板列/Focus，完成只做划线、不消失。
    @ViewBuilder
    private func subtaskArea(_ task: Task) -> some View {
        let subs = viewModel.subtasks(of: task)
        if !subs.isEmpty || addingSubtaskTo == task.id {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(subs) { subtask in
                    subtaskRow(subtask)
                }
                if addingSubtaskTo == task.id {
                    TextField("子任务…", text: $subtaskText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .focused($subtaskFieldFocused)
                        .onAppear { subtaskFieldFocused = true }
                        .onSubmit {
                            viewModel.addSubtask(to: task, title: subtaskText)
                            subtaskFieldFocused = false
                            addingSubtaskTo = nil
                        }
                        .onExitCommand {
                            subtaskFieldFocused = false
                            addingSubtaskTo = nil
                        }
                }
            }
            .padding(.leading, 26)
            .padding(.top, 2)
        }
    }

    private func subtaskRow(_ subtask: Task) -> some View {
        HStack(spacing: 6) {
            // 子任务完成 = 原地划线不消失（主卡误触消失的教训）；再点恢复
            Button { viewModel.toggleDone(subtask) } label: {
                Image(systemName: subtask.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(subtask.status == .done ? Color.green : Color.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(subtask.title)
                .font(.caption)
                .foregroundStyle(subtask.status == .done ? .tertiary : .secondary)
                .strikethrough(subtask.status == .done)
                .lineLimit(expandedText == expandKey(subtask, .subtask) ? 6 : 1)
                .modifier(HoverExpandText(key: expandKey(subtask, .subtask), expanded: $expandedText))

            Spacer(minLength: 2)

            Menu {
                Button("删除", role: .destructive) { viewModel.delete(subtask) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func badges(for task: Task) -> some View {
        let progress = viewModel.subtaskProgress(of: task)
        if let projectId = task.projectId, let name = viewModel.projectNames[projectId] {
            badge(name, color: .purple)
        }
        if progress.total > 0 {
            badge("\(progress.done)/\(progress.total)", color: progress.done == progress.total ? .green : .secondary)
        }
        // 天数不写文字，由状态字形外的圆弧表达（见 timeRing）；这里只保留"等谁"
        if task.status == .waiting, let waitingOn = task.waitingOn, !waitingOn.isEmpty {
            badge("等 \(waitingOn)", color: .orange)
        }
    }

    /// 卡片的"天数环"：环绕状态字形的细圆弧，弧长随时间**增长**。
    /// 有截止日期的卡按 创建→截止 跨度倒计时（灰 = 从容，橙 = 进入临近窗口，红满环 = 已逾期）；
    /// 等待中的卡按"等待超时"设置计时（橙色弧）；没设时间的卡走"年龄环"：每 7 天一圈，
    /// 长满换色继续画（灰 → 蓝 → 橙 → 红），上一圈以浅色留底，28 天后红满环封顶。
    /// underlay = 上一圈的颜色（以浅色整圈留底），无则 nil。
    /// marker = 环顶警报球：已逾期 → 红；waiting/doing/backlog 超过各自停滞阈值（与建议区同套设置）→ 橙；未越线 nil。
    private func timeRing(for task: Task) -> (progress: Double, color: Color, underlay: Color?, marker: Color?)? {
        guard task.status != .done else { return nil }
        let now = Date()
        if let due = task.dueDate {
            let days = dayDiff(from: now, to: due)
            if days < 0 { return (1, .red, nil, .red) }
            // 倒计时进度 = 已消耗的时间占这张卡 创建→截止 总跨度的比例（防除零至少 1 小时）
            let total = max(due.timeIntervalSince(task.createdAt), 3600)
            let elapsed = now.timeIntervalSince(task.createdAt)
            let nearDue = days <= viewModel.settings.dueApproachingDays
            // 满环留给"已逾期"：未到截止最多 95%；临近的卡给个弧长下限保证可读
            let progress = nearDue ? min(0.95, max(0.3, elapsed / total)) : min(0.95, max(0.04, elapsed / total))
            return (progress, nearDue ? .orange : .secondary, nil, nil)
        }
        if task.status == .waiting, let since = task.waitingSince {
            let days = dayDiff(from: since, to: now)
            if days > 0 {
                let overdue = days >= viewModel.settings.waitingTooLongDays
                return (min(1, Double(days) / Double(viewModel.settings.waitingTooLongDays)), .orange, nil, overdue ? .orange : nil)
            }
        }
        // 年龄环：每 7 天一圈，长满一圈换色在原圈上继续画；上一圈浅色留底
        let age = now.timeIntervalSince(task.createdAt)
        let lapLength = 7 * 86400.0
        let lap = Int(age / lapLength)
        let lapColors: [Color] = [.secondary, .blue, .orange, .red]
        let lapIndex = min(lap, lapColors.count - 1)
        let progress = lap >= lapColors.count ? 1 : max(0.04, age.truncatingRemainder(dividingBy: lapLength) / lapLength)
        // doing/backlog 停滞阈值（与建议区、智能清理同一套设置）
        var marker: Color?
        let staleDays = dayDiff(from: task.updatedAt, to: now)
        if task.status == .doing, staleDays >= viewModel.settings.doingTooLongDays {
            marker = .orange
        } else if task.status == .backlog, staleDays >= viewModel.settings.backlogStaleDays {
            marker = .orange
        }
        return (progress, lapColors[lapIndex], lapIndex > 0 ? lapColors[lapIndex - 1] : nil, marker)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func dayDiff(from a: Date, to b: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: a),
            to: calendar.startOfDay(for: b)
        ).day ?? 0
    }
}

// MARK: - 尺寸测量（desktop 模式自适应窗口高度）

private struct ChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SectionsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


// MARK: - 状态字形与配色（BoardView 与提案卡片共用）

private func statusGlyph(_ status: TaskStatus) -> String {
    switch status {
    // 虚线圆 = 未开始：避免方框带来的"可点 checkbox"错觉（实际不可点击）
    case .backlog, .today: "circle.dashed"
    case .doing: "circle.fill"
    case .waiting: "pause.circle"
    case .done: "checkmark.circle.fill"
    }
}

private func statusAccent(_ status: TaskStatus) -> Color {
    switch status {
    case .doing: .blue
    case .waiting: .orange
    case .done: .green
    case .backlog, .today: .secondary
    }
}

// MARK: - Brain Dump 提案卡片（确认流，M4 复用）

/// 单条 AI 提案：标题就地编辑、状态字形点击循环、日期/等待对象 chip、确认/丢弃。
private struct ProposalCardView: View {
    @Binding var proposal: TaskProposal
    let onConfirm: () -> Void
    let onDiscard: () -> Void
    let onRequestKeyboard: (@MainActor () -> Void)?
    /// 卡片内任一输入框的焦点变化（供外层并入"输入中"抑制判定）
    let onFocusChange: (@MainActor (Bool) -> Void)?

    @State private var editingDue = false
    @FocusState private var textFieldFocused: Bool

    private static let statusCycle: [TaskStatus] = [.today, .doing, .waiting, .backlog]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { cycleStatus() } label: {
                    Image(systemName: statusGlyph(proposal.status))
                        .font(.system(size: 14))
                        .foregroundStyle(statusAccent(proposal.status))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("点击切换状态：\(proposal.status.displayName)")

                TextField("任务标题", text: $proposal.title)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.medium))
                    .focused($textFieldFocused)
                    .onTapGesture { onRequestKeyboard?() }

                Spacer(minLength: 4)
                Button("丢弃", action: onDiscard)
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Button("确认", action: onConfirm)
                    .font(.caption)
                    .buttonStyle(.borderless)
            }

            HStack(spacing: 6) {
                dueChip
                if proposal.status == .waiting || proposal.waitingOn != nil {
                    waitingChip
                }
                Spacer()
            }

            if editingDue {
                HStack(spacing: 8) {
                    DatePicker("", selection: dueBinding, displayedComponents: .date)
                        .labelsHidden()
                        .controlSize(.small)
                    Button("清除") {
                        proposal.dueDate = nil
                        proposal.dueText = nil
                        editingDue = false
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 24)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onChange(of: textFieldFocused) { _, focused in onFocusChange?(focused) }
    }

    private var dueChip: some View {
        Button { editingDue.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "calendar")
                    .font(.caption2)
                if let dueDate = proposal.dueDate {
                    Text(dueDate.formatted(.dateTime.month(.wide).day().locale(Locale(identifier: "zh_CN"))))
                } else if let dueText = proposal.dueText {
                    // 有时间表述但规则解析不了：原文展示，点击可手动指定
                    Text(dueText)
                } else {
                    Text("无截止")
                }
            }
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(proposal.dueDate != nil ? 0.12 : 0.06))
            .foregroundStyle(proposal.dueDate != nil ? .orange : .secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var waitingChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "pause.circle")
                .font(.caption2)
            TextField("等待谁/什么", text: waitingOnBinding)
                .textFieldStyle(.plain)
                .font(.caption2)
                .frame(maxWidth: 130)
                .focused($textFieldFocused)
                .onTapGesture { onRequestKeyboard?() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.orange.opacity(0.12))
        .foregroundStyle(.orange)
        .clipShape(Capsule())
    }

    private var dueBinding: Binding<Date> {
        Binding(
            get: { proposal.dueDate ?? Date() },
            set: { proposal.dueDate = $0; proposal.dueText = nil }
        )
    }

    private var waitingOnBinding: Binding<String> {
        Binding(
            get: { proposal.waitingOn ?? "" },
            set: { proposal.waitingOn = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private func cycleStatus() {
        guard let index = Self.statusCycle.firstIndex(of: proposal.status) else {
            proposal.status = .today
            return
        }
        proposal.status = Self.statusCycle[(index + 1) % Self.statusCycle.count]
    }
}

// MARK: - 截断文本的悬停展开

/// 标识卡片里一段可被截断的文本：任务 id + 种类
private struct ExpandedTextKey: Equatable {
    enum Kind { case title, note, subtask }
    let taskID: Int64
    let kind: Kind
}

/// 悬停 0.5s 后把被截断的文本原地展开（解除 lineLimit），移开恢复。
/// 桌面挂板/Peek 都是 nonactivating panel：悬停时 App 不激活，系统 tooltip（.help）不显示，
/// 故用原地展开替代。未截断的文本展开后无视觉变化，等于天然只作用于"真的被截断"的文本。
private struct HoverExpandText: ViewModifier {
    let key: ExpandedTextKey
    @Binding var expanded: ExpandedTextKey?
    @State private var pending: DispatchWorkItem?

    private static let delay: TimeInterval = 0.5

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                pending?.cancel()
                pending = nil
                if hovering {
                    let work = DispatchWorkItem { expanded = key }
                    pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
                } else if expanded == key {
                    expanded = nil
                }
            }
            .onDisappear {
                pending?.cancel()
                pending = nil
                if expanded == key { expanded = nil }
            }
    }
}
