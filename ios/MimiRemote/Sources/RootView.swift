import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingLogInspector = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @SceneStorage("root.selectedAppTab") private var selectedAppTabRawValue = AppTab.sessions.rawValue
    @AppStorage("runtime.keepAwakeWhileRunning") private var keepAwakeWhileRunning = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if appStore.isConfigured {
                appShell
            } else {
                SettingsView(isInitialSetup: true)
                    .environment(\.themeSystemColorScheme, colorScheme)
            }
        }
        .task {
            await sessionStore.bootstrap()
        }
        .task(id: sessionStore.selectedProjectID) {
            await sessionStore.pollSelectedProjectSessionsWhileVisible()
        }
        .onAppear(perform: applyIdleTimerPolicy)
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            applyIdleTimerPolicy()
            guard phase == .active else {
                return
            }
            Task {
                await sessionStore.resumeFromForeground()
            }
        }
        .onChange(of: keepAwakeWhileRunning) { _, _ in
            applyIdleTimerPolicy()
        }
        .onChange(of: sessionStore.selectedSessionID) { _, _ in
            applyIdleTimerPolicy()
        }
        .onChange(of: sessionStore.selectedSession?.status) { _, _ in
            applyIdleTimerPolicy()
        }
        .onChange(of: sessionStore.webSocketStatus) { _, _ in
            applyIdleTimerPolicy()
        }
        .environment(\.themeSystemColorScheme, colorScheme)
        .preferredColorScheme(themeStore.preferredColorScheme)
        .tint(tokens.accent)
        .background(tokens.background.ignoresSafeArea())
    }

    private func applyIdleTimerPolicy() {
        // 只在前台且用户明确开启时保持常亮；离开运行会话后立即恢复系统默认，避免静默耗电。
        UIApplication.shared.isIdleTimerDisabled = keepAwakeWhileRunning
            && scenePhase == .active
            && sessionStore.selectedSession?.isRunning == true
    }

    private var selectedAppTab: AppTab {
        AppTab(rawValue: selectedAppTabRawValue) ?? .sessions
    }

    private var selectedAppTabBinding: Binding<AppTab> {
        Binding(
            get: { selectedAppTab },
            set: { selectedAppTabRawValue = $0.rawValue }
        )
    }

    private var appShell: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return TabView(selection: selectedAppTabBinding) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    appTabContent(for: tab)
                }
            }
        }
        .toolbarBackground(tokens.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    @ViewBuilder
    private func appTabContent(for tab: AppTab) -> some View {
        switch tab {
        case .sessions:
            mainLayout
        case .workspace:
            WorkspaceRootView()
                .environment(\.themeSystemColorScheme, colorScheme)
        case .settings:
            SettingsView(isInitialSetup: false, showsDoneButton: false)
                .environment(\.themeSystemColorScheme, colorScheme)
        case .profile:
            ProfileRootView()
                .environment(\.themeSystemColorScheme, colorScheme)
        }
    }

    private var mainLayout: some View {
        GeometryReader { proxy in
            let layout = WorkbenchLayout(containerWidth: proxy.size.width, horizontalSizeClass: horizontalSizeClass)

            if layout.usesCompactNavigation {
                compactLayout(layout: layout)
            } else {
                splitLayout(layout: layout)
            }
        }
        .overlay {
            initialConnectionOverlay
        }
    }

    @ViewBuilder
    private var initialConnectionOverlay: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if appStore.isConfigured,
           sessionStore.sidebarProjects.isEmpty,
           sessionStore.selectedProjectID == nil,
           sessionStore.selectedSessionID == nil,
           sessionStore.isLoading || sessionStore.errorMessage != nil {
            VStack(spacing: 14) {
                if sessionStore.isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(tokens.accent)
                    Text("正在连接本地开发环境中的 agentd")
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text("如果刚启动 Tailscale 或 agentd，这里会自动重试。")
                        .font(themeStore.uiFont(.callout))
                        .foregroundStyle(tokens.secondaryText)
                        .multilineTextAlignment(.center)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(tokens.warning)
                    Text("无法连接 agentd")
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(sessionStore.errorMessage ?? "请检查 agentd 和网络连接。")
                        .font(themeStore.uiFont(.callout))
                        .foregroundStyle(tokens.secondaryText)
                        .multilineTextAlignment(.center)
                    Button {
                        selectedAppTabRawValue = AppTab.settings.rawValue
                    } label: {
                        Label("打开设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tokens.border, lineWidth: 1)
            }
            .padding()
            .transition(.opacity)
        }
    }

    private func compactLayout(layout: WorkbenchLayout) -> some View {
        NavigationStack {
            ProjectSidebarView(showsSessions: true)
                .navigationTitle("咪咪")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(isPresented: compactSessionDetailBinding) {
                    workspaceDetail(
                        layout: layout,
                        showsSidebarToggle: false,
                        showsReturnButton: false
                    )
                }
        }
        .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
            if sessionID == nil {
                showingLogInspector = false
            }
        }
    }

    private func splitLayout(layout: WorkbenchLayout) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebarView(showsSessions: true)
                // 侧栏本身用 Section header 呈现“项目”，隐藏大标题可以让项目树首屏更紧凑。
                .toolbar(.hidden, for: .navigationBar)
                // 侧栏宽度跟随窗口缩放，iPhone、iPad mini 和浮窗不会把详情区挤到只剩一条窄缝。
                .navigationSplitViewColumnWidth(
                    min: layout.projectColumn.min,
                    ideal: layout.projectColumn.ideal,
                    max: layout.projectColumn.max
                )
        } detail: {
            workspaceDetail(
                layout: layout,
                showsSidebarToggle: true,
                showsReturnButton: true
            )
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            applyResponsiveColumnVisibility(for: layout)
        }
        .onChange(of: layout) { _, newLayout in
            applyResponsiveColumnVisibility(for: newLayout)
        }
        .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
            if sessionID == nil {
                showingLogInspector = false
            }
            applyResponsiveColumnVisibility(for: layout)
        }
    }

    private func workspaceDetail(
        layout: WorkbenchLayout,
        showsSidebarToggle: Bool,
        showsReturnButton: Bool
    ) -> some View {
        WorkspaceView()
            .navigationTitle(sessionStore.selectedSession?.title ?? sessionStore.selectedProject?.name ?? "会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    AgentWorkbenchTitle(
                        maxWidth: layout.titleMaxWidth,
                        horizontalOffset: titleHorizontalOffset(layout: layout)
                    )
                }
                ToolbarItem(placement: .topBarLeading) {
                    // 仅在侧栏收起时，在主界面提供展开按钮；展开时由侧栏自带的开关负责收起，避免两个图标同时出现。
                    if showsSidebarToggle && columnVisibility == .detailOnly {
                        Button {
                            withAnimation {
                                columnVisibility = .all
                            }
                        } label: {
                            Label("显示项目栏", systemImage: "sidebar.left")
                        }
                        .accessibilityLabel("显示项目栏")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if showsReturnButton && sessionStore.selectedSessionID != nil {
                        Button {
                            sessionStore.returnToSessionList()
                        } label: {
                            Label("回到项目", systemImage: "xmark.circle")
                        }
                        .accessibilityLabel("回到项目")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    refreshControl
                    if let symbol = connectionBadgeSymbol {
                        Image(systemName: symbol)
                            .foregroundStyle(connectionBadgeColor)
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityLabel(sessionStore.connectionBadgeTitle ?? "连接状态")
                    }
                    if sessionStore.selectedSessionID != nil {
                        Button {
                            showingLogInspector.toggle()
                        } label: {
                            Label(layout.usesAttachedInspector ? "日志" : "会话详情", systemImage: layout.usesAttachedInspector ? "terminal" : "sidebar.right")
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText.opacity(0.78))
                        .accessibilityLabel(showingLogInspector ? "隐藏详情" : "显示详情")
                    }
                }
            }
            .sessionInspectorPresentation(isPresented: $showingLogInspector, layout: layout)
    }

    private func titleHorizontalOffset(layout: WorkbenchLayout) -> CGFloat {
        guard showingLogInspector, layout.usesAttachedInspector else {
            return 0
        }
        // SwiftUI inspector 会附着在 detail 右侧；系统 principal 默认按 detail+inspector 总宽居中。
        // 标题左移半个右栏宽度后，视觉中心重新落回中间对话区。
        return -(layout.inspectorColumn.ideal / 2)
    }

    // 刷新属于维护动作，不参与主定位信息；放在 trailing 并弱化颜色，减少顶部抢眼控件。
    @ViewBuilder
    private var refreshControl: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if sessionStore.isLoading || sessionStore.isRefreshingSelectedSession {
            ProgressView()
                .controlSize(.small)
                .tint(tokens.secondaryText.opacity(0.8))
                .accessibilityLabel("正在刷新")
        } else {
            Button {
                Task { await sessionStore.refreshCurrentContext() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(tokens.secondaryText.opacity(0.72))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sessionStore.selectedSessionID == nil ? "刷新会话列表" : "刷新当前会话")
        }
    }

    private var connectionBadgeKind: StatusPill.Kind {
        if sessionStore.selectedSession?.isRunning == true {
            switch sessionStore.webSocketStatus {
            case .connected:
                return .success
            case .connecting:
                // 运行中但 WebSocket 还在握手，不算健康成功态，避免误导用户以为实时链路已就绪。
                return .neutral
            case .disconnected, .failed:
                return .warning
            }
        } else if case .failed = sessionStore.webSocketStatus {
            return .warning
        }
        return .neutral
    }

    // 连接状态以图标呈现，避免在工具栏里塞中文文字。
    private var connectionBadgeSymbol: String? {
        guard let session = sessionStore.selectedSession else {
            return nil
        }
        if case .failed = sessionStore.webSocketStatus {
            return "exclamationmark.triangle.fill"
        }
        guard session.isRunning else {
            // closed/history 是普通完成态，不在顶部常驻提示；异常和运行态才需要占用视觉注意力。
            return nil
        }
        switch sessionStore.webSocketStatus {
        case .connected:
            return "dot.radiowaves.left.and.right"
        case .connecting:
            return "dot.radiowaves.left.and.right"
        case .disconnected:
            return "wifi.slash"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var connectionBadgeColor: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        switch connectionBadgeKind {
        case .success:
            return tokens.success
        case .warning:
            return tokens.warning
        case .neutral:
            return .secondary
        }
    }

    private func applyResponsiveColumnVisibility(for layout: WorkbenchLayout) {
        guard sessionStore.selectedSessionID != nil else {
            if columnVisibility == .detailOnly || layout.prefersDetailOnly {
                // 没有会话被选中时，窄 split 要回到项目/会话列表；否则会停在一个没有返回路径的详情列。
                columnVisibility = .all
            }
            return
        }
        guard layout.prefersDetailOnly else {
            return
        }
        columnVisibility = .detailOnly
    }

    private var compactSessionDetailBinding: Binding<Bool> {
        Binding(get: {
            sessionStore.selectedSessionID != nil
        }, set: { isPresented in
            guard !isPresented, sessionStore.selectedSessionID != nil else {
                return
            }
            sessionStore.returnToSessionList()
        })
    }
}

private enum AppTab: String, CaseIterable, Identifiable {
    case sessions
    case workspace
    case profile
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions:
            return "会话"
        case .workspace:
            return "工作区"
        case .profile:
            return "我的"
        case .settings:
            return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions:
            return "bubble.left.and.bubble.right"
        case .workspace:
            return "folder"
        case .profile:
            return "person.crop.circle"
        case .settings:
            return "gearshape"
        }
    }

    @ViewBuilder
    var label: some View {
        Label(title, systemImage: systemImage)
    }
}

private struct WorkspaceRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isShowingCompactWorkspaceDetail = false

    var body: some View {
        GeometryReader { proxy in
            let usesSplitLayout = horizontalSizeClass == .regular && proxy.size.width >= 720

            if usesSplitLayout {
                HStack(spacing: 0) {
                    ProjectSidebarView(showsSessions: false)
                        .frame(width: min(max(proxy.size.width * 0.32, 280), 360))
                    Divider()
                    WorkspaceDetailView(project: sessionStore.selectedProject)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(themeStore.tokens(for: colorScheme).background)
            } else {
                NavigationStack {
                    ProjectSidebarView(showsSessions: false) {
                        isShowingCompactWorkspaceDetail = true
                    }
                        .navigationTitle("工作区")
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationDestination(isPresented: $isShowingCompactWorkspaceDetail) {
                            WorkspaceDetailView(project: sessionStore.selectedProject)
                        }
                }
            }
        }
    }
}

private struct WorkspaceDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    let project: AgentProject?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if let project {
                workspaceContent(project: project, tokens: tokens)
            } else {
                ContentUnavailableView {
                    Label("选择一个工作区", systemImage: "folder")
                } description: {
                    Text("左侧会保留最近打开的项目。这里先作为工作区入口，后续再迁移更多管理功能。")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(project?.name ?? "工作区")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func workspaceContent(project: AgentProject, tokens: ThemeTokens) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                workspaceHeader(project: project, tokens: tokens)
                workspaceStats(project: project, tokens: tokens)

                VStack(spacing: 10) {
                    ProfileInfoRow(
                        systemImage: "terminal",
                        title: "会话",
                        value: sessionSummary(for: project),
                        detail: "会话仍在“会话”工作区里创建和继续运行。",
                        tone: tokens.accent
                    )
                    ProfileInfoRow(
                        systemImage: "square.stack.3d.up",
                        title: "Git Worktree",
                        value: worktreeSummary(for: project),
                        detail: "Worktree 管理入口暂时保留在项目行菜单里。",
                        tone: tokens.secondaryText
                    )
                    ProfileInfoRow(
                        systemImage: "checkmark.shield",
                        title: "权限状态",
                        value: sessionStore.isWorkspaceUnavailable(project.id) ? "需要重试" : "可访问",
                        detail: sessionStore.isWorkspaceUnavailable(project.id) ? "这个工作区可能已被移动、删除或不在授权范围内。" : "当前工作区在已授权范围内，可继续用于会话。",
                        tone: sessionStore.isWorkspaceUnavailable(project.id) ? tokens.warning : tokens.success
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func workspaceHeader(project: AgentProject, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(project.name, systemImage: "folder.fill")
                .font(themeStore.uiFont(.title2, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(2)
            Text(project.path)
                .font(themeStore.uiFont(.callout))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workspaceStats(project: AgentProject, tokens: ThemeTokens) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], alignment: .leading, spacing: 10) {
            WorkspaceStatPill(
                title: "会话",
                value: "\(sessionStore.sessions(forProjectID: project.id).count)",
                systemImage: "bubble.left.and.text.bubble.right",
                tone: tokens.accent
            )
            WorkspaceStatPill(
                title: "Worktree",
                value: "\(managedWorktreeCount(for: project))",
                systemImage: "arrow.triangle.branch",
                tone: tokens.secondaryText
            )
            WorkspaceStatPill(
                title: "状态",
                value: sessionStore.isWorkspaceUnavailable(project.id) ? "异常" : "正常",
                systemImage: sessionStore.isWorkspaceUnavailable(project.id) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                tone: sessionStore.isWorkspaceUnavailable(project.id) ? tokens.warning : tokens.success
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionSummary(for project: AgentProject) -> String {
        let count = sessionStore.sessions(forProjectID: project.id).count
        return count == 0 ? "暂无历史" : "\(count) 个"
    }

    private func worktreeSummary(for project: AgentProject) -> String {
        let count = managedWorktreeCount(for: project)
        return count == 0 ? "待接入" : "\(count) 个"
    }

    private func managedWorktreeCount(for project: AgentProject) -> Int {
        let rootProjectID = sessionStore.rootProjectID(forProjectID: project.id)
        return sessionStore.managedWorktrees(rootProjectID: rootProjectID).count
    }
}

private struct WorkspaceStatPill: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let systemImage: String
    let tone: Color

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 16, weight: .semibold))
                .foregroundStyle(tone)
            Text(value)
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }
}

private enum ProfileSection: String, CaseIterable, Identifiable, Hashable {
    case runtime
    case models
    case capabilities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runtime:
            return "运行环境"
        case .models:
            return "模型"
        case .capabilities:
            return "能力"
        }
    }

    var systemImage: String {
        switch self {
        case .runtime:
            return "server.rack"
        case .models:
            return "cpu"
        case .capabilities:
            return "wand.and.stars"
        }
    }
}

private struct ProfileRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var selectedSection: ProfileSection = .runtime

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        GeometryReader { proxy in
            let usesSplitLayout = horizontalSizeClass == .regular && proxy.size.width >= 720

            if usesSplitLayout {
                HStack(spacing: 0) {
                    ProfileSectionSidebar(selection: $selectedSection)
                        .frame(width: 260)
                    Divider()
                    ProfileSectionDetail(section: selectedSection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(tokens.background)
            } else {
                NavigationStack {
                    List {
                        ForEach(ProfileSection.allCases) { section in
                            NavigationLink(value: section) {
                                Label(section.title, systemImage: section.systemImage)
                                    .foregroundStyle(tokens.primaryText)
                            }
                            .listRowBackground(tokens.elevatedSurface)
                        }
                    }
                    .navigationTitle("我的")
                    .navigationDestination(for: ProfileSection.self) { section in
                        ProfileSectionDetail(section: section)
                    }
                    .scrollContentBackground(.hidden)
                    .background(tokens.background)
                    .tint(tokens.accent)
                }
            }
        }
    }
}

private struct ProfileSectionSidebar: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @Binding var selection: ProfileSection

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            Text("我的")
                .font(themeStore.uiFont(.title2, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .padding(.horizontal, 18)
                .padding(.top, 20)

            VStack(spacing: 4) {
                ForEach(ProfileSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.systemImage)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 22)
                            Text(section.title)
                                .font(themeStore.uiFont(.callout, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(selection == section ? tokens.accent : tokens.primaryText)
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(selection == section ? tokens.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(tokens.sidebarBackground)
    }
}

private struct ProfileSectionDetail: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isShowingConnectionSettings = false
    let section: ProfileSection

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(section.title, systemImage: section.systemImage)
                        .font(themeStore.uiFont(.title2, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Spacer()
                }

                switch section {
                case .runtime:
                    runtimeContent(tokens: tokens)
                case .models:
                    modelsContent(tokens: tokens)
                case .capabilities:
                    capabilitiesContent(tokens: tokens)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(tokens.background)
        .navigationTitle(section.title)
        .sheet(isPresented: $isShowingConnectionSettings) {
            NavigationStack {
                ConnectionSettingsView {
                    isShowingConnectionSettings = false
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") {
                            isShowingConnectionSettings = false
                        }
                    }
                }
            }
            .environment(\.themeSystemColorScheme, colorScheme)
        }
    }

    private func runtimeContent(tokens: ThemeTokens) -> some View {
        VStack(spacing: 10) {
            Button {
                isShowingConnectionSettings = true
            } label: {
                ProfileInfoRow(
                    systemImage: "desktopcomputer",
                    title: "连接 Mac",
                    value: appStore.connectionStatus.title,
                    detail: appStore.isConfigured ? appStore.endpoint : "扫码、手动连接、测试连接和忘记 Mac 都在这里处理",
                    tone: appStore.connectionStatus.isConnected ? tokens.success : tokens.warning,
                    trailingSystemImage: "chevron.right"
                )
            }
            .buttonStyle(.plain)
            ProfileInfoRow(
                systemImage: "sparkles",
                title: "Codex",
                value: "默认通道",
                detail: "会话工作区继续沿用当前运行逻辑",
                tone: tokens.accent
            )
            ProfileInfoRow(
                systemImage: "flask",
                title: "Claude",
                value: sessionStore.hasClaudeRuntimeChannel ? "已发现" : "实验通道",
                detail: "本轮只占位展示，不迁移配置入口",
                tone: sessionStore.hasClaudeRuntimeChannel ? tokens.success : tokens.secondaryText
            )
        }
    }

    private func modelsContent(tokens: ThemeTokens) -> some View {
        VStack(spacing: 10) {
            ProfileInfoRow(
                systemImage: "cpu",
                title: "模型列表",
                value: modelSummary,
                detail: "输入区的模型菜单暂时保持原位置",
                tone: tokens.accent
            )
            ProfileInfoRow(
                systemImage: "arrow.clockwise",
                title: "刷新模型",
                value: sessionStore.isRefreshingAppServerModels ? "刷新中" : "待接入",
                detail: "下一步再把真实刷新动作迁移到这里",
                tone: tokens.secondaryText
            )
        }
    }

    private func capabilitiesContent(tokens: ThemeTokens) -> some View {
        VStack(spacing: 10) {
            ProfileInfoRow(
                systemImage: "wand.and.stars",
                title: "Skills",
                value: "只读能力",
                detail: "现有能力清单暂时留在设置高级里",
                tone: tokens.accent
            )
            ProfileInfoRow(
                systemImage: "point.3.connected.trianglepath.dotted",
                title: "MCP",
                value: "只读配置",
                detail: "后续再迁移 Skills / MCP 列表",
                tone: tokens.accent
            )
        }
    }

    private var modelSummary: String {
        let count = sessionStore.appServerModelOptions.count
        return count == 0 ? "使用内置候选" : "\(count) 个模型"
    }
}

private struct ProfileInfoRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    let title: String
    let value: String
    let detail: String
    let tone: Color
    var trailingSystemImage: String? = nil

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tone.opacity(0.12))
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tone)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(value)
                        .font(themeStore.uiFont(.footnote, weight: .semibold))
                        .foregroundStyle(tone)
                }
                Text(detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.tertiaryText)
                    .padding(.top, 11)
            }
        }
        .padding(14)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }
}

private extension ConnectionStatus {
    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

struct WorkbenchLayout: Equatable {
    struct ColumnWidth: Equatable {
        let min: CGFloat
        let ideal: CGFloat
        let max: CGFloat
    }

    let projectColumn: ColumnWidth
    let inspectorColumn: ColumnWidth
    let titleMaxWidth: CGFloat
    let usesCompactNavigation: Bool
    let prefersDetailOnly: Bool
    let usesAttachedInspector: Bool

    init(containerWidth: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) {
        let isCompactWidth = horizontalSizeClass == .compact || containerWidth < 760
        let isTightPadWidth = containerWidth < 980

        if isCompactWidth {
            projectColumn = ColumnWidth(min: 220, ideal: 260, max: 300)
            // 手机导航栏同时有返回、连接状态、日志和设置按钮；标题必须主动让位，避免挤压工具按钮。
            titleMaxWidth = max(86, min(150, containerWidth - 250))
        } else if isTightPadWidth {
            projectColumn = ColumnWidth(min: 240, ideal: 280, max: 320)
            titleMaxWidth = 240
        } else {
            projectColumn = ColumnWidth(min: 280, ideal: 330, max: 380)
            titleMaxWidth = 340
        }

        inspectorColumn = containerWidth < 1280
            ? ColumnWidth(min: 280, ideal: 300, max: 320)
            : ColumnWidth(min: 300, ideal: 340, max: 380)

        // 三栏只在真正宽的横向空间里附着；窄窗口改用 sheet，保住会话阅读/输入区域。
        usesAttachedInspector = horizontalSizeClass != .compact && containerWidth >= 1180
        usesCompactNavigation = isCompactWidth
        prefersDetailOnly = isCompactWidth || containerWidth < 860
    }
}

private extension View {
    func sessionInspectorPresentation(isPresented: Binding<Bool>, layout: WorkbenchLayout) -> some View {
        modifier(SessionInspectorPresentation(isPresented: isPresented, layout: layout))
    }
}

private struct SessionInspectorPresentation: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var isPresented: Bool
    let layout: WorkbenchLayout

    @ViewBuilder
    func body(content: Content) -> some View {
        if layout.usesAttachedInspector {
            content.inspector(isPresented: $isPresented) {
                SessionInspectorView()
                    .inspectorColumnWidth(
                        min: layout.inspectorColumn.min,
                        ideal: layout.inspectorColumn.ideal,
                        max: layout.inspectorColumn.max
                    )
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                NavigationStack {
                    SessionInspectorView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") {
                                    isPresented = false
                                }
                            }
                        }
                }
                .presentationDetents(horizontalSizeClass == .compact ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct AgentWorkbenchTitle: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let maxWidth: CGFloat
    let horizontalOffset: CGFloat

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 2) {
            Text(primaryText)
                .font(themeStore.codeFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            HStack(spacing: 5) {
                if historyProgress != nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.tertiaryText)
                        .frame(width: 10, height: 10)
                }
                Text(secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .font(themeStore.codeFont(.caption2))
            .foregroundStyle(tokens.tertiaryText)
        }
        .frame(maxWidth: maxWidth)
        .offset(x: horizontalOffset)
        .accessibilityElement(children: .combine)
    }

    private var historyProgress: HistoryLoadProgress? {
        sessionStore.historyLoadProgress(sessionID: sessionStore.selectedSessionID)
    }

    private var primaryText: String {
        if let session = sessionStore.selectedSession {
            return session.project.isEmpty ? "工作区" : session.project
        }
        return sessionStore.selectedProject?.name ?? "工作区"
    }

    private var secondaryText: String {
        if let historyProgress {
            // 历史请求没有真实网络进度，标题区只保留轻量状态，避免 32% 这类假进度占据主内容。
            return "正在\(historyProgress.title)…"
        }
        if let session = sessionStore.selectedSession {
            return session.title.isEmpty ? session.dir : session.title
        }
        return sessionStore.selectedProject?.path ?? "请选择项目"
    }
}

struct StatusPill: View {
    enum Kind {
        case success
        case warning
        case neutral
    }

    let text: String
    let kind: Kind
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Text(text)
            .font(themeStore.uiFont(size: 12, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background(tokens: tokens))
            .foregroundStyle(foreground(tokens: tokens))
            .clipShape(Capsule())
    }

    private func background(tokens: ThemeTokens) -> Color {
        switch kind {
        case .success:
            return tokens.success.opacity(0.16)
        case .warning:
            return tokens.warning.opacity(0.18)
        case .neutral:
            return tokens.elevatedSurface
        }
    }

    private func foreground(tokens: ThemeTokens) -> Color {
        switch kind {
        case .success:
            return tokens.success
        case .warning:
            return tokens.warning
        case .neutral:
            return tokens.secondaryText
        }
    }
}
