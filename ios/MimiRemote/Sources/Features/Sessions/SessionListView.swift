import SwiftUI

enum SessionIndexRowStyle {
    case sidebar
    case library
}

enum SessionLibraryStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case needsAttention
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部状态"
        case .active: return "运行中"
        case .needsAttention: return "需要处理"
        case .completed: return "已完成"
        }
    }

    func includes(_ session: AgentSession) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return session.isRunning
        case .needsAttention:
            return session.pendingApproval != nil ||
                session.pendingUserInput != nil ||
                session.status == SessionStatus.failed.rawValue
        case .completed:
            return !session.isRunning && session.status != SessionStatus.failed.rawValue
        }
    }
}

/// 完整会话库只展示轻量索引；消息历史仍在用户选中会话后按需加载。
struct SessionListView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedWorkspaceID = "all"
    @State private var selectedStatus: SessionLibraryStatusFilter = .all

    var onNewSession: (() -> Void)?
    var onSelectSession: ((AgentSession) -> Void)?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        List {
            if visibleSessions.isEmpty && !sessionStore.isLoading {
                if sessionStore.isSessionSearchActive && sessionStore.isSearchingRemoteSessionResults {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在搜索历史会话…")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(tokens.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .accessibilityIdentifier("sessions.search.initialLoading")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ContentUnavailableView {
                        Label("没有匹配的会话", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text(sessionStore.isSessionSearchActive ? "换个关键词或筛选条件试试。" : "从一个工作区创建新会话后会显示在这里。")
                    } actions: {
                        Button("新会话", action: presentNewSession)
                            .buttonStyle(.borderedProminent)
                            .tint(tokens.primaryAction)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else {
                ForEach(visibleSessions) { session in
                    SessionIndexRow(
                        session: session,
                        foregroundActivity: sessionStore.foregroundActivity(for: session.id),
                        isSelected: session.id == sessionStore.selectedSessionID,
                        isPinned: sessionStore.isSessionPinned(session.id),
                        isArchived: sessionStore.isSessionArchived(session.id),
                        reminder: sessionStore.sessionReminder(for: session.id),
                        isObserving: sessionStore.isSessionObserving(session),
                        style: .library,
                        searchSnippet: sessionStore.sessionSearchSnippet(for: session.id)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { select(session) }
                    .sessionRowActions(session)
                    .listRowInsets(.init(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }

            // Gateway 过滤后当前页可能没有可见结果但仍给出 nextCursor，入口必须独立于空态展示。
            if sessionStore.isSessionSearchActive && sessionStore.sessionSearchHasMore {
                Button {
                    Task { await sessionStore.loadMoreSessionSearchResults() }
                } label: {
                    HStack(spacing: 8) {
                        if sessionStore.isLoadingMoreSessionSearchResults {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text(sessionStore.isLoadingMoreSessionSearchResults ? "正在继续搜索…" : "继续搜索")
                    }
                    .font(themeStore.uiFont(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.secondaryText)
                .disabled(sessionStore.isLoadingMoreSessionSearchResults)
                .accessibilityIdentifier("sessions.search.loadMore")
                .listRowInsets(.init(top: 4, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle("会话")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $sessionStore.sessionSearchQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索会话")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                filterMenu(tokens: tokens)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                sessionListToolbarButton(
                    systemImage: "arrow.clockwise",
                    accessibilityLabel: "刷新会话库",
                    tokens: tokens
                ) {
                    Task { await sessionStore.refreshSessionLibraryIndex() }
                }

                sessionListToolbarButton(
                    systemImage: "plus",
                    accessibilityLabel: "新建会话",
                    tokens: tokens,
                    isPrimary: true,
                    action: presentNewSession
                )
                .accessibilityIdentifier("sessions.newSession")
            }
        }
        .task {
            await sessionStore.refreshSessionLibraryIndex()
        }
    }

    /// 列表右上角保留新建入口，所有工具按钮共用单层圆形样式，避免 glass 自动样式产生双圆环。
    private func sessionListToolbarButton(
        systemImage: String,
        accessibilityLabel: String,
        tokens: ThemeTokens,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(
                    isPrimary ? tokens.primaryAction : tokens.surface.opacity(0.72),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .stroke(isPrimary ? tokens.primaryAction.opacity(0.72) : tokens.border.opacity(0.62), lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPrimary ? Color.white : tokens.secondaryText)
        .accessibilityLabel(accessibilityLabel)
    }

    private var visibleSessions: [AgentSession] {
        sessionStore.sessionLibrarySessions.filter { session in
            (selectedWorkspaceID == "all" || session.projectID == selectedWorkspaceID) &&
                selectedStatus.includes(session)
        }
    }

    private func filterMenu(tokens: ThemeTokens) -> some View {
        Menu {
            Section("工作区") {
                Button {
                    selectedWorkspaceID = "all"
                } label: {
                    Label("全部工作区", systemImage: selectedWorkspaceID == "all" ? "checkmark" : "folder")
                }
                ForEach(sessionStore.sidebarProjects) { project in
                    Button {
                        selectedWorkspaceID = project.id
                    } label: {
                        Label(project.name, systemImage: selectedWorkspaceID == project.id ? "checkmark" : "folder")
                    }
                }
            }
            Section("状态") {
                ForEach(SessionLibraryStatusFilter.allCases) { filter in
                    Button {
                        selectedStatus = filter
                    } label: {
                        Label(filter.title, systemImage: selectedStatus == filter ? "checkmark" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
        } label: {
            Label(filterTitle, systemImage: "line.3.horizontal.decrease")
                .foregroundStyle(tokens.secondaryText)
        }
        .accessibilityLabel("筛选会话")
    }

    private var filterTitle: String {
        if selectedWorkspaceID != "all",
           let project = sessionStore.sidebarProjects.first(where: { $0.id == selectedWorkspaceID }) {
            return project.name
        }
        return selectedStatus == .all ? "筛选" : selectedStatus.title
    }

    private func presentNewSession() {
        if let onNewSession {
            onNewSession()
        } else {
            Task { await sessionStore.startNewSession() }
        }
    }

    private func select(_ session: AgentSession) {
        if let onSelectSession {
            onSelectSession(session)
        } else {
            Task { await sessionStore.selectSession(session) }
        }
    }
}

struct SessionIndexRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let session: AgentSession
    let foregroundActivity: SessionForegroundActivity?
    let isSelected: Bool
    let isPinned: Bool
    let isArchived: Bool
    let reminder: SessionReminder?
    let isObserving: Bool
    let style: SessionIndexRowStyle
    var searchSnippet: String? = nil

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: style == .sidebar ? 3 : 7) {
            HStack(alignment: .center, spacing: 7) {
                if style == .library {
                    Circle()
                        .fill(statusColor(tokens: tokens))
                        .frame(width: 7, height: 7)
                }

                Text(session.title)
                    .font(themeStore.uiFont(size: style == .sidebar ? 14 : 16, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(style == .sidebar ? 1 : 2)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if status.showsSpinner && style == .library {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(statusColor(tokens: tokens))
                } else if style == .library {
                    Text(timestampText)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.tertiaryText)
                        .fixedSize()
                }
            }

            HStack(spacing: 6) {
                if isPinned { Image(systemName: "pin.fill") }
                if isArchived { Image(systemName: "archivebox.fill") }
                if reminder != nil { Image(systemName: "bell.fill").foregroundStyle(tokens.warning) }

                Text(session.project.isEmpty ? session.dir : session.project)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 3) {
                    Circle()
                        .fill(statusColor(tokens: tokens))
                        .frame(width: style == .sidebar ? 4 : 5, height: style == .sidebar ? 4 : 5)
                    Text(status.title)
                        .font(themeStore.uiFont(size: style == .sidebar ? 9 : 11, weight: .medium))
                        .foregroundStyle(statusColor(tokens: tokens))
                }

                if style == .sidebar {
                    Text("·")
                    Text(timestampText)
                }
            }
            .font(themeStore.uiFont(size: style == .sidebar ? 10 : 12, weight: .regular))
            .foregroundStyle(tokens.tertiaryText)
            .lineLimit(1)

            if style == .library,
               let searchSnippet,
               !searchSnippet.isEmpty {
                Text(searchSnippet)
                    .font(themeStore.uiFont(size: 12, weight: .regular))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, style == .sidebar ? 10 : 14)
        .padding(.vertical, style == .sidebar ? 6 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? tokens.selectionFill : (style == .library ? tokens.surface.opacity(0.58) : Color.clear), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(tokens.primaryAction)
                    .frame(width: 3)
                    .padding(.vertical, 9)
                    .padding(.leading, 2)
            }
        }
        .overlay {
            if style == .library {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? tokens.primaryAction.opacity(0.34) : tokens.border.opacity(0.58), lineWidth: 1)
            }
        }
    }

    private var status: AgentSessionDisplayStatus {
        if isObserving {
            return AgentSessionDisplayStatus(title: "观察中", systemImage: "eye", tone: .neutral, showsSpinner: false)
        }
        return session.displayStatus(foregroundActivity: foregroundActivity)
    }

    private func statusColor(tokens: ThemeTokens) -> Color {
        switch status.tone {
        case .active: return tokens.primaryAction
        case .warning: return tokens.warning
        case .danger: return .red
        case .complete, .neutral: return tokens.tertiaryText
        }
    }

    private var timestampText: String {
        guard let date = session.updatedAt ?? session.createdAt else { return "" }
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}

private struct SessionRowActions: ViewModifier {
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var renameTarget: SessionRenameTarget?
    @State private var reviewPresentation: SessionReviewPresentation?
    let session: AgentSession

    func body(content: Content) -> some View {
        let isPinned = sessionStore.isSessionPinned(session.id)
        let isArchived = sessionStore.isSessionArchived(session.id)
        let reminder = sessionStore.sessionReminder(for: session.id)

        content.contextMenu {
            if sessionStore.isSessionObserving(session) {
                Button {
                    sessionStore.takeOverSession(session)
                } label: {
                    Label("接管到 iPad", systemImage: "hand.raised.fill")
                }
            }

            Button {
                sessionStore.toggleSessionPinned(session)
            } label: {
                Label(isPinned ? "取消置顶" : "置顶", systemImage: isPinned ? "pin.slash" : "pin")
            }

            if sessionStore.supportsCodexThreadManagement(session) {
                Divider()

                Button {
                    renameTarget = SessionRenameTarget(session: session)
                } label: {
                    Label("重命名", systemImage: "pencil")
                }

                Button {
                    Task { await sessionStore.compactSessionContext(session) }
                } label: {
                    Label("压缩上下文", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .disabled(session.isRunning)

                Button {
                    reviewPresentation = SessionReviewPresentation(session: session)
                } label: {
                    Label("开始代码审查", systemImage: "checklist.checked")
                }
                .disabled(session.isRunning)
            }

            Button {
                Task { await sessionStore.handoffSessionToWorktree(session) }
            } label: {
                Label("转到新 Git Worktree", systemImage: "arrow.triangle.branch")
            }
            .disabled(session.isRunning || sessionStore.isCreatingWorktree)

            Menu {
                Button("30 分钟后") { Task { await sessionStore.scheduleSessionReminder(session, after: 30 * 60) } }
                Button("2 小时后") { Task { await sessionStore.scheduleSessionReminder(session, after: 2 * 60 * 60) } }
                Button("明天") { Task { await sessionStore.scheduleSessionReminder(session, after: 24 * 60 * 60) } }
                if reminder != nil {
                    Button("清除提醒", role: .destructive) { sessionStore.clearSessionReminder(session) }
                }
            } label: {
                Label("提醒", systemImage: reminder == nil ? "bell" : "bell.fill")
            }

            Button(role: isArchived ? nil : .destructive) {
                Task { await sessionStore.toggleSessionArchivedRemote(session) }
            } label: {
                Label(isArchived ? "取消归档" : "归档", systemImage: isArchived ? "archivebox.fill" : "archivebox")
            }
        }
        .sheet(item: $renameTarget) { target in
            SessionRenameSheet(session: target.session)
        }
        .sheet(item: $reviewPresentation) { presentation in
            SessionReviewSheet(session: presentation.session)
        }
    }
}

private struct SessionRenameTarget: Identifiable {
    let session: AgentSession
    var id: SessionID { session.id }
}

private struct SessionReviewPresentation: Identifiable {
    let session: AgentSession
    var id: SessionID { session.id }
}

private enum SessionReviewScope: String, CaseIterable, Identifiable {
    case uncommittedChanges
    case baseBranch
    case commit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uncommittedChanges: return "未提交改动"
        case .baseBranch: return "相对基准分支"
        case .commit: return "指定提交"
        }
    }

    var systemImage: String {
        switch self {
        case .uncommittedChanges: return "pencil.and.list.clipboard"
        case .baseBranch: return "arrow.triangle.branch"
        case .commit: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

private struct SessionReviewSheet: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let session: AgentSession
    @State private var scope: SessionReviewScope = .uncommittedChanges
    @State private var baseBranch = ""
    @State private var commitSHA = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Form {
                Section("审查目标") {
                    Picker("目标类型", selection: $scope) {
                        ForEach(SessionReviewScope.allCases) { option in
                            Label(option.title, systemImage: option.systemImage)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }

                switch scope {
                case .uncommittedChanges:
                    Section {
                        Label("审查当前工作区尚未提交的全部改动", systemImage: "info.circle")
                            .foregroundStyle(tokens.secondaryText)
                    }
                case .baseBranch:
                    Section {
                        TextField("例如 main", text: $baseBranch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityIdentifier("sessions.review.baseBranch")
                    } header: {
                        Text("基准分支")
                    } footer: {
                        Text(normalizedBaseBranch.isEmpty ? "请输入非空分支名。" : "将审查当前分支相对 \(normalizedBaseBranch) 的差异。")
                            .foregroundStyle(normalizedBaseBranch.isEmpty ? tokens.warning : tokens.tertiaryText)
                    }
                case .commit:
                    Section {
                        TextField("Commit SHA", text: $commitSHA)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityIdentifier("sessions.review.commit")
                    } header: {
                        Text("提交")
                    } footer: {
                        Text(normalizedCommitSHA.isEmpty ? "请输入非空 Commit SHA。" : "将只审查提交 \(normalizedCommitSHA)。")
                            .foregroundStyle(normalizedCommitSHA.isEmpty ? tokens.warning : tokens.tertiaryText)
                    }
                }

                Section {
                    Label("Review 始终在当前会话内执行，不会创建 detached 会话。", systemImage: "lock.shield")
                        .foregroundStyle(tokens.tertiaryText)
                }

                if let submissionError {
                    Section {
                        Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(tokens.warning)
                    }
                }
            }
            .font(themeStore.uiFont(.body))
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle("开始代码审查")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("开始")
                        }
                    }
                    .disabled(isSubmitting || session.isRunning || normalizedTarget == nil)
                    .accessibilityIdentifier("sessions.review.submit")
                }
            }
        }
        .tint(tokens.primaryAction)
        .interactiveDismissDisabled(isSubmitting)
        .presentationDetents([.medium, .large])
    }

    private var normalizedBaseBranch: String {
        baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedCommitSHA: String {
        commitSHA.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedTarget: CodexAppServerReviewTarget? {
        switch scope {
        case .uncommittedChanges:
            return .uncommittedChanges
        case .baseBranch:
            guard !normalizedBaseBranch.isEmpty else { return nil }
            return .baseBranch(normalizedBaseBranch)
        case .commit:
            guard !normalizedCommitSHA.isEmpty else { return nil }
            return .commit(sha: normalizedCommitSHA)
        }
    }

    private func submit() {
        guard !isSubmitting, !session.isRunning, let target = normalizedTarget else { return }
        isSubmitting = true
        submissionError = nil
        Task {
            let didStart = await sessionStore.startReview(session, target: target)
            isSubmitting = false
            if didStart {
                dismiss()
            } else {
                submissionError = sessionStore.statusMessage ?? "Review 启动失败，请稍后重试。"
            }
        }
    }
}

private struct SessionRenameSheet: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss

    let session: AgentSession
    @State private var name: String
    @State private var isSaving = false

    init(session: AgentSession) {
        self.session = session
        _name = State(initialValue: session.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("会话名称") {
                    TextField("输入名称", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit(save)
                }
            }
            .navigationTitle("重命名会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存", action: save)
                        .disabled(isSaving || normalizedName.isEmpty || normalizedName == session.title)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !isSaving, !normalizedName.isEmpty else { return }
        isSaving = true
        Task {
            let didRename = await sessionStore.renameSession(session, name: normalizedName)
            isSaving = false
            if didRename {
                dismiss()
            }
        }
    }
}

extension View {
    func sessionRowActions(_ session: AgentSession) -> some View {
        modifier(SessionRowActions(session: session))
    }
}
