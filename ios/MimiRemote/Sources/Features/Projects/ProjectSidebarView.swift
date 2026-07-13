import SwiftUI
import QuickLook

struct ProjectSidebarView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isPresentingOpenWorkspace = false
    @State private var isPresentingWorktreeManager = false
    @State private var worktreeManagerRootProjectID = ""
    @State private var worktreeCreateProject: AgentProject?
    var showsSessions = true
    var onProjectSelected: (() -> Void)?
    var onCollapseSidebar: (() -> Void)?
    var onOpenWorkspaceTab: (() -> Void)?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let selectedProjectID = sessionStore.selectedProjectID
        let selectedSessionID = sessionStore.selectedSessionID
        let themeRenderKey = SidebarThemeRenderKey(themeVersion: themeStore.themeVersion, colorScheme: colorScheme)
        let projects = showsSessions ? sessionStore.filteredSessionSidebarProjects : sessionStore.filteredSidebarProjects
        let usesCustomHeader = horizontalSizeClass == .regular || onCollapseSidebar != nil

        Group {
            if usesCustomHeader {
                VStack(spacing: 0) {
                    sidebarHeader(tokens: tokens, projects: projects)
                        .frame(height: regularHeaderHeight)
                    sidebarList(
                        tokens: tokens,
                        selectedProjectID: selectedProjectID,
                        selectedSessionID: selectedSessionID,
                        themeRenderKey: themeRenderKey,
                        projects: projects,
                        showsInlineHeader: false
                    )
                }
            } else {
                sidebarList(
                    tokens: tokens,
                    selectedProjectID: selectedProjectID,
                    selectedSessionID: selectedSessionID,
                    themeRenderKey: themeRenderKey,
                    projects: projects,
                    showsInlineHeader: true
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tokens.sidebarBackground)
        .tint(tokens.accent)
        .overlay(alignment: .trailing) {
            if horizontalSizeClass == .regular {
                Rectangle()
                    .fill(tokens.border.opacity(0.72))
                    .frame(width: 1)
            }
        }
        .sidebarSystemSearchable(
            isEnabled: !usesCustomHeader,
            text: $sessionStore.sessionSearchQuery,
            placement: searchPlacement,
            prompt: Text(showsSessions ? "搜索会话" : "搜索工作区")
        )
        .sheet(isPresented: $isPresentingOpenWorkspace) {
            OpenWorkspaceSheet()
        }
        .sheet(isPresented: $isPresentingWorktreeManager) {
            WorktreeManagerSheet(rootProjectID: worktreeManagerRootProjectID)
        }
        .sheet(item: $worktreeCreateProject) { project in
            CreateWorktreeSheet(project: project)
        }
    }

    private func sidebarList(
        tokens: ThemeTokens,
        selectedProjectID: String?,
        selectedSessionID: SessionID?,
        themeRenderKey: SidebarThemeRenderKey,
        projects: [AgentProject],
        showsInlineHeader: Bool
    ) -> some View {
        List {
            Section {
                if shouldShowSidebarEmptyRow(projects: projects) {
                    sidebarEmptyContent()
                        .padding(.top, showsInlineHeader ? 10 : 12)
                        .padding(.bottom, 8)
                        .sidebarListRow()
                }

                ForEach(projects) { project in
                    let snapshot = sessionStore.sessionListSnapshot(forProjectID: project.id)

                    ProjectRow(
                        project: project,
                        isActiveProject: project.id == selectedProjectID,
                        isSelected: project.id == selectedProjectID && (!showsSessions || selectedSessionID == nil),
                        isExpanded: snapshot.isExpanded,
                        isLoading: snapshot.isLoadingMore,
                        isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                        showsDisclosure: showsSessions,
                        showsSessionActions: showsSessions,
                        claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel,
                        themeRenderKey: themeRenderKey,
                        onToggle: {
                            Task {
                                if showsSessions {
                                    await sessionStore.toggleProjectExpansion(project)
                                } else {
                                    await sessionStore.selectProject(project)
                                    onProjectSelected?()
                                }
                            }
                        },
                        onNewSession: {
                            Task { await sessionStore.startNewSession(in: project) }
                        },
                        onNewClaudeSession: {
                            Task { await sessionStore.startNewSession(in: project, runtimeProvider: "claude") }
                        },
                        onCreateWorktree: {
                            worktreeCreateProject = project
                        },
                        onManageWorktrees: {
                            worktreeManagerRootProjectID = sessionStore.rootProjectID(forProjectID: project.id)
                            isPresentingWorktreeManager = true
                        },
                        onRetry: {
                            Task { await sessionStore.retryWorkspace(project) }
                        },
                        onForget: {
                            sessionStore.forgetWorkspace(project)
                        }
                    )
                    .equatable()
                    .sidebarListRow()

                    if showsSessions && snapshot.isExpanded {
                        ProjectSessionRows(
                            project: project,
                            snapshot: snapshot,
                            selectedSessionID: selectedSessionID,
                            isLoading: sessionStore.isLoading,
                            themeRenderKey: themeRenderKey
                        )
                    }
                }

                // 远端搜索是跨项目分页，只放一个全局入口；0 项目/0 可见命中时也能继续翻页。
                if showsSessions && sessionStore.isSessionSearchActive && sessionStore.sessionSearchHasMore {
                    sidebarSearchLoadMoreRow(tokens: tokens)
                }
            } header: {
                if showsInlineHeader {
                    sidebarCompactHeaderContent(tokens: tokens, projects: projects)
                }
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, showsInlineHeader ? 6 : 0, for: .scrollContent)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(tokens.sidebarBackground)
    }

    private func sidebarSearchLoadMoreRow(tokens: ThemeTokens) -> some View {
        Button {
            Task { await sessionStore.loadMoreSessionSearchResults() }
        } label: {
            HStack(spacing: 7) {
                if sessionStore.isLoadingMoreSessionSearchResults {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.tertiaryText)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                }
                Text(sessionStore.isLoadingMoreSessionSearchResults ? "正在继续搜索…" : "继续搜索")
                    .lineLimit(1)
            }
            .font(themeStore.uiFont(size: 12, weight: .medium))
            .foregroundStyle(tokens.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 30)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sessionStore.isLoadingMoreSessionSearchResults)
        .accessibilityIdentifier("sidebar.sessions.search.loadMore")
        .sidebarListRow()
    }

    private func shouldShowSidebarEmptyRow(projects: [AgentProject]) -> Bool {
        guard projects.isEmpty, !sessionStore.isLoading else {
            return false
        }
        return true
    }

    @ViewBuilder
    private func sidebarEmptyContent() -> some View {
        if showsSessions && sessionStore.isSessionSearchActive && sessionStore.isSearchingRemoteSessionResults {
            SidebarSearchLoadingMessage()
        } else if sessionStore.isSessionSearchActive {
            SidebarEmptyMessage(
                title: showsSessions ? "没有匹配的会话" : "没有匹配的工作区",
                detail: "换个关键词试试。"
            )
        } else if showsSessions {
            SidebarEmptyMessage(
                title: "还没有会话工作区",
                detail: "会话页只显示已加入会话的工作区，去工作区把常用项目加入后，这里会显示对应的历史会话。",
                actionTitle: onOpenWorkspaceTab == nil ? nil : "去工作区",
                actionSystemImage: onOpenWorkspaceTab == nil ? nil : "folder.badge.plus",
                action: onOpenWorkspaceTab
            )
        } else {
            SidebarEmptyMessage(
                title: "没有已打开的工作区",
                detail: "选择已授权的工作目录后，这里会保留最近打开的项目。",
                actionTitle: "打开路径",
                actionSystemImage: "folder.badge.plus"
            ) {
                isPresentingOpenWorkspace = true
            }
        }
    }

    private var regularHeaderHeight: CGFloat {
        showsSessions ? 112 : 104
    }

    private func sidebarHeader(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        regularSidebarHeaderContent(tokens: tokens, projects: projects)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(tokens.sidebarBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tokens.border.opacity(0.42))
                    .frame(height: 1)
            }
    }

    private func regularSidebarHeaderContent(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(showsSessions ? "会话" : "工作区")
                        .font(themeStore.uiFont(size: 13, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                    Text(sidebarHeaderSubtitle(projects: projects))
                        .font(themeStore.uiFont(size: 11))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if shouldShowSidebarHeaderActions(projects: projects) {
                    sidebarHeaderActionGroup(tokens: tokens, projects: projects)
                }
            }

            HStack(spacing: 8) {
                sidebarSearchField(tokens: tokens)
                if showsSessions {
                    sidebarNewSessionMenu(tokens: tokens, projects: projects)
                }
            }
        }
    }

    private func sidebarCompactHeaderContent(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        HStack(spacing: 8) {
            Text(showsSessions ? "会话" : "工作区")
                .font(themeStore.uiFont(size: 12, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
            Spacer()
            if shouldShowSidebarHeaderActions(projects: projects) {
                sidebarHeaderActionGroup(tokens: tokens, projects: projects)
            }
        }
    }

    private func sidebarHeaderActionGroup(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        HStack(spacing: 2) {
            if showsSessions, let onCollapseSidebar {
                sidebarHeaderButton(tokens: tokens, systemImage: "sidebar.left", accessibilityLabel: "收起会话列表") {
                    onCollapseSidebar()
                }
            }
            sidebarHeaderRefresh(tokens: tokens, projects: projects)
            if !showsSessions {
                sidebarHeaderButton(tokens: tokens, systemImage: "folder.badge.plus", accessibilityLabel: "打开路径") {
                    isPresentingOpenWorkspace = true
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(tokens.elevatedSurface.opacity(0.58), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tokens.border.opacity(0.5), lineWidth: 1)
        }
    }

    private func sidebarSearchField(tokens: ThemeTokens) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(themeStore.uiFont(size: 12, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
            TextField(showsSessions ? "搜索会话" : "搜索工作区", text: $sessionStore.sessionSearchQuery)
                .font(themeStore.uiFont(size: 13))
                .foregroundStyle(tokens.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1)
            if sessionStore.isSessionSearchActive {
                Button {
                    sessionStore.sessionSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.tertiaryText)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(tokens.surface.opacity(0.74), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border.opacity(0.52), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func sidebarNewSessionMenu(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        if let project = primarySessionProject(projects: projects) {
            Menu {
                Button {
                    Task { await sessionStore.startNewSession(in: project) }
                } label: {
                    Label("新建 Codex 会话", systemImage: "plus.circle")
                }
                if sessionStore.hasClaudeRuntimeChannel {
                    Button {
                        Task { await sessionStore.startNewSession(in: project, runtimeProvider: "claude") }
                    } label: {
                        Label("新建 Claude Code 会话", systemImage: "sparkles")
                    }
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label("新会话", systemImage: "plus")
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                    Image(systemName: "plus")
                        .frame(width: 34, height: 34)
                        .accessibilityLabel("新会话")
                }
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .background(tokens.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(tokens.accent.opacity(0.26), lineWidth: 1)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("新建会话")
        }
    }

    private func primarySessionProject(projects: [AgentProject]) -> AgentProject? {
        if let selectedProject = sessionStore.selectedProject,
           projects.contains(where: { $0.id == selectedProject.id }) {
            return selectedProject
        }
        return projects.first
    }

    private func sidebarHeaderSubtitle(projects: [AgentProject]) -> String {
        if sessionStore.isSessionSearchActive {
            return projects.isEmpty ? "没有匹配结果" : "\(projects.count) 个匹配结果"
        }
        if showsSessions {
            let configuredCount = sessionStore.sessionWorkspaceSelectionCount
            if projects.count > configuredCount, sessionStore.selectedSessionID != nil {
                return configuredCount == 0 ? "当前会话临时保留" : "\(configuredCount) 个常用 + 当前会话"
            }
            return projects.isEmpty ? "只显示已加入会话的工作区" : "\(projects.count) 个工作区显示在会话里"
        }
        return projects.isEmpty ? "还没有打开的目录" : "\(projects.count) 个工作区"
    }

    private func shouldShowSidebarHeaderActions(projects: [AgentProject]) -> Bool {
        if showsSessions, onCollapseSidebar != nil {
            return true
        }
        if sessionStore.isLoading || shouldShowSidebarRefresh(projects: projects) {
            return true
        }
        return !showsSessions
    }

    @ViewBuilder
    private func sidebarHeaderRefresh(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        if sessionStore.isLoading {
            ProgressView()
                .controlSize(.small)
                .tint(tokens.secondaryText)
                .frame(width: 32, height: 32)
                .accessibilityLabel("正在刷新")
        } else if shouldShowSidebarRefresh(projects: projects) {
            sidebarHeaderButton(tokens: tokens, systemImage: "arrow.clockwise", accessibilityLabel: "刷新") {
                Task { await sessionStore.refreshAll(autoAttach: false) }
            }
        }
    }

    private func shouldShowSidebarRefresh(projects: [AgentProject]) -> Bool {
        !projects.isEmpty || sessionStore.isSessionSearchActive || sessionStore.errorMessage != nil
    }

    private func sidebarHeaderButton(
        tokens: ThemeTokens,
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .accessibilityLabel(accessibilityLabel)
    }

    private var searchPlacement: SearchFieldPlacement {
        // iPhone 没有真正的 sidebar 搜索区，放到导航栏抽屉里才是系统原生的窄屏入口。
        horizontalSizeClass == .compact ? .navigationBarDrawer(displayMode: .automatic) : .automatic
    }
}

private extension View {
    @ViewBuilder
    func sidebarSystemSearchable(
        isEnabled: Bool,
        text: Binding<String>,
        placement: SearchFieldPlacement,
        prompt: Text
    ) -> some View {
        if isEnabled {
            searchable(text: text, placement: placement, prompt: prompt)
        } else {
            // 宽屏侧栏已经有可见的内联搜索框；这里不再叠加系统 searchable，
            // 避免出现两个搜索入口或隐藏搜索状态互相抢焦点。
            self
        }
    }
}

private struct SidebarThemeRenderKey: Equatable {
    let themeVersion: Int
    let colorScheme: ColorScheme
}

private struct SidebarSearchLoadingMessage: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(tokens.tertiaryText)
            Text("正在搜索历史会话…")
                .font(themeStore.uiFont(size: 12, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("sidebar.sessions.search.initialLoading")
    }
}

private struct SidebarEmptyMessage: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let detail: String
    var actionTitle: String?
    var actionSystemImage: String?
    var action: (() -> Void)?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(themeStore.uiFont(size: 12))
                .foregroundStyle(tokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) {
                    if let actionSystemImage {
                        Label(actionTitle, systemImage: actionSystemImage)
                    } else {
                        Text(actionTitle)
                    }
                }
                .font(themeStore.uiFont(size: 12, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(tokens.accent.opacity(0.1), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(tokens.accent.opacity(0.24), lineWidth: 1)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.elevatedSurface.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border.opacity(0.48), lineWidth: 1)
        }
    }
}

struct OpenWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var path = ""
    @State private var isOpening = false
    @State private var localError: String?

    @State private var browsePath: String?
    @State private var browseParentPath: String?
    @State private var browseEntries: [DirectoryEntry] = []
    @State private var browseTruncated = false
    @State private var isBrowsing = false
    @State private var browseError: String?
    @State private var previewURL: URL?
    @State private var previewError: String?
    @State private var previewingPath: String?
    // 快速连点目录时让最后一次请求胜出，避免慢响应把列表回写成旧目录。
    @State private var browseRequestID = 0
    var onOpened: (String) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            Form {
                currentDirectorySection
                childDirectoriesSection

                if let localError {
                    Section {
                        Text(localError)
                            .font(themeStore.uiFont(size: 13))
                            .foregroundStyle(.red)
                    } header: {
                        Text("打开失败")
                    }
                }

                Section {
                    TextField("/Users/me/finance", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await open(path: path) }
                    } label: {
                        Label(isOpening ? "正在打开" : "打开输入的路径", systemImage: "folder.badge.plus")
                    }
                    .disabled(!canOpenTypedPath)
                } header: {
                    Text("手动输入路径")
                } footer: {
                    Text("可直接粘贴开发环境中的绝对路径；目录需在已授权范围内（默认是用户 Home）。")
                }
            }
            .navigationTitle("打开工作区")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .task {
                // 默认进入服务端浏览根（第一个 scan root），失败时仍可手动输入路径。
                await browse(to: "")
            }
            .onChange(of: path) { _, _ in
                localError = nil
            }
            .quickLookPreview($previewURL)
        }
    }

    @ViewBuilder
    private var currentDirectorySection: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(themeStore.uiFont(size: 20, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                        .frame(width: 38, height: 38)
                        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentDirectoryName)
                            .font(themeStore.uiFont(size: 16, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                            .lineLimit(1)
                        Text(browsePath ?? "正在定位...")
                            .font(themeStore.uiFont(size: 12))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(2)
                            .truncationMode(.head)
                    }

                    Spacer(minLength: 10)

                    if let browseParentPath {
                        Button {
                            Task { await browse(to: browseParentPath) }
                        } label: {
                            Label("上一级", systemImage: "arrow.up")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isBrowsing)
                        .accessibilityLabel("返回上一级")
                    }
                }

                Button {
                    if let browsePath {
                        Task { await open(path: browsePath) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(isOpening ? "正在打开" : "打开当前目录")
                        Spacer(minLength: 0)
                    }
                    .font(themeStore.uiFont(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(browsePath == nil || isOpening || isBrowsing)
            }
            .padding(.vertical, 4)
        } header: {
            Text("当前位置")
        }
    }

    @ViewBuilder
    private var childDirectoriesSection: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Section {
            if isBrowsing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载目录…")
                        .foregroundStyle(.secondary)
                }
            } else if let browseError {
                Text(browseError)
                    .font(themeStore.uiFont(size: 13))
                    .foregroundStyle(.red)
                Button {
                    Task { await browse(to: browsePath ?? "") }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
            } else if browseEntries.isEmpty {
                Text("没有可进入的子目录或可预览文件")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(browseEntries) { entry in
                    Button {
                        if entry.isDir {
                            Task { await browse(to: entry.path) }
                        } else {
                            Task { await preview(entry) }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.isDir ? "folder" : "doc.text")
                                .font(themeStore.uiFont(size: 18, weight: .regular))
                                .foregroundStyle(tokens.accent)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(themeStore.uiFont(size: 15, weight: .medium))
                                    .foregroundStyle(tokens.primaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if previewingPath == entry.path {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: entry.isDir ? "chevron.right" : "eye")
                                    .font(themeStore.uiFont(size: 12, weight: .semibold))
                                    .foregroundStyle(tokens.tertiaryText)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpening || isBrowsing || previewingPath != nil || (!entry.canBrowse && !entry.isPreviewable))
                }

                if let previewError {
                    Text(previewError)
                        .font(themeStore.uiFont(size: 13))
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("内容")
        } footer: {
            if browseTruncated {
                Text("目录过大，仅显示前面部分；其余内容请用下方手动输入路径打开目录。")
            } else {
                Text("隐藏目录、Library 与常见缓存目录不会显示；文件仅用于预览，不能作为工作区打开。")
            }
        }
    }

    private var currentDirectoryName: String {
        guard let browsePath, !browsePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "正在定位"
        }
        let parts = browsePath.split(separator: "/").map(String.init)
        return parts.last ?? browsePath
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canOpenTypedPath: Bool {
        !isOpening && !trimmedPath.isEmpty
    }

    private func browse(to target: String) async {
        browseRequestID += 1
        let requestID = browseRequestID
        isBrowsing = true
        browseError = nil
        do {
            let response = try await sessionStore.listDirectories(path: target)
            guard requestID == browseRequestID else {
                return
            }
            browsePath = response.path
            browseParentPath = response.parentPath
            browseEntries = response.entries
            browseTruncated = response.truncated ?? false
            previewError = nil
            isBrowsing = false
        } catch {
            guard requestID == browseRequestID else {
                return
            }
            browseError = userFacingBrowseError(error)
            isBrowsing = false
        }
    }

    private func userFacingBrowseError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return "当前 agentd 版本还不支持目录浏览，请升级 agentd；也可以直接在下方输入路径。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return "该目录不在授权范围内或不可访问。"
        }
        return error.localizedDescription
    }

    private func preview(_ entry: DirectoryEntry) async {
        guard entry.isPreviewable else {
            return
        }
        let targetPath = entry.path
        previewingPath = targetPath
        previewError = nil
        defer {
            if previewingPath == targetPath {
                previewingPath = nil
            }
        }
        do {
            previewURL = try await sessionStore.previewFile(path: targetPath)
        } catch {
            previewError = userFacingPreviewError(error)
        }
    }

    private func userFacingPreviewError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return "当前 agentd 版本还不支持文件预览，请升级 agentd。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return "该文件不在授权范围内或不可访问。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 413 {
            return "文件过大，暂不支持预览。"
        }
        return error.localizedDescription
    }

    private func open(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            localError = "请输入开发环境中的目录路径"
            return
        }
        isOpening = true
        localError = nil
        defer { isOpening = false }
        if await sessionStore.openWorkspace(path: targetPath) {
            if let openedWorkspaceID = sessionStore.selectedProjectID {
                onOpened(openedWorkspaceID)
            }
            dismiss()
        } else {
            localError = userFacingOpenWorkspaceError(sessionStore.errorMessage, path: targetPath)
        }
    }

    private func userFacingOpenWorkspaceError(_ message: String?, path: String) -> String {
        let fallback = "无法打开“\(path)”"
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        let lowercased = message.lowercased()
        if lowercased.contains("allowlist") ||
            message.contains("允许范围") ||
            message.contains("HTTP 403") {
            return "“\(path)”还不在已授权范围内。默认浏览授权根是用户 Home；如改过配置，请在本地开发环境中调整 browse_roots（或 AGENTD_BROWSE_ROOTS）后重试。"
        }
        return message
    }
}

private struct ProjectSessionRows: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let project: AgentProject
    let snapshot: ProjectSessionListSnapshot
    let selectedSessionID: SessionID?
    let isLoading: Bool
    let themeRenderKey: SidebarThemeRenderKey

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if snapshot.isEmpty && !isLoading {
            Text("暂无历史会话")
                .font(themeStore.uiFont(size: 12))
                .foregroundStyle(tokens.tertiaryText)
                .padding(.leading, 30)
                .padding(.vertical, 4)
                .sidebarListRow()
        }

        ForEach(snapshot.visibleSessions) { session in
            let isPinned = sessionStore.isSessionPinned(session.id)
            let isArchived = sessionStore.isSessionArchived(session.id)
            let reminder = sessionStore.sessionReminder(for: session.id)
            let foregroundActivity = sessionStore.foregroundActivity(for: session.id)
            SessionRow(
                session: session,
                foregroundActivity: foregroundActivity,
                isSelected: session.id == selectedSessionID,
                isPinned: isPinned,
                isArchived: isArchived,
                reminder: reminder,
                isObserving: sessionStore.isSessionObserving(session),
                searchSnippet: sessionStore.sessionSearchSnippet(for: session.id),
                themeRenderKey: themeRenderKey
            )
                .equatable()
                // List 行内的 Button 会被 UICollectionView 的 delaysContentTouches 拖慢高亮，
                // 改用 contentShape + onTapGesture，让点击在抬手时立即响应。
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await sessionStore.selectSession(session) }
                }
                .contextMenu {
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

                    Button {
                        Task { await sessionStore.handoffSessionToWorktree(session) }
                    } label: {
                        Label("转到新 Git Worktree", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(session.isRunning || sessionStore.isCreatingWorktree)

                    Menu {
                        Button {
                            Task { await sessionStore.scheduleSessionReminder(session, after: 30 * 60) }
                        } label: {
                            Label("30 分钟后", systemImage: "timer")
                        }
                        Button {
                            Task { await sessionStore.scheduleSessionReminder(session, after: 2 * 60 * 60) }
                        } label: {
                            Label("2 小时后", systemImage: "clock")
                        }
                        Button {
                            Task { await sessionStore.scheduleSessionReminder(session, after: 24 * 60 * 60) }
                        } label: {
                            Label("明天", systemImage: "calendar")
                        }
                        if reminder != nil {
                            Button(role: .destructive) {
                                sessionStore.clearSessionReminder(session)
                            } label: {
                                Label("清除提醒", systemImage: "bell.slash")
                            }
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
                .padding(.leading, 30)
                .sidebarListRow()
        }

        if snapshot.shouldShowActionRow {
            HStack(spacing: 6) {
                if snapshot.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.tertiaryText)
                } else {
                    Image(systemName: snapshot.isShowingAll && !snapshot.canLoadMore ? "chevron.up" : "ellipsis")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                }
                Text(snapshot.actionTitle)
                    .lineLimit(1)
            }
            .font(themeStore.uiFont(size: 12, weight: .medium))
            .foregroundStyle(tokens.tertiaryText)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !snapshot.isLoadingMore else {
                        return
                    }
                    Task {
                        await sessionStore.toggleSessionListExpansion(projectID: project.id)
                    }
                }
                .padding(.leading, 38)
                .padding(.vertical, 4)
                .sidebarListRow()
        }
    }
}

private struct ProjectRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    let project: AgentProject
    let isActiveProject: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let isUnavailable: Bool
    let showsDisclosure: Bool
    let showsSessionActions: Bool
    let claudeChannelAvailable: Bool
    let themeRenderKey: SidebarThemeRenderKey
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onNewClaudeSession: () -> Void
    let onCreateWorktree: () -> Void
    let onManageWorktrees: () -> Void
    let onRetry: () -> Void
    let onForget: () -> Void

    static func == (lhs: ProjectRow, rhs: ProjectRow) -> Bool {
        lhs.project == rhs.project
            && lhs.isActiveProject == rhs.isActiveProject
            && lhs.isSelected == rhs.isSelected
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isLoading == rhs.isLoading
            && lhs.isUnavailable == rhs.isUnavailable
            && lhs.showsDisclosure == rhs.showsDisclosure
            && lhs.showsSessionActions == rhs.showsSessionActions
            && lhs.claudeChannelAvailable == rhs.claudeChannelAvailable
            // 主题切换只通过轻量 key 打破行缓存，避免移除 .equatable() 导致长列表回退。
            && lhs.themeRenderKey == rhs.themeRenderKey
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 6) {
            // 整块左侧区域作为展开/收起的点击目标。用 onTapGesture 绕开 List 行内 Button
            // 在 UICollectionView 下的 delaysContentTouches 高亮延迟。
            HStack(spacing: 8) {
                Image(systemName: isUnavailable ? "exclamationmark.triangle.fill" : (isActiveProject || isExpanded ? "folder.fill" : "folder"))
                    .font(themeStore.uiFont(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 20)
                    .foregroundStyle(isUnavailable ? tokens.warning : (isActiveProject ? tokens.accent : tokens.tertiaryText))
                Text(project.name)
                    .font(themeStore.uiFont(size: 15, weight: isActiveProject ? .semibold : .medium))
                    .foregroundStyle(isUnavailable ? tokens.tertiaryText : (isActiveProject ? tokens.primaryText : tokens.secondaryText))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if isUnavailable {
                    Text("不可用")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.warning)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.tertiaryText)
                } else if showsDisclosure {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.tertiaryText)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(themeStore.uiFont(size: 13, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            Menu {
                if showsSessionActions {
                    // 会话在创建瞬间就绑定 runtime，事后无法切换通道；菜单里保留显式通道选择。
                    Button(action: onNewSession) {
                        Label("新建 Codex 会话", systemImage: "plus.circle")
                    }
                    .disabled(isUnavailable)
                    if claudeChannelAvailable {
                        Button(action: onNewClaudeSession) {
                            Label("新建 Claude Code 会话", systemImage: "sparkles")
                        }
                        .disabled(isUnavailable)
                    }
                    Divider()
                }
                if isUnavailable {
                    Button(action: onRetry) {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                }
                Button(action: onCreateWorktree) {
                    Label("新建 Git Worktree", systemImage: "square.stack.3d.up")
                }
                .disabled(isUnavailable)
                Button(action: onManageWorktrees) {
                    Label("管理 Git Worktree", systemImage: "wrench.and.screwdriver")
                }
                Button(role: .destructive, action: onForget) {
                    Label("从当前设备移除", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(themeStore.uiFont(size: 14, weight: .semibold))
                    .foregroundStyle(tokens.tertiaryText.opacity(0.72))
                    .frame(width: 22, height: 26)
                    // 菜单点击区随行高扩展，不用负 padding，保证 hit-test 在布局边界内稳定生效。
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .accessibilityLabel("项目操作")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background {
            SidebarSelectionBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                selectedTint: tokens.selectionFill,
                hoverTint: tokens.sidebarHoverFill,
                selectedAccent: tokens.accent
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? tokens.accent.opacity(0.34) : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
    }

}

private struct SessionRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    let session: AgentSession
    let foregroundActivity: SessionForegroundActivity?
    let isSelected: Bool
    let isPinned: Bool
    let isArchived: Bool
    let reminder: SessionReminder?
    let isObserving: Bool
    let searchSnippet: String?
    let themeRenderKey: SidebarThemeRenderKey

    static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.session == rhs.session
            && lhs.foregroundActivity == rhs.foregroundActivity
            && lhs.isSelected == rhs.isSelected
            && lhs.isPinned == rhs.isPinned
            && lhs.isArchived == rhs.isArchived
            && lhs.reminder == rhs.reminder
            && lhs.isObserving == rhs.isObserving
            && lhs.searchSnippet == rhs.searchSnippet
            // 主题 key 让色彩/字体 token 变化能刷新，但仍避免流式状态更新重绘所有侧栏行。
            && lhs.themeRenderKey == rhs.themeRenderKey
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6, height: 6)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? tokens.secondaryText : tokens.tertiaryText)
                        .accessibilityLabel("已置顶")
                }
                if isArchived {
                    Image(systemName: "archivebox.fill")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.tertiaryText)
                        .accessibilityLabel("已归档")
                }
                if reminder != nil {
                    Image(systemName: "bell.fill")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.warning.opacity(0.86))
                        .accessibilityLabel("已设置提醒")
                }
                Text(session.title)
                    .font(themeStore.uiFont(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? tokens.primaryText : tokens.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                trailingMetadata
            }

            // 侧栏作为会话索引，默认不展示聊天 preview，避免内容摘要压过标题和关键状态。
            if shouldShowStatusLine {
                HStack(spacing: 0) {
                    statusCapsule(statusSummary)
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
            }

            if let searchSnippet, !searchSnippet.isEmpty {
                Text(searchSnippet)
                    .font(themeStore.uiFont(size: 11, weight: .regular))
                    .foregroundStyle(tokens.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background {
            SidebarSelectionBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                selectedTint: tokens.selectionFill,
                hoverTint: tokens.sidebarHoverFill,
                selectedAccent: tokens.accent
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? tokens.accent.opacity(0.32) : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var trailingMetadata: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if !shouldShowStatusLine && shouldShowTrailingActivityIcon {
            if statusSummary.showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(tint(for: statusSummary.tone))
                    .frame(width: 16, height: 16, alignment: .center)
                    .accessibilityLabel(statusSummary.title)
            } else {
                Image(systemName: statusSummary.systemImage)
                    .font(themeStore.uiFont(size: 13, weight: .semibold))
                    .foregroundStyle(tint(for: statusSummary.tone))
                    .frame(width: 16, height: 16, alignment: .center)
                    .accessibilityLabel(statusSummary.title)
            }
        } else if let updatedAt = session.updatedAt {
            Text(Self.minuteTimeFormatter.string(from: updatedAt))
                .font(themeStore.uiFont(size: 12, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var statusSummary: AgentSessionDisplayStatus {
        if isObserving {
            return AgentSessionDisplayStatus(title: "观察中", systemImage: "eye", tone: .neutral, showsSpinner: false)
        }
        return session.displayStatus(foregroundActivity: foregroundActivity)
    }

    private var statusDotColor: Color {
        tint(for: statusSummary.tone)
    }

    private var shouldShowStatusLine: Bool {
        session.pendingApproval != nil
            || session.status == SessionStatus.waitingForInput.rawValue
            || session.status == SessionStatus.waitingForApproval.rawValue
            || session.status == SessionStatus.failed.rawValue
    }

    private var shouldShowTrailingActivityIcon: Bool {
        isObserving || session.isRunning || foregroundActivity != nil || session.activeTurnID != nil
    }

    private func statusCapsule(_ status: AgentSessionDisplayStatus) -> some View {
        Text(status.title)
            .lineLimit(1)
        .font(themeStore.uiFont(size: 10, weight: .medium))
        .foregroundStyle(tint(for: status.tone))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusCapsuleBackground(for: status.tone), in: Capsule())
    }

    private func tint(for tone: AgentSessionStatusTone) -> Color {
        let tokens = themeStore.tokens(for: colorScheme)
        // 侧栏只让运行、等待、失败等需要处理的状态使用强色；完成/历史态退到中性色。
        switch tone {
        case .active:
            return tokens.primaryAction
        case .warning:
            return tokens.warning
        case .danger:
            return .red
        case .complete:
            return tokens.tertiaryText
        case .neutral:
            return tokens.secondaryText
        }
    }

    private func statusCapsuleBackground(for tone: AgentSessionStatusTone) -> Color {
        switch tone {
        case .warning, .danger:
            return tint(for: tone).opacity(0.11)
        case .active:
            return tint(for: tone).opacity(0.09)
        case .complete, .neutral:
            return themeStore.tokens(for: colorScheme).elevatedSurface.opacity(0.72)
        }
    }

    // 左侧列表只展示到分钟，避免 relative 时间按秒触发刷新。
    private static let minuteTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct SidebarSelectionBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    let selectedTint: Color
    let hoverTint: Color
    let selectedAccent: Color

    var body: some View {
        if isSelected {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selectedTint)
                Capsule(style: .continuous)
                    .fill(selectedAccent)
                    .frame(width: 3)
                    .padding(.vertical, 7)
                    .padding(.leading, 1)
            }
        } else if isHovered {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hoverTint)
        }
    }
}

private struct WorktreeManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    let rootProjectID: String
    @State private var pendingDelete: WorktreeListItem?
    @State private var cleanupDestination: WorktreeCleanupDestination?
    @State private var isLoadingCleanupPreview = false
    @State private var cleanupPreviewError: String?

    private var worktrees: [WorktreeListItem] {
        sessionStore.managedWorktrees(rootProjectID: rootProjectID)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            List {
                if let message = sessionStore.worktreeErrorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    ForEach(worktrees) { item in
                        WorktreeManagerRow(
                            item: item,
                            isRunning: sessionStore.hasRunningSession(in: item),
                            isBusy: sessionStore.isDeletingWorktree,
                            onOpen: {
                                Task {
                                    _ = await sessionStore.openManagedWorktree(item)
                                    dismiss()
                                }
                            },
                            onDelete: {
                                pendingDelete = item
                            }
                        )
                    }
                }
                Section {
                    Button {
                        Task { await loadCleanupPreview() }
                    } label: {
                        if isLoadingCleanupPreview {
                            Label("正在评估清理候选", systemImage: "hourglass")
                        } else {
                            Label("清理候选", systemImage: "sparkles")
                        }
                    }
                    .disabled(sessionStore.isRefreshingWorktrees || sessionStore.isDeletingWorktree || sessionStore.isPruningWorktrees || isLoadingCleanupPreview)

                    Button {
                        Task { await sessionStore.pruneMissingManagedWorktrees() }
                    } label: {
                        if sessionStore.isPruningWorktrees {
                            Label("正在清理", systemImage: "hourglass")
                        } else {
                            Label("清理丢失登记", systemImage: "checklist.unchecked")
                        }
                    }
                    .disabled(sessionStore.isRefreshingWorktrees || sessionStore.isDeletingWorktree || sessionStore.isPruningWorktrees)

                    if let cleanupPreviewError {
                        Label(cleanupPreviewError, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("“清理候选”会先按服务端固定保留策略预览，只有无 blocker 的候选可确认删除；“清理丢失登记”只移除不存在的 registry 记录。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Git Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .overlay {
                if worktrees.isEmpty && !sessionStore.isRefreshingWorktrees {
                    ContentUnavailableView(
                        "没有 Git Worktree",
                        systemImage: "square.stack.3d.up",
                        description: Text("当前项目没有已管理的 Git Worktree。")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await sessionStore.refreshManagedWorktrees() }
                    } label: {
                        if sessionStore.isRefreshingWorktrees {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(sessionStore.isRefreshingWorktrees || sessionStore.isPruningWorktrees)
                    .accessibilityLabel("刷新 Git Worktree")
                }
            }
        }
        .task {
            await sessionStore.refreshManagedWorktrees()
        }
        .sheet(item: $cleanupDestination) { destination in
            WorktreeCleanupPreviewSheet(
                preview: destination.preview,
                rootProjectID: rootProjectID
            )
        }
        .confirmationDialog("删除 Git Worktree？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDelete = nil
                }
            }
        ), titleVisibility: .visible) {
            if let item = pendingDelete {
                Button("删除 \(item.workspace.name)", role: .destructive) {
                    let target = item
                    pendingDelete = nil
                    Task { await sessionStore.deleteManagedWorktree(target, force: false) }
                }
            }
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("删除仍会由 agentd 检查运行中会话和 Git 状态；存在未提交改动时不会强制绕过保护。")
        }
    }

    @MainActor
    private func loadCleanupPreview() async {
        guard !isLoadingCleanupPreview else {
            return
        }
        isLoadingCleanupPreview = true
        cleanupPreviewError = nil
        defer { isLoadingCleanupPreview = false }
        do {
            let preview = try await sessionStore.previewManagedWorktreeCleanup()
            cleanupDestination = WorktreeCleanupDestination(preview: preview)
        } catch {
            cleanupPreviewError = userFacingCleanupError(error)
        }
    }

    private func userFacingCleanupError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return "当前 agentd 版本还不支持清理预览，请先升级 Mac 端 agentd。"
        }
        return error.localizedDescription
    }
}

private struct WorktreeCleanupDestination: Identifiable {
    let id = UUID()
    let preview: WorktreeCleanupResponse
}

private struct WorktreeCleanupPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var preview: WorktreeCleanupResponse
    @State private var selectedPaths: Set<String>
    @State private var isExecuting = false
    @State private var isShowingDestructiveConfirmation = false
    @State private var executionError: String?
    let rootProjectID: String

    init(preview: WorktreeCleanupResponse, rootProjectID: String) {
        self.rootProjectID = rootProjectID
        _preview = State(initialValue: preview)
        let candidates = Set(preview.candidatePaths)
        _selectedPaths = State(initialValue: Set(preview.worktrees.compactMap { item in
            let root = item.workspace.rootProjectID ?? item.worktree.rootProjectID
            guard root == rootProjectID,
                  item.eligible,
                  candidates.contains(item.worktree.path)
            else {
                return nil
            }
            return item.worktree.path
        }))
    }

    private var projectItems: [WorktreeCleanupItem] {
        preview.worktrees.filter { item in
            (item.workspace.rootProjectID ?? item.worktree.rootProjectID) == rootProjectID
        }
    }

    private var candidatePaths: Set<String> {
        Set(preview.candidatePaths)
    }

    private var isPlanExecutable: Bool {
        // 只有 dry-run 响应里的 plan_id 可以执行一次。执行响应即使还带着旧候选，
        // 也只能用于展示结果，不能再次选择并提交已经消费的计划。
        preview.dryRun && !preview.hasPartialFailure
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            List {
                Section("保留策略") {
                    LabeledContent("自动删除", value: preview.policy.autoDelete ? "开启" : "关闭")
                    LabeledContent("候选时间", value: "超过 \(preview.policy.candidateAfterDays) 天未使用")
                    LabeledContent("每个项目至少保留", value: "最近 \(preview.policy.keepLatestPerProject) 个")
                    LabeledContent("评估时间", value: preview.generatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                Section {
                    if projectItems.isEmpty {
                        ContentUnavailableView(
                            "没有可评估的 Worktree",
                            systemImage: "checkmark.shield",
                            description: Text("当前项目没有进入清理策略评估的已管理 Worktree。")
                        )
                    } else {
                        ForEach(projectItems) { item in
                            WorktreeCleanupPreviewRow(
                                item: item,
                                isCandidate: isPlanExecutable && candidatePaths.contains(item.worktree.path),
                                isSelected: selectedPaths.contains(item.worktree.path),
                                isBusy: isExecuting
                            ) {
                                toggleSelection(item)
                            }
                        }
                    }
                } header: {
                    Text("候选与保护原因")
                } footer: {
                    Text("只有服务端 dry-run 同时标记为 eligible 的路径可以选择；有 blocker 的 Worktree 不会被提交到删除接口。")
                }

                if let executionError {
                    Section("清理结果") {
                        Label(executionError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        isShowingDestructiveConfirmation = true
                    } label: {
                        if isExecuting {
                            Label("正在重新检查并清理", systemImage: "hourglass")
                        } else {
                            Label("删除选中的 \(selectedPaths.count) 个 Worktree", systemImage: "trash")
                        }
                    }
                    .disabled(selectedPaths.isEmpty || isExecuting)
                } footer: {
                    Text("执行时 agentd 会重新计算 blocker；策略变化、运行中会话、未提交改动或未知 Git 状态都会阻止删除。")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle("清理 Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(isExecuting)
                }
            }
        }
        .confirmationDialog(
            "确认删除 \(selectedPaths.count) 个 Worktree？",
            isPresented: $isShowingDestructiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认删除", role: .destructive) {
                Task { await executeCleanup() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除对应 Git checkout。客户端不会发送 force；agentd 仍会对当前候选和所有 blocker 做最终检查。")
        }
    }

    private func toggleSelection(_ item: WorktreeCleanupItem) {
        guard isPlanExecutable,
              item.eligible,
              candidatePaths.contains(item.worktree.path),
              !isExecuting
        else {
            return
        }
        if selectedPaths.contains(item.worktree.path) {
            selectedPaths.remove(item.worktree.path)
        } else {
            selectedPaths.insert(item.worktree.path)
        }
        executionError = nil
    }

    @MainActor
    private func executeCleanup() async {
        guard !isExecuting else {
            return
        }
        isExecuting = true
        executionError = nil
        defer { isExecuting = false }
        do {
            let response = try await sessionStore.cleanupManagedWorktrees(paths: selectedPaths, preview: preview)
            if let partialFailureMessage = response.partialFailureMessage {
                // plan_id 在执行开始后即失效；部分成功时保留结果页，但清空选择，
                // 要求用户关闭后重新 dry-run，不能误用旧计划重试剩余路径。
                preview = response
                selectedPaths = []
                executionError = partialFailureMessage
                return
            }
            guard !response.deletedPaths.isEmpty else {
                preview = response
                selectedPaths = []
                executionError = "agentd 重新检查后没有删除任何 Worktree，请关闭后重新生成预览。"
                return
            }
            dismiss()
        } catch {
            executionError = error.localizedDescription
        }
    }
}

private struct WorktreeCleanupPreviewRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let item: WorktreeCleanupItem
    let isCandidate: Bool
    let isSelected: Bool
    let isBusy: Bool
    let onToggle: () -> Void

    private var isSelectable: Bool {
        item.eligible && isCandidate
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelectable ? (isSelected ? "checkmark.circle.fill" : "circle") : "lock.shield.fill")
                    .foregroundStyle(isSelectable ? tokens.accent : tokens.secondaryText)
                    .font(themeStore.uiFont(size: 19, weight: .semibold))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.workspace.name)
                        .font(themeStore.uiFont(size: 15, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(item.worktree.path)
                        .font(themeStore.uiFont(size: 11))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    cleanupDates
                    if isSelectable {
                        Label("符合清理策略", systemImage: "checkmark.shield")
                            .font(themeStore.uiFont(size: 12, weight: .medium))
                            .foregroundStyle(tokens.success)
                    } else {
                        blockers
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable || isBusy)
        .accessibilityLabel(accessibilityLabel)
    }

    private var cleanupDates: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let createdAt = item.createdAt {
                Text("创建：\(createdAt.formatted(date: .abbreviated, time: .omitted))")
            }
            if let lastUsedAt = item.lastUsedAt {
                Text("最近使用：\(lastUsedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .font(themeStore.uiFont(size: 11))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var blockers: some View {
        if item.blockers.isEmpty {
            Label("服务端未判定为可清理", systemImage: "shield")
                .font(themeStore.uiFont(size: 12, weight: .medium))
                .foregroundStyle(.orange)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(item.blockers) { blocker in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(blocker.message)
                            .font(themeStore.uiFont(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                        Text(blocker.code)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var accessibilityLabel: String {
        if isSelectable {
            return "\(item.workspace.name)，可清理，\(isSelected ? "已选择" : "未选择")"
        }
        let reasons = item.blockers.map(\.message).joined(separator: "，")
        return "\(item.workspace.name)，不可清理，\(reasons)"
    }
}

private struct CreateWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    let project: AgentProject
    @State private var name = ""
    @State private var base = ""
    @State private var branch = ""
    @State private var didApplyDefaultBase = false

    private var canCreate: Bool {
        !sessionStore.isCreatingWorktree
    }

    private var branchList: WorktreeBranchListResponse? {
        sessionStore.worktreeBranches(path: project.path)
    }

    private var baseBranchItems: [WorktreeBranchItem] {
        branchList?.branches ?? []
    }

    private var branchErrorMessage: String? {
        sessionStore.worktreeBranchError(path: project.path)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Form {
                Section {
                    LabeledContent("项目") {
                        Text(project.name)
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                    }
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack(spacing: 8) {
                        TextField("Base", text: $base)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if sessionStore.isRefreshingWorktreeBranches && baseBranchItems.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                        } else if !baseBranchItems.isEmpty {
                            Menu {
                                ForEach(baseBranchItems) { item in
                                    Button {
                                        base = item.name
                                        didApplyDefaultBase = true
                                    } label: {
                                        Label(branchMenuTitle(item), systemImage: branchIconName(item))
                                    }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                                    .foregroundStyle(tokens.secondaryText)
                                    .frame(width: 28, height: 28)
                            }
                            .accessibilityLabel("选择 Base")
                        }
                    }
                    TextField("分支", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let message = branchErrorMessage, !message.isEmpty {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                if let message = sessionStore.errorMessage, !message.isEmpty {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle("新建 Git Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            let opened = await sessionStore.createWorktreeAndOpen(
                                project: project,
                                name: normalizedOptional(name),
                                base: normalizedOptional(base),
                                branch: normalizedOptional(branch)
                            )
                            if opened {
                                dismiss()
                            }
                        }
                    } label: {
                        if sessionStore.isCreatingWorktree {
                            ProgressView()
                        } else {
                            Text("创建")
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .task(id: project.path) {
                await sessionStore.refreshWorktreeBranches(path: project.path)
                applyDefaultBaseIfNeeded()
            }
            .onChange(of: branchList?.defaultBase ?? "") { _, _ in
                applyDefaultBaseIfNeeded()
            }
        }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyDefaultBaseIfNeeded() {
        guard !didApplyDefaultBase,
              normalizedOptional(base) == nil,
              let defaultBase = branchList?.defaultBase,
              !defaultBase.isEmpty
        else {
            return
        }
        base = defaultBase
        didApplyDefaultBase = true
    }

    private func branchMenuTitle(_ item: WorktreeBranchItem) -> String {
        if item.isCurrent {
            return "\(item.name) · 当前"
        }
        if item.isDefault {
            return "\(item.name) · 默认"
        }
        return item.name
    }

    private func branchIconName(_ item: WorktreeBranchItem) -> String {
        item.kind == "remote" ? "arrow.down.circle" : "point.topleft.down.curvedto.point.bottomright.up"
    }
}

private struct WorktreeManagerRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let item: WorktreeListItem
    let isRunning: Bool
    let isBusy: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(tokens.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.workspace.name)
                        .font(themeStore.uiFont(size: 15, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                    Text(item.worktree.rootProjectName)
                        .font(themeStore.uiFont(size: 12, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isRunning {
                    Text("运行中")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.primaryAction)
                }
            }

            Text(item.workspace.path)
                .font(themeStore.uiFont(size: 12, weight: .regular))
                .foregroundStyle(tokens.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(item.worktree.branch ?? item.worktree.base, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(themeStore.uiFont(size: 11, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                    Label("base \(item.worktree.base)", systemImage: "arrow.triangle.branch")
                        .font(themeStore.uiFont(size: 11, weight: .regular))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onOpen) {
                    Label("打开", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(isRunning || isBusy)
            }

            if !worktreeStatusItems.isEmpty {
                HStack(spacing: 6) {
                    ForEach(worktreeStatusItems, id: \.self) { item in
                        Text(item)
                            .font(themeStore.uiFont(size: 10, weight: .semibold))
                            .foregroundStyle(tokens.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(tokens.surface, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var worktreeStatusItems: [String] {
        var items: [String] = []
        if item.worktree.gitState == "unknown" {
            items.append("Git 状态未知")
        } else if item.worktree.dirty || item.worktree.gitState == "dirty" {
            items.append("未提交")
        }
        if item.worktree.ahead > 0 {
            items.append("领先 \(item.worktree.ahead)")
        }
        if item.worktree.behind > 0 {
            items.append("落后 \(item.worktree.behind)")
        }
        if let upstream = item.worktree.upstream?.trimmingCharacters(in: .whitespacesAndNewlines), !upstream.isEmpty {
            items.append(upstream)
        }
        return items
    }
}

private struct SidebarListRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private extension View {
    func sidebarListRow() -> some View {
        modifier(SidebarListRowStyle())
    }
}
