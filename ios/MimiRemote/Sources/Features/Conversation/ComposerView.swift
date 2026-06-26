import AVFoundation
import AudioToolbox
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct ComposerChipItem: Identifiable {
    let id: String
    let text: String
    let symbol: String
    let tint: Color
}

enum VoiceInputLanguage: String, CaseIterable, Identifiable {
    case automatic
    case chineseSimplified
    case englishUS
    case japanese
    case korean

    static let storageKey = "voice.input.language"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "自动"
        case .chineseSimplified:
            return "中文"
        case .englishUS:
            return "English"
        case .japanese:
            return "日本語"
        case .korean:
            return "한국어"
        }
    }

    var localeCandidates: [Locale] {
        switch self {
        case .automatic:
            return [Locale(identifier: "zh_CN"), Locale.current]
        case .chineseSimplified:
            return [Locale(identifier: "zh_CN"), Locale.current]
        case .englishUS:
            return [Locale(identifier: "en_US"), Locale.current]
        case .japanese:
            return [Locale(identifier: "ja_JP"), Locale.current]
        case .korean:
            return [Locale(identifier: "ko_KR"), Locale.current]
        }
    }

    var transcriptionLanguageCode: String? {
        switch self {
        case .automatic:
            return nil
        case .chineseSimplified:
            return "zh"
        case .englishUS:
            return "en"
        case .japanese:
            return "ja"
        case .korean:
            return "ko"
        }
    }

    var transcriptionPrompt: String {
        switch self {
        case .automatic:
            return "这是一段给编程助手的口述指令，请准确转写，保留原始语言、技术术语和自然标点。"
        case .chineseSimplified:
            return "这是一段中文口述给编程助手的指令，请准确转写，保留技术术语、英文词和自然标点。"
        case .englishUS:
            return "This is an English dictated instruction to a coding assistant. Preserve technical terms and natural punctuation."
        case .japanese:
            return "これはコーディング支援への日本語の音声指示です。技術用語と自然な句読点を保って正確に書き起こしてください。"
        case .korean:
            return "코딩 도우미에게 말한 한국어 음성 지시입니다. 기술 용어와 자연스러운 문장 부호를 유지해 정확히 받아써 주세요."
        }
    }

    static func stored(_ rawValue: String) -> VoiceInputLanguage {
        VoiceInputLanguage(rawValue: rawValue) ?? .automatic
    }
}

struct ComposerView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var composerState = ComposerState()
    @StateObject private var voiceInput = VoiceInputController()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var manualInputKind: ManualInputKind = .localImage
    @State private var showsAddContentPanel = false
    @State private var showsManualInputSheet = false
    @State private var showsAdvancedOptionsSheet = false
    @State private var showsImageFileImporter = false
    @State private var previewingAttachment: CodexAppServerUserInput?
    @State private var goalEditor: ThreadGoalEditorDraft?
    @State private var isGoalStatusExpanded = false
    @State private var attachmentErrorMessage: String?
    @State private var isVoicePressActive = false
    @State private var isVoiceTranscribing = false
    @State private var measuredComposerTextHeight: CGFloat = 0
    @AppStorage("agentd.developerMode") private var developerModeEnabled = false
    @AppStorage(VoiceInputLanguage.storageKey) private var selectedVoiceLanguageID = VoiceInputLanguage.automatic.rawValue

    private static let minimumUsableVoiceDuration: TimeInterval = 0.35

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        // 外层不再画大方框：ConversationView 的底部 dock 已经提供了表面色和顶部分隔线，
        // 这里只保留一个真正的输入卡片，避免“框中框”的视觉堆叠。
        VStack(alignment: .leading, spacing: 10) {
            composerStatusArea
            activeGoalStatusBar
            pendingApprovalAction
            voiceErrorMessage
            voiceNoticeMessage
            attachmentErrorNotice
            attachmentStrip
            selectedTurnOptionsStrip
            composerCard(tokens: tokens)
            voiceKeyboardShortcutButton
        }
        .sheet(isPresented: $showsManualInputSheet) {
            ManualUserInputSheet(kind: manualInputKind) { input in
                composerState.addAttachment(input)
            }
        }
        .sheet(isPresented: $showsAdvancedOptionsSheet) {
            AdvancedTurnOptionsSheet(options: composerState.turnOptions) { options in
                composerState.turnOptions = options
            }
        }
        .sheet(item: $previewingAttachment) { item in
            AttachmentPreviewSheet(item: item)
                .environmentObject(themeStore)
        }
        .sheet(item: $goalEditor) { draft in
            ThreadGoalEditorSheet(draft: draft)
                .environmentObject(sessionStore)
                .environmentObject(themeStore)
        }
        .fileImporter(isPresented: $showsImageFileImporter, allowedContentTypes: [.image]) { result in
            showsAddContentPanel = false
            switch result {
            case .success(let url):
                loadImageFileAttachment(url)
            case .failure(let error):
                attachmentErrorMessage = userFacingAttachmentError(error)
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else {
                return
            }
            showsAddContentPanel = false
            loadPhotoAttachment(item)
        }
        .onChange(of: developerModeEnabled) { _, enabled in
            guard !enabled else {
                return
            }
            composerState.turnOptions = composerState.turnOptions.sanitizedForStandardComposer()
            showsAdvancedOptionsSheet = false
        }
        .task {
            await sessionStore.refreshAppServerModelOptions()
        }
        .onDisappear {
            voiceInput.stop()
            isVoicePressActive = false
            isVoiceTranscribing = false
            composerState.endVoiceInput()
        }
    }

    @discardableResult
    private func submitDraft() -> Bool {
        if composerState.isGoalModeSelected {
            return submitGoalDraft()
        }
        let options = developerModeEnabled ? composerState.turnOptions : composerState.turnOptions.sanitizedForStandardComposer()
        guard let submitted = composerState.takeDraftForSubmit(isLoading: sessionStore.isLoading, turnOptionsOverride: options) else {
            return false
        }
        Task {
            let accepted = await sessionStore.sendTurn(submitted.payload)
            if !accepted {
                await MainActor.run {
                    composerState.restore(submitted)
                }
            }
        }
        return true
    }

    @discardableResult
    private func submitGoalDraft() -> Bool {
        let options = developerModeEnabled ? composerState.turnOptions : composerState.turnOptions.sanitizedForStandardComposer()
        guard let submitted = composerState.takeDraftForSubmit(
            isLoading: sessionStore.isLoading || sessionStore.isUpdatingThreadGoal,
            turnOptionsOverride: options
        ) else {
            return false
        }
        let objective = submitted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            composerState.restore(submitted)
            return false
        }
        Task {
            let accepted = await sessionStore.startGoalTurn(payload: submitted.payload, objective: objective)
            if !accepted {
                await MainActor.run {
                    composerState.restore(submitted)
                }
            } else {
                await MainActor.run {
                    composerState.resetSendModeAfterSubmit()
                }
            }
        }
        return true
    }

    private var canSubmitDraft: Bool {
        if composerState.isGoalModeSelected {
            return canSubmitGoalDraft
        }
        return composerState.canSubmit(isLoading: sessionStore.isLoading)
    }

    private var canSubmitGoalDraft: Bool {
        composerState.hasNonWhitespaceDraft && !sessionStore.isLoading && !sessionStore.isUpdatingThreadGoal
    }

    private var isCompactComposer: Bool {
        horizontalSizeClass == .compact
    }

    @ViewBuilder
    private var composerStatusArea: some View {
        if let activity = sessionStore.selectedForegroundActivity {
            composerActivity(activity)
        }
        if !runtimeChipItems.isEmpty || sessionStore.selectedSession?.isRunning == true {
            HStack(spacing: 10) {
                if runtimeChipItems.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(runtimeChipItems, id: \.text) { item in
                                runtimeChip(item)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Ctrl-C / 停止 只在 turn 运行时才有意义，跟随“active turn”状态出现，
                // 不再常驻在输入操作行里占位、徒增灰色禁用按钮。
                if sessionStore.selectedSession?.isRunning == true {
                    runningControls
                }
            }
        }
    }

    private func runtimeChip(_ item: (text: String, symbol: String, tint: Color)) -> some View {
        Label(item.text, systemImage: item.symbol)
            .font(themeStore.uiFont(.caption, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(item.tint.opacity(0.12), in: Capsule())
            .foregroundStyle(item.tint)
    }

    private var runningControls: some View {
        HStack(spacing: 8) {
            Button {
                sessionStore.sendCtrlC()
            } label: {
                Label("Ctrl-C", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .accessibilityLabel("发送 Ctrl-C")

            Button(role: .destructive) {
                Task { await sessionStore.stopSelectedSession() }
            } label: {
                Label("停止", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("停止当前会话")
        }
        .controlSize(.small)
        .font(themeStore.uiFont(.caption, weight: .medium))
        .layoutPriority(1)
    }

    @ViewBuilder
    private var activeGoalStatusBar: some View {
        if let goal = sessionStore.selectedThreadGoal {
            ActiveGoalStatusBar(
                goal: goal,
                isExpanded: isGoalStatusExpanded,
                isUpdating: sessionStore.isUpdatingThreadGoal,
                errorMessage: sessionStore.threadGoalErrorMessage,
                onEdit: {
                    goalEditor = ThreadGoalEditorDraft(sessionID: goal.threadID, existing: goal)
                },
                onTogglePause: {
                    Task { await sessionStore.updateSelectedThreadGoalStatus(nextPrimaryGoalStatus(for: goal.status)) }
                },
                onComplete: {
                    Task { await sessionStore.updateSelectedThreadGoalStatus(.complete) }
                },
                onClear: {
                    Task { await sessionStore.clearSelectedThreadGoal() }
                },
                onToggleExpanded: {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isGoalStatusExpanded.toggle()
                    }
                }
            )
            .environmentObject(themeStore)
        }
    }

    private func nextPrimaryGoalStatus(for status: ThreadGoalStatus) -> ThreadGoalStatus {
        switch status {
        case .active:
            return .paused
        case .paused, .blocked, .usageLimited, .budgetLimited, .complete:
            return .active
        }
    }

    private func composerCard(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            composerTextArea(tokens: tokens)
            inlineVoiceRecordingStatus
            voiceReviewNotice
            composerToolbar(tokens: tokens)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(composerCardBorderColor(tokens), lineWidth: composerCardBorderWidth)
        }
    }

    private func composerTextArea(tokens: ThemeTokens) -> some View {
        ZStack(alignment: .topLeading) {
            ComposerTextView(
                text: $composerState.draft,
                font: composerUIFont,
                textColor: UIColor(tokens.primaryText),
                tintColor: UIColor(tokens.accent),
                minHeight: composerMinHeight,
                maxHeight: composerMaxHeight,
                onSubmit: { submitDraft() },
                onContentHeightChange: { height in
                    if abs(measuredComposerTextHeight - height) > 0.5 {
                        measuredComposerTextHeight = height
                    }
                },
                onVoiceShortcutPressChanged: { pressed in
                    if pressed {
                        beginHoldToTalk()
                    } else {
                        endHoldToTalk()
                    }
                }
            )
            .frame(height: composerTextHeight)

            if composerState.draft.isEmpty {
                // ComposerTextView 把 textContainerInset 归零，占位文案与正文同源，无需再补 padding。
                Text(composerPlaceholderText)
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(tokens.tertiaryText)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func composerCardBorderColor(_ tokens: ThemeTokens) -> Color {
        if voiceInput.isRecording {
            return Color.red.opacity(0.78)
        }
        if voiceInput.isPreparing || isVoicePressActive {
            return tokens.accent.opacity(0.62)
        }
        if isVoiceTranscribing {
            return tokens.accent.opacity(0.55)
        }
        return tokens.border
    }

    private var composerPlaceholderText: String {
        if composerState.isGoalModeSelected {
            return sessionStore.selectedThreadGoal == nil ? "描述目标任务" : "要求目标后续变更"
        }
        if sessionStore.selectedThreadGoal != nil {
            return "要求后续变更"
        }
        return "输入任务或后续指令"
    }

    private var composerCardBorderWidth: CGFloat {
        voiceInput.isRecording || voiceInput.isPreparing || isVoicePressActive ? 1.5 : 1
    }

    private func composerToolbar(tokens: ThemeTokens) -> some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                toolbarMenuRow
                    .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            voiceMicControl
            sendButton(showLabels: !isCompactComposer)
        }
    }

    @ViewBuilder
    private var toolbarMenuRow: some View {
        let menus = HStack(spacing: 8) {
            addContentButton
            goalButton
            voiceLanguageMenu
            permissionMenu
            runSettingsMenu
        }
        .font(themeStore.uiFont(.caption, weight: .medium))
        .controlSize(.small)

        if isCompactComposer {
            menus.labelStyle(.iconOnly)
        } else {
            menus
        }
    }

    private var voiceMicControl: some View {
        VoiceMicButton(
            isPreparing: voiceInput.isPreparing || (isVoicePressActive && !voiceInput.isRecording),
            isRecording: voiceInput.isRecording,
            isTranscribing: isVoiceTranscribing,
            isCompact: isCompactComposer,
            onPressChanged: { pressed in
                if pressed {
                    beginHoldToTalk()
                } else {
                    endHoldToTalk()
                }
            }
        )
        .layoutPriority(1)
    }

    private var voiceKeyboardShortcutButton: some View {
        Button {
            toggleVoiceInputFromKeyboard()
        } label: {
            EmptyView()
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityLabel(voiceInput.isRecording || isVoicePressActive || isVoiceTranscribing ? "结束语音输入" : "开始语音输入")
        .accessibilityHidden(true)
    }

    private var addContentButton: some View {
        Button {
            showsAddContentPanel.toggle()
        } label: {
            Label("添加", systemImage: "plus.circle")
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showsAddContentPanel, arrowEdge: .bottom) {
            AddContentPanel(
                selectedPhotoItem: $selectedPhotoItem,
                onPickImageFile: {
                    showsAddContentPanel = false
                    showsImageFileImporter = true
                },
                onManualInput: { kind in
                    openManualInput(kind)
                },
                onShortcut: { shortcut in
                    composerState.insertShortcut(shortcut)
                    showsAddContentPanel = false
                }
            )
            .environmentObject(themeStore)
            .presentationCompactAdaptation(.sheet)
        }
    }

    private var goalButton: some View {
        let selected = composerState.isGoalModeSelected
        return Button {
            composerState.toggleGoalMode()
        } label: {
            Label("目标", systemImage: "target")
        }
        .buttonStyle(.bordered)
        .tint(selected ? themeStore.tokens(for: colorScheme).accent : nil)
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .help(selected ? "关闭目标任务发送模式" : "将下一次发送设为目标任务")
        .accessibilityLabel("目标任务模式")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityHint("只切换发送模式，不会立即发送")
    }

    @ViewBuilder
    private var voiceReviewNotice: some View {
        if composerState.voiceDraftNeedsReview {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield")
                Text("语音草稿待确认")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(themeStore.uiFont(.caption, weight: .medium))
            .foregroundStyle(themeStore.tokens(for: colorScheme).accent)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(themeStore.tokens(for: colorScheme).accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(themeStore.tokens(for: colorScheme).accent.opacity(0.35))
            }
        }
    }

    private var selectedVoiceLanguage: VoiceInputLanguage {
        VoiceInputLanguage.stored(selectedVoiceLanguageID)
    }

    private var voiceLanguageMenu: some View {
        Menu {
            ForEach(VoiceInputLanguage.allCases) { language in
                Button {
                    selectedVoiceLanguageID = language.rawValue
                } label: {
                    Label(language.title, systemImage: selectedVoiceLanguage == language ? "checkmark" : "globe")
                }
            }
        } label: {
            Label(selectedVoiceLanguage.title, systemImage: "globe")
        }
        .buttonStyle(.bordered)
    }

    private var runSettingsMenu: some View {
        Menu {
            modelOptionsMenu
            reasoningOptionsMenu
            serviceTierOptionsMenu
            outputOptionsMenu
            if developerModeEnabled {
                Divider()
                Button {
                    showsAdvancedOptionsSheet = true
                } label: {
                    Label("高级选项", systemImage: "ellipsis.circle")
                }
            }
        } label: {
            Label("运行", systemImage: "gearshape")
        }
        .buttonStyle(.bordered)
    }

    private var modelOptionsMenu: some View {
        Menu {
            Button("默认") {
                composerState.turnOptions.model = nil
                composerState.turnOptions.modelProvider = nil
            }
            ForEach(modelOptionsForMenu) { option in
                Button(option.menuTitle) {
                    composerState.turnOptions.model = option.model
                    composerState.turnOptions.modelProvider = option.provider
                }
            }
            Divider()
            Button {
                Task { await sessionStore.refreshAppServerModelOptions(force: true) }
            } label: {
                Label(sessionStore.isRefreshingAppServerModels ? "刷新中" : "刷新模型列表", systemImage: "arrow.clockwise")
            }
            .disabled(sessionStore.isRefreshingAppServerModels)
        } label: {
            Label(composerState.turnOptions.model ?? "默认模型", systemImage: "cpu")
        }
    }

    private var reasoningOptionsMenu: some View {
        Menu {
            Button("默认") { composerState.turnOptions.reasoningEffort = nil }
            ForEach(CodexAppServerReasoningEffort.allCases) { effort in
                Button(effort.rawValue) { composerState.turnOptions.reasoningEffort = effort }
            }
        } label: {
            Label(composerState.turnOptions.reasoningEffort?.rawValue ?? "推理默认", systemImage: "brain.head.profile")
        }
    }

    private var serviceTierOptionsMenu: some View {
        Menu {
            Button("默认") { composerState.turnOptions.serviceTier = nil }
            Button("auto") { composerState.turnOptions.serviceTier = "auto" }
            Button("priority") { composerState.turnOptions.serviceTier = "priority" }
            Button("flex") { composerState.turnOptions.serviceTier = "flex" }
        } label: {
            Label(composerState.turnOptions.serviceTier ?? "速度默认", systemImage: "speedometer")
        }
    }

    private var outputOptionsMenu: some View {
        Menu {
            Section("摘要") {
                Button("默认") { composerState.turnOptions.reasoningSummary = nil }
                ForEach(CodexAppServerReasoningSummary.allCases) { summary in
                    Button(summary.rawValue) { composerState.turnOptions.reasoningSummary = summary }
                }
            }
            Section("人格") {
                Button("默认") { composerState.turnOptions.personality = nil }
                Button("none") { composerState.turnOptions.personality = CodexAppServerPersonality.none }
                Button("friendly") { composerState.turnOptions.personality = .friendly }
                Button("pragmatic") { composerState.turnOptions.personality = .pragmatic }
            }
        } label: {
            Label("摘要/人格", systemImage: "text.bubble")
        }
    }

    private var permissionMenu: some View {
        Menu {
            Section("权限模式") {
                ForEach(ComposerPermissionMode.allCases) { mode in
                    Button {
                        composerState.applyPermissionMode(mode)
                    } label: {
                        Label(
                            mode.title,
                            systemImage: composerState.permissionMode == mode ? "checkmark" : mode.systemImage
                        )
                    }
                    .accessibilityHint(mode.detail)
                }
            }
            Section("当前效果") {
                Text(composerState.permissionMode.detail)
                Text(permissionWireSummary)
            }
        } label: {
            Label(composerState.permissionMode.title, systemImage: composerState.permissionMode.systemImage)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("权限模式")
        .accessibilityValue(permissionTitle)
    }

    @ViewBuilder
    private var inlineVoiceRecordingStatus: some View {
        if isVoiceTranscribing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("模型转写中 · \(selectedVoiceLanguage.title)")
                    .lineLimit(1)
            }
            .font(themeStore.uiFont(.caption, weight: .medium))
            .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(themeStore.tokens(for: colorScheme).elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(themeStore.tokens(for: colorScheme).border)
            }
        } else if voiceInput.isRecording {
            HStack(spacing: 8) {
                VoiceWaveformView(meter: voiceInput.levelMeter, isActive: true, tint: .red)
                    .frame(width: isCompactComposer ? 88 : 124, height: 30)
                Text("现在说话，松手转写 · \(selectedVoiceLanguage.title)")
                    .lineLimit(1)
            }
            .font(themeStore.uiFont(.caption, weight: .medium))
            .foregroundStyle(.red)
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(Color.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.58))
            }
            .shadow(color: Color.red.opacity(0.12), radius: 10, y: 3)
        } else if voiceInput.isPreparing || isVoicePressActive {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(themeStore.tokens(for: colorScheme).accent)
                Text("正在准备麦克风，出现红色波形后再说 · \(selectedVoiceLanguage.title)")
                    .lineLimit(1)
            }
            .font(themeStore.uiFont(.caption, weight: .medium))
            .foregroundStyle(themeStore.tokens(for: colorScheme).accent)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(themeStore.tokens(for: colorScheme).accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(themeStore.tokens(for: colorScheme).accent.opacity(0.40))
            }
        }
    }

    private var modelOptionsForMenu: [CodexAppServerModelOption] {
        sessionStore.appServerModelOptions.isEmpty ? CodexAppServerModelOption.builtInFallback : sessionStore.appServerModelOptions
    }

    @ViewBuilder
    private var selectedTurnOptionsStrip: some View {
        let items = turnOptionChipItems
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(items) { item in
                        Label(item.text, systemImage: item.symbol)
                            .font(themeStore.uiFont(.caption, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundStyle(item.tint)
                            .background(item.tint.opacity(0.12), in: Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("当前运行选项")
        }
    }

    private var turnOptionChipItems: [ComposerChipItem] {
        var items: [ComposerChipItem] = []
        if composerState.isGoalModeSelected {
            items.append(ComposerChipItem(id: "send-goal", text: "目标任务", symbol: "target", tint: themeStore.tokens(for: colorScheme).accent))
        }
        items.append(ComposerChipItem(id: "model", text: selectedModelSummaryTitle, symbol: "cpu", tint: themeStore.tokens(for: colorScheme).accent))
        items.append(
            ComposerChipItem(
                id: "permission",
                text: composerState.permissionMode.chipTitle,
                symbol: composerState.permissionMode.systemImage,
                tint: permissionTint
            )
        )

        if let effort = composerState.turnOptions.reasoningEffort {
            items.append(ComposerChipItem(id: "effort", text: "推理 \(effort.rawValue)", symbol: "brain.head.profile", tint: .secondary))
        }
        if let tier = composerState.turnOptions.serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty {
            items.append(ComposerChipItem(id: "tier", text: "速度 \(tier)", symbol: "speedometer", tint: .secondary))
        }
        if let summary = composerState.turnOptions.reasoningSummary {
            items.append(ComposerChipItem(id: "summary", text: "摘要 \(summary.rawValue)", symbol: "text.bubble", tint: .secondary))
        }
        if let personality = composerState.turnOptions.personality {
            items.append(ComposerChipItem(id: "personality", text: "人格 \(personality.rawValue)", symbol: "person.crop.circle", tint: .secondary))
        }
        if developerModeEnabled, hasAdvancedTurnOptions {
            items.append(ComposerChipItem(id: "advanced", text: "高级已应用", symbol: "ellipsis.circle", tint: .orange))
        }
        return items
    }

    private var selectedModelSummaryTitle: String {
        guard let model = composerState.turnOptions.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return "默认模型"
        }
        if let option = modelOptionsForMenu.first(where: { item in
            item.model == model && (composerState.turnOptions.modelProvider == nil || item.provider == composerState.turnOptions.modelProvider)
        }) {
            return developerModeEnabled ? option.menuTitle : option.title
        }
        if developerModeEnabled, let provider = composerState.turnOptions.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
            return "\(model) · \(provider)"
        }
        return model
    }

    private var hasAdvancedTurnOptions: Bool {
        composerState.turnOptions.config != nil ||
            composerState.turnOptions.baseInstructions != nil ||
            composerState.turnOptions.developerInstructions != nil ||
            composerState.turnOptions.outputSchema != nil ||
            composerState.turnOptions.serviceName != nil ||
            composerState.turnOptions.sessionStartSource != nil ||
            composerState.turnOptions.threadSource != nil
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !composerState.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(composerState.attachments.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 6) {
                            Button {
                                previewingAttachment = item
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: attachmentSymbol(for: item))
                                    Text(item.previewText)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!canPreviewAttachment(item))

                            Button {
                                composerState.removeAttachment(at: index)
                                if previewingAttachment?.id == item.id {
                                    previewingAttachment = nil
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .accessibilityLabel("移除")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(themeStore.uiFont(.caption))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(themeStore.tokens(for: colorScheme).elevatedSurface, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(themeStore.tokens(for: colorScheme).border)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentErrorNotice: some View {
        if let attachmentErrorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(attachmentErrorMessage)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var voiceErrorMessage: some View {
        if let errorMessage = voiceInput.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(errorMessage)
                    .lineLimit(2)
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var voiceNoticeMessage: some View {
        if let noticeMessage = voiceInput.noticeMessage {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                Text(noticeMessage)
                    .lineLimit(2)
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(themeStore.tokens(for: colorScheme).accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runtimeChipItems: [(text: String, symbol: String, tint: Color)] {
        guard let session = sessionStore.selectedSession else {
            return []
        }
        var items: [(text: String, symbol: String, tint: Color)] = []
        if session.activeTurnID != nil {
            items.append(("active turn", "bolt.fill", .green))
        }
        if let lastSeq = session.lastSeq {
            items.append(("seq \(lastSeq)", "number", .secondary))
        }
        if let usage = session.usage?.compactText {
            items.append((usage, "gauge.with.dots.needle.33percent", .secondary))
        }
        if let rateLimit = session.rateLimit?.compactText {
            items.append((rateLimit, "speedometer", .secondary))
        }
        return items
    }

    @ViewBuilder
    private var pendingApprovalAction: some View {
        if let approval = sessionStore.selectedSession?.pendingApproval {
            PendingApprovalActionCard(
                approval: approval,
                isSendingDecision: sessionStore.isApprovalDecisionPending(approval),
                onApprove: { sessionStore.decideApproval(approval, accept: true) },
                onDecline: { sessionStore.decideApproval(approval, accept: false) }
            )
        }
    }

    private func sendButton(showLabels: Bool) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let isGoalMode = composerState.isGoalModeSelected
        let title = composerState.voiceDraftNeedsReview ? (isGoalMode ? "确认目标" : "确认发送") : (isGoalMode ? "发送目标" : "发送")
        let symbol = composerState.voiceDraftNeedsReview ? "checkmark.circle.fill" : (isGoalMode ? "target" : "paperplane.fill")
        let enabled = canSubmitDraft

        // 自绘成与“按住说话”同高同圆角的实心主按钮，让语音/发送成为右侧一组协调的主操作，
        // 而不是一个系统 prominent 小按钮配一个自定义大胶囊那种割裂感。
        return Button {
            submitDraft()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(themeStore.uiFont(size: 17, weight: .bold))
                if showLabels {
                    Text(title)
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(enabled ? Color.white : tokens.tertiaryText)
            .frame(height: 44)
            .padding(.horizontal, showLabels ? 18 : 0)
            .frame(minWidth: 44)
            .background(
                enabled ? tokens.accent : tokens.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if !enabled {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tokens.border)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!enabled)
        .accessibilityLabel(isGoalMode ? "发送目标任务" : (composerState.voiceDraftNeedsReview ? "确认发送语音草稿" : "发送"))
    }

    private var permissionTitle: String {
        "\(composerState.permissionMode.title) · \(composerState.turnOptions.sandboxMode.title)"
    }

    private var permissionWireSummary: String {
        "\(composerState.turnOptions.approvalPolicy.rawValue) · \(composerState.turnOptions.approvalsReviewer)"
    }

    private var permissionTint: Color {
        switch composerState.permissionMode {
        case .requestApproval:
            return themeStore.tokens(for: colorScheme).accent
        case .readOnly:
            return .secondary
        case .autoApprove:
            return .green
        case .fullAccess:
            return .red
        }
    }

    private var composerMinHeight: CGFloat {
        if isCompactComposer {
            return 60
        }
        return 72
    }

    private var composerMaxHeight: CGFloat {
        if isCompactComposer {
            return 190
        }
        return 260
    }

    private var composerTextHeight: CGFloat {
        let measured = measuredComposerTextHeight > 0 ? measuredComposerTextHeight : composerMinHeight
        return min(max(measured, composerMinHeight), composerMaxHeight)
    }

    private var composerUIFont: UIFont {
        let size = themeStore.scaledFontSize(17)
        let base = UIFont.systemFont(ofSize: size)
        let design: UIFontDescriptor.SystemDesign
        switch themeStore.uiFontPreset {
        case .system:
            design = .default
        case .rounded:
            design = .rounded
        case .serif:
            design = .serif
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private func composerActivity(_ activity: SessionForegroundActivity) -> some View {
        HStack(spacing: 7) {
            if activity.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.green)
            } else {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
            }
            Text(activity.title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(themeStore.uiFont(.caption, weight: .medium))
        .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
    }

    private func openManualInput(_ kind: ManualInputKind) {
        manualInputKind = kind
        showsAddContentPanel = false
        showsManualInputSheet = true
    }

    private func beginHoldToTalk() {
        guard !isVoicePressActive && !voiceInput.isPreparing && !voiceInput.isRecording && !isVoiceTranscribing else {
            return
        }
        isVoicePressActive = true
        composerState.beginVoiceInput()
        let language = selectedVoiceLanguage
        voiceInput.start { recording in
            isVoicePressActive = false
            guard let recording else {
                composerState.endVoiceInput()
                return
            }
            Task {
                await transcribeVoiceRecording(recording, language: language)
            }
        }
    }

    private func endHoldToTalk() {
        guard isVoicePressActive || voiceInput.isPreparing || voiceInput.isRecording else {
            return
        }
        let releasedBeforeRecording = voiceInput.isPreparing && !voiceInput.isRecording
        isVoicePressActive = false
        voiceInput.stop()
        if releasedBeforeRecording {
            voiceInput.setErrorMessage("麦克风还没准备好，请按住到出现“正在听”后再说")
        }
    }

    private func toggleVoiceInputFromKeyboard() {
        guard !isVoiceTranscribing else {
            return
        }
        if isVoicePressActive || voiceInput.isRecording {
            endHoldToTalk()
        } else {
            beginHoldToTalk()
        }
    }

    @MainActor
    private func transcribeVoiceRecording(_ recording: VoiceRecordingResult, language: VoiceInputLanguage) async {
        isVoiceTranscribing = true
        voiceInput.setErrorMessage(nil)
        defer {
            isVoiceTranscribing = false
            composerState.endVoiceInput()
            try? FileManager.default.removeItem(at: recording.fileURL)
        }
        do {
            async let dataTask = Self.voiceRecordingData(recording.fileURL)
            async let durationTask = Self.safeVoiceRecordingDuration(recording.fileURL)
            let data = try await dataTask
            let assetDuration = await durationTask
            let usableDuration = max(recording.recordedDuration, assetDuration)
            if data.count < 1_024 || usableDuration < Self.minimumUsableVoiceDuration {
                voiceInput.setErrorMessage(shortVoiceRecordingMessage(recording: recording, usableDuration: usableDuration))
                return
            }
            let response = try await sessionStore.transcribeVoice(
                filename: recording.fileURL.lastPathComponent,
                contentType: "audio/mp4",
                audioData: data,
                language: language.transcriptionLanguageCode,
                prompt: language.transcriptionPrompt
            )
            composerState.applyVoiceTranscript(response.text)
        } catch {
            voiceInput.setErrorMessage(userFacingVoiceTranscriptionError(error, recording: recording))
        }
    }

    nonisolated private static func voiceRecordingData(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    nonisolated private static func safeVoiceRecordingDuration(_ url: URL) async -> TimeInterval {
        (try? await voiceRecordingDuration(url)) ?? 0
    }

    private func shortVoiceRecordingMessage(recording: VoiceRecordingResult, usableDuration: TimeInterval) -> String {
        // 区分“用户真的很快松手”和“按住了但录音器实际采样很短”，避免把启动延迟误报成没按够 1 秒。
        if recording.pressDuration >= 0.9 && usableDuration < Self.minimumUsableVoiceDuration {
            return "麦克风启动较慢，刚才录到的声音太短，请等“正在听”后再说"
        }
        return "按得有点短，请按住说完整句再松开"
    }

    nonisolated private static func voiceRecordingDuration(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func userFacingVoiceTranscriptionError(_ error: Error, recording: VoiceRecordingResult? = nil) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return "语音转写失败，请稍后重试"
        }
        if message.localizedCaseInsensitiveContains("API Key") {
            return message
        }
        if message.contains("没有识别到语音内容") || message.contains("按住说话至少 1 秒") {
            if let recording, recording.pressDuration >= 0.9 {
                return "没有识别到清晰语音，请靠近麦克风并说完整句后再松手"
            }
            return "没有识别到清晰语音，请按住说完整句后再松手"
        }
        return "语音转写失败：\(message)"
    }

    private func loadPhotoAttachment(_ item: PhotosPickerItem) {
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    return
                }
                let url = await Task.detached(priority: .userInitiated) {
                    let encoded = Self.compressedImageData(from: data) ?? data
                    return "data:image/jpeg;base64,\(encoded.base64EncodedString())"
                }.value
                await MainActor.run {
                    attachmentErrorMessage = nil
                    composerState.addAttachment(.image(url: url, detail: .auto))
                    selectedPhotoItem = nil
                }
            } catch {
                await MainActor.run {
                    attachmentErrorMessage = userFacingAttachmentError(error)
                    selectedPhotoItem = nil
                }
            }
        }
    }

    private func loadImageFileAttachment(_ url: URL) {
        Task {
            do {
                let data = try Self.readSecurityScopedFile(url)
                let inlineURL = await Task.detached(priority: .userInitiated) {
                    let encoded = Self.compressedImageData(from: data) ?? data
                    return "data:image/jpeg;base64,\(encoded.base64EncodedString())"
                }.value
                await MainActor.run {
                    attachmentErrorMessage = nil
                    composerState.addAttachment(.image(url: inlineURL, detail: .auto))
                }
            } catch {
                await MainActor.run {
                    attachmentErrorMessage = userFacingAttachmentError(error)
                }
            }
        }
    }

    nonisolated private static func readSecurityScopedFile(_ url: URL) throws -> Data {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try Data(contentsOf: url)
    }

    nonisolated private static func compressedImageData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else {
            return nil
        }
        let maxDimension: CGFloat = 1_280
        let largestSide = max(image.size.width, image.size.height)
        let scale = largestSide > maxDimension ? maxDimension / largestSide : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        // iPad 侧只负责把截图/照片作为上下文传给 app-server；先降采样再 JPEG 编码，
        // 避免原图 base64 把 SwiftUI state、WebSocket payload 和内存峰值一起撑大。
        return resized.jpegData(compressionQuality: 0.82)
    }

    private func canPreviewAttachment(_ item: CodexAppServerUserInput) -> Bool {
        switch item {
        case .image, .localImage:
            return true
        case .text, .skill, .mention:
            return false
        }
    }

    private func userFacingAttachmentError(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "图片读取失败" : "图片读取失败：\(message)"
    }

    private func attachmentSymbol(for item: CodexAppServerUserInput) -> String {
        switch item {
        case .image, .localImage:
            return "photo"
        case .skill:
            return "wand.and.stars"
        case .mention:
            return "at"
        case .text:
            return "text.alignleft"
        }
    }
}

private struct ActiveGoalStatusBar: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let goal: ThreadGoal
    let isExpanded: Bool
    let isUpdating: Bool
    let errorMessage: String?
    let onEdit: () -> Void
    let onTogglePause: () -> Void
    let onComplete: () -> Void
    let onClear: () -> Void
    let onToggleExpanded: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            ViewThatFits(in: .horizontal) {
                horizontalHeader(tokens: tokens)
                verticalHeader(tokens: tokens)
            }

            if isExpanded {
                Divider()
                expandedDetails(tokens: tokens)
            }

            if let errorMessage = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !errorMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(errorMessage)
                        .lineLimit(2)
                }
                .font(themeStore.uiFont(.caption2, weight: .medium))
                .foregroundStyle(tokens.warning)
                .padding(.top, isExpanded ? 0 : 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(statusTint.opacity(0.28))
        }
        .accessibilityElement(children: .contain)
    }

    private func horizontalHeader(tokens: ThemeTokens) -> some View {
        HStack(alignment: .center, spacing: 10) {
            statusIcon
            summaryText(tokens: tokens)
            Spacer(minLength: 8)
            goalActionButtons(tokens: tokens)
        }
    }

    private func verticalHeader(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                statusIcon
                summaryText(tokens: tokens)
                Spacer(minLength: 8)
                expandButton(tokens: tokens)
            }
            goalActionButtons(tokens: tokens, includesExpandButton: false)
        }
    }

    private var statusIcon: some View {
        Image(systemName: "target")
            .font(themeStore.uiFont(size: 15, weight: .bold))
            .foregroundStyle(statusTint)
            .frame(width: 30, height: 30)
            .background(statusTint.opacity(0.14), in: Circle())
    }

    private func summaryText(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(headerTitle)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                Text(goal.status.displayText)
                    .font(themeStore.uiFont(.caption2, weight: .bold))
                    .foregroundStyle(statusTint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusTint.opacity(0.13), in: Capsule())
            }

            Text(goal.objective)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(isExpanded ? 3 : 1)

            HStack(spacing: 8) {
                if goal.timeUsedSeconds > 0 {
                    Label(goal.elapsedText, systemImage: "timer")
                }
                Label(goal.progressText, systemImage: "gauge.with.dots.needle.33percent")
            }
            .font(themeStore.uiFont(.caption2, weight: .medium))
            .foregroundStyle(tokens.secondaryText)
            .lineLimit(1)
        }
        .layoutPriority(1)
    }

    private func goalActionButtons(tokens: ThemeTokens, includesExpandButton: Bool = true) -> some View {
        HStack(spacing: 5) {
            if isUpdating {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
            }
            goalActionButton(
                title: "编辑目标",
                systemImage: "pencil",
                tint: tokens.secondaryText,
                isDisabled: isUpdating,
                action: onEdit
            )
            goalActionButton(
                title: primaryStatusActionTitle,
                systemImage: primaryStatusActionSymbol,
                tint: statusTint,
                isDisabled: isUpdating,
                action: onTogglePause
            )
            goalActionButton(
                title: "标记完成",
                systemImage: "checkmark.circle",
                tint: .green,
                isDisabled: isUpdating || goal.status == .complete,
                action: onComplete
            )
            goalActionButton(
                title: "清除目标",
                systemImage: "trash",
                tint: .red,
                isDisabled: isUpdating,
                action: onClear
            )
            if includesExpandButton {
                expandButton(tokens: tokens)
            }
        }
    }

    private func expandButton(tokens: ThemeTokens) -> some View {
        goalActionButton(
            title: isExpanded ? "收起目标" : "展开目标",
            systemImage: isExpanded ? "chevron.up" : "chevron.down",
            tint: tokens.secondaryText,
            isDisabled: false,
            action: onToggleExpanded
        )
    }

    private func goalActionButton(
        title: String,
        systemImage: String,
        tint: Color,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 14, weight: .semibold))
                .foregroundStyle(isDisabled ? themeStore.tokens(for: colorScheme).tertiaryText : tint)
                .frame(width: 30, height: 30)
                .background(themeStore.tokens(for: colorScheme).elevatedSurface.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(themeStore.tokens(for: colorScheme).border.opacity(0.75))
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private func expandedDetails(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            goalDetailRow(symbol: "circle.dashed", title: "状态", value: goal.status.displayText, tokens: tokens)
            goalDetailRow(symbol: "gauge.with.dots.needle.33percent", title: "进度", value: goal.progressText, tokens: tokens)
            if goal.timeUsedSeconds > 0 {
                goalDetailRow(symbol: "timer", title: "用时", value: goal.elapsedText, tokens: tokens)
            }
            if let updatedAt = goal.updatedAt {
                goalDetailRow(symbol: "clock", title: "更新", value: updatedAt.formatted(date: .omitted, time: .shortened), tokens: tokens)
            }
        }
    }

    private func goalDetailRow(symbol: String, title: String, value: String, tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
            Text(title)
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 34, alignment: .leading)
            Text(value)
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
        }
        .font(themeStore.uiFont(.caption2, weight: .medium))
    }

    private var headerTitle: String {
        goal.status == .complete ? "已完成目标" : "进行中的目标"
    }

    private var primaryStatusActionTitle: String {
        goal.status == .active ? "暂停目标" : "继续目标"
    }

    private var primaryStatusActionSymbol: String {
        goal.status == .active ? "pause.circle" : "play.circle"
    }

    private var statusTint: Color {
        switch goal.status {
        case .active:
            return .green
        case .paused:
            return .secondary
        case .blocked, .usageLimited, .budgetLimited:
            return .orange
        case .complete:
            return .blue
        }
    }
}

private struct AttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewURL: URL?
    @State private var previewingLocalImagePath: String?
    @State private var localImagePreviewError: String?

    let item: CodexAppServerUserInput

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    previewContent(tokens: tokens)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(tokens.surface)
            .navigationTitle("附件预览")
            .navigationBarTitleDisplayMode(.inline)
            .quickLookPreview($previewURL)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func previewContent(tokens: ThemeTokens) -> some View {
        switch item {
        case .image(let url, _):
            if let image = Self.image(fromDataURL: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let remoteURL = URL(string: url),
                      let scheme = remoteURL.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 180)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    case .failure:
                        previewMessage("图片加载失败", detail: url, tokens: tokens)
                    @unknown default:
                        previewMessage("图片加载失败", detail: url, tokens: tokens)
                    }
                }
            } else {
                previewMessage("无法预览这个图片引用", detail: url, tokens: tokens)
            }
        case .localImage(let path, _):
            localImagePreview(path: path, tokens: tokens)
        case .text(let text, _):
            previewMessage("文本附件", detail: text, tokens: tokens)
        case .skill(let name, let path):
            previewMessage("$\(name)", detail: path, tokens: tokens)
        case .mention(let name, let path):
            previewMessage("@\(name)", detail: path, tokens: tokens)
        }
    }

    private func localImagePreview(path: String, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            previewMessage(
                "本机图片路径",
                detail: path + "\n发送时由本机 agentd 读取；也可以通过 agentd 安全读取授权范围内的文件并用 QuickLook 预览。",
                tokens: tokens
            )
            Button {
                Task { await previewLocalImage(path: path) }
            } label: {
                if previewingLocalImagePath == path {
                    Label("正在预览", systemImage: "hourglass")
                } else {
                    Label("预览文件", systemImage: "eye")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(previewingLocalImagePath != nil || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let localImagePreviewError {
                Text(localImagePreviewError)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func previewLocalImage(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            localImagePreviewError = "本机路径为空，无法预览。"
            return
        }

        previewingLocalImagePath = targetPath
        localImagePreviewError = nil
        defer {
            if previewingLocalImagePath == targetPath {
                previewingLocalImagePath = nil
            }
        }
        do {
            previewURL = try await sessionStore.previewFile(path: targetPath)
        } catch {
            localImagePreviewError = userFacingPreviewError(error)
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

    private func previewMessage(_ title: String, detail: String, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "photo")
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(detail)
                .font(themeStore.codeFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func image(fromDataURL value: String) -> UIImage? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("data:image/"),
              let comma = trimmed.firstIndex(of: ",") else {
            return nil
        }
        let payload = trimmed[trimmed.index(after: comma)...]
        guard let data = Data(base64Encoded: String(payload), options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return UIImage(data: data)
    }
}

private struct AddContentPanel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selectedPhotoItem: PhotosPickerItem?

    let onPickImageFile: () -> Void
    let onManualInput: (ManualInputKind) -> Void
    let onShortcut: (String) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            panelSection("图片") {
                LazyVGrid(columns: columns, spacing: 8) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        panelActionLabel("图片", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onPickImageFile()
                    } label: {
                        panelActionLabel("文件图片", systemImage: "doc.viewfinder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onManualInput(.localImage)
                    } label: {
                        panelActionLabel("本机图片", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onManualInput(.imageURL)
                    } label: {
                        panelActionLabel("图片 URL", systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                }
            }

            panelSection("快捷短语") {
                Menu {
                    ForEach(Self.shortcuts, id: \.self) { shortcut in
                        Button(shortcut) {
                            onShortcut(shortcut)
                        }
                    }
                } label: {
                    panelActionLabel("快捷短语", systemImage: "bolt")
                }
                .buttonStyle(.bordered)
            }

            panelSection("引用") {
                LazyVGrid(columns: columns, spacing: 8) {
                    Button {
                        onManualInput(.skill)
                    } label: {
                        panelActionLabel("Skill", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onManualInput(.mention)
                    } label: {
                        panelActionLabel("Mention", systemImage: "at")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .font(themeStore.uiFont(.callout))
        .padding(16)
        .frame(maxWidth: 360)
        .background(tokens.surface)
    }

    private func panelSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            content()
        }
    }

    private func panelActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 30)
    }

    private static let shortcuts = [
        "检查这段实现并给出风险",
        "实现这个功能并补测试",
        "只做最小可运行版本，避免过度设计",
        "解释失败日志并给修复方案"
    ]
}

private struct VoiceMicButton: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPressed = false

    let isPreparing: Bool
    let isRecording: Bool
    let isTranscribing: Bool
    let isCompact: Bool
    let onPressChanged: (Bool) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let isActive = isPreparing || isRecording || isTranscribing
        let foreground = isRecording ? Color.red : tokens.accent
        let background = isRecording ? Color.red.opacity(0.20) : tokens.accent.opacity(isActive ? 0.14 : 0.10)
        let border = isRecording ? Color.red.opacity(0.72) : tokens.accent.opacity(isActive ? 0.54 : 0.42)

        HStack(spacing: 8) {
            if isPreparing {
                ProgressView()
                    .controlSize(.small)
                    .tint(foreground)
            } else {
                Image(systemName: isTranscribing ? "wand.and.stars" : isRecording ? "waveform.circle.fill" : "mic.fill")
                    .font(themeStore.uiFont(size: 18, weight: .bold))
            }
            if !isCompact {
                Text(buttonTitle)
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .foregroundStyle(foreground)
        .frame(width: isCompact ? 44 : 132, height: 44)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(border)
        }
        .shadow(color: isRecording ? Color.red.opacity(0.18) : .clear, radius: 10, y: 3)
        .scaleEffect(isActive ? 1.04 : 1)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 放在横向 ScrollView 外面，长按手势不会和工具栏滚动相互抢占。
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else {
                        return
                    }
                    isPressed = true
                    onPressChanged(true)
                }
                .onEnded { _ in
                    guard isPressed else {
                        return
                    }
                    isPressed = false
                    onPressChanged(false)
                }
        )
        .onDisappear {
            guard isPressed else {
                return
            }
            isPressed = false
            onPressChanged(false)
        }
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("按住把语音转写到草稿")
    }

    private var buttonTitle: String {
        if isTranscribing {
            return "转写中"
        }
        if isRecording {
            return "松手转写"
        }
        if isPreparing {
            return "准备中"
        }
        return "按住说话"
    }

    private var accessibilityTitle: String {
        if isRecording {
            return "正在录音，松手结束"
        }
        if isPreparing {
            return "正在准备麦克风"
        }
        return isTranscribing ? "正在转写语音" : "按住说话"
    }
}

private struct VoiceWaveformView: View {
    @ObservedObject var meter: VoiceLevelMeter
    let isActive: Bool
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let samples = Array(meter.samples.enumerated())
            let spacing: CGFloat = 3
            let count = max(samples.count, 1)
            let availableWidth = max(0, proxy.size.width - spacing * CGFloat(max(count - 1, 0)))
            let barWidth = max(3, min(5, availableWidth / CGFloat(count)))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(samples, id: \.offset) { index, level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(isActive ? 0.95 : 0.45), tint.opacity(isActive ? 0.62 : 0.28)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: barWidth, height: barHeight(index: index, level: level, maxHeight: proxy.size.height))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func barHeight(index: Int, level: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 4
        let usable = max(0, maxHeight - minHeight)
        guard isActive else {
            // 静止时给一点高低错落，避免看起来像坏掉的直线。
            return minHeight + (index.isMultiple(of: 2) ? 4 : 0)
        }
        let visibleLevel = max(level, index.isMultiple(of: 3) ? 0.14 : 0.08)
        return minHeight + pow(visibleLevel, 0.72) * usable
    }
}

@MainActor
private final class VoiceLevelMeter: ObservableObject {
    static let barCount = 16

    @Published private(set) var samples: [CGFloat] = Array(repeating: 0, count: VoiceLevelMeter.barCount)

    func push(_ level: CGFloat) {
        var next = samples
        next.removeFirst()
        next.append(pow(max(0, min(1, level)), 0.62))
        samples = next
    }

    func prepareForRecording() {
        // 录音器刚启动时 meter 还没吐出第一帧；先给一个低幅度基线，用户按下后立刻能看到反馈。
        samples = (0..<Self.barCount).map { index in
            index.isMultiple(of: 3) ? 0.18 : 0.10
        }
    }

    func reset() {
        samples = Array(repeating: 0, count: VoiceLevelMeter.barCount)
    }
}

@MainActor
private enum VoiceHaptics {
    private static let recordingStartGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private static let recordingReadyGenerator = UINotificationFeedbackGenerator()

    static func prepareRecordingStarted() {
        recordingStartGenerator.prepare()
        recordingReadyGenerator.prepare()
    }

    static func recordingStarted() {
        // 语音输入的唯一震动锚点：只有录音器已经开始采样后才震动。
        // 用户感受到这次反馈，就可以立即开口。
        recordingStartGenerator.impactOccurred(intensity: 1.0)
        recordingReadyGenerator.notificationOccurred(.success)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        recordingStartGenerator.prepare()
        recordingReadyGenerator.prepare()
    }
}

private struct ManualUserInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ManualInputKind
    @State private var name = ""
    @State private var pathOrURL = ""

    let onAdd: (CodexAppServerUserInput) -> Void

    init(kind: ManualInputKind, onAdd: @escaping (CodexAppServerUserInput) -> Void) {
        _kind = State(initialValue: kind)
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) {
                    ForEach(ManualInputKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                if kind.requiresName {
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField(kind.valuePlaceholder, text: $pathOrURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("添加引用")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        if let input {
                            onAdd(input)
                            dismiss()
                        }
                    }
                    .disabled(input == nil)
                }
            }
        }
    }

    private var input: CodexAppServerUserInput? {
        let value = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .imageURL:
            return .image(url: value, detail: .auto)
        case .localImage:
            return .localImage(path: value, detail: .auto)
        case .skill:
            guard !title.isEmpty else {
                return nil
            }
            return .skill(name: title, path: value)
        case .mention:
            guard !title.isEmpty else {
                return nil
            }
            return .mention(name: title, path: value)
        }
    }
}

private enum ManualInputKind: String, CaseIterable, Identifiable {
    case imageURL
    case localImage
    case skill
    case mention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imageURL:
            return "图片 URL"
        case .localImage:
            return "本机图片"
        case .skill:
            return "Skill"
        case .mention:
            return "Mention"
        }
    }

    var requiresName: Bool {
        switch self {
        case .skill, .mention:
            return true
        case .imageURL, .localImage:
            return false
        }
    }

    var valuePlaceholder: String {
        switch self {
        case .imageURL:
            return "https://... 或 data:image/..."
        case .localImage:
            return "app-server 可读取的绝对路径"
        case .skill, .mention:
            return "allowlist 内的路径"
        }
    }
}

private struct AdvancedTurnOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CodexAppServerTurnOptions
    @State private var configText: String
    @State private var outputSchemaText: String
    @State private var errorMessage: String?

    let onSave: (CodexAppServerTurnOptions) -> Void

    init(options: CodexAppServerTurnOptions, onSave: @escaping (CodexAppServerTurnOptions) -> Void) {
        _draft = State(initialValue: options)
        _configText = State(initialValue: Self.jsonText(from: options.config))
        _outputSchemaText = State(initialValue: Self.jsonText(from: options.outputSchema))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模型") {
                    TextField("Model", text: optionalStringBinding(\.model))
                    TextField("Model Provider", text: optionalStringBinding(\.modelProvider))
                    TextField("Service Name", text: optionalStringBinding(\.serviceName))
                }

                Section("线程来源") {
                    TextField("Session Start Source", text: optionalStringBinding(\.sessionStartSource))
                    TextField("Thread Source", text: optionalStringBinding(\.threadSource))
                }

                Section("指令") {
                    TextEditor(text: optionalStringBinding(\.baseInstructions))
                        .frame(minHeight: 90)
                    TextEditor(text: optionalStringBinding(\.developerInstructions))
                        .frame(minHeight: 90)
                }

                Section("JSON") {
                    TextEditor(text: $configText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 110)
                    TextEditor(text: $outputSchemaText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 130)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("高级选项")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("清空") { clearAdvancedOptions() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { apply() }
                }
            }
        }
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<CodexAppServerTurnOptions, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                draft[keyPath: keyPath] = trimmed.isEmpty ? nil : value
            }
        )
    }

    private func apply() {
        do {
            draft.config = try parseOptionalJSON(configText, requireObject: true, label: "config")
            draft.outputSchema = try parseOptionalJSON(outputSchemaText, requireObject: false, label: "outputSchema")
            onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearAdvancedOptions() {
        draft.modelProvider = nil
        draft.config = nil
        draft.baseInstructions = nil
        draft.developerInstructions = nil
        draft.outputSchema = nil
        draft.serviceName = nil
        draft.sessionStartSource = nil
        draft.threadSource = nil
        configText = ""
        outputSchemaText = ""
        errorMessage = nil
    }

    private func parseOptionalJSON(_ text: String, requireObject: Bool, label: String) throws -> CodexAppServerJSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let value = try JSONDecoder().decode(CodexAppServerJSONValue.self, from: Data(trimmed.utf8))
        if requireObject, value.objectValue == nil {
            throw AdvancedTurnOptionsError.invalidJSON(label + " 必须是 JSON object")
        }
        return value
    }

    private static func jsonText(from value: CodexAppServerJSONValue?) -> String {
        guard let value else {
            return ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum AdvancedTurnOptionsError: LocalizedError {
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            return message
        }
    }
}

@MainActor
private final class VoiceInputController: NSObject, ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?

    // 音量计单独成对象：波形按 buffer 频率刷新，只让 VoiceWaveformView 订阅它，
    // 避免高频 level 变化把整个 ComposerView 一起重绘。
    let levelMeter = VoiceLevelMeter()

    private var recorder: AVAudioRecorder?
    private var meteringTask: Task<Void, Never>?
    private var finishHandler: ((VoiceRecordingResult?) -> Void)?
    private var recordingURL: URL?
    private var startRequestID: UUID?
    private var pressStartedAt: Date?
    private var recordingStartedAt: Date?

    func start(onFinish: @escaping (VoiceRecordingResult?) -> Void) {
        guard !isRecording, finishHandler == nil else {
            return
        }
        let requestID = UUID()
        startRequestID = requestID
        finishHandler = onFinish
        pressStartedAt = Date()
        recordingStartedAt = nil
        errorMessage = nil
        noticeMessage = nil

        switch recordPermissionState() {
        case .undetermined:
            Task {
                // 首次系统权限弹窗可能吞掉按住手势结束事件；授权后不自动接着录，
                // 让用户重新按住一次，保证 UI 状态和真实录音起点一致。
                let granted = await requestRecordPermission()
                guard startRequestID == requestID else {
                    return
                }
                if granted {
                    noticeMessage = "麦克风已开启，请再按住说话"
                } else {
                    errorMessage = "麦克风权限未开启，请在系统设置中允许"
                }
                finish(fileURL: nil)
            }
            return
        case .denied:
            errorMessage = "麦克风权限未开启，请在系统设置中允许"
            finish(fileURL: nil)
            return
        case .granted:
            break
        }

        isPreparing = true
        VoiceHaptics.prepareRecordingStarted()

        Task {
            // 按住说话时权限弹窗可能晚于松手返回；用 requestID 防止松手后又启动录音。
            guard await requestRecordPermission() else {
                guard startRequestID == requestID else {
                    return
                }
                errorMessage = "麦克风权限未开启"
                finish(fileURL: nil)
                return
            }
            guard startRequestID == requestID else {
                return
            }
            do {
                try startRecording()
            } catch {
                guard startRequestID == requestID else {
                    return
                }
                errorMessage = error.localizedDescription
                finish(fileURL: nil)
            }
        }
    }

    func stop() {
        let shouldFinishImmediately = !isRecording && recorder == nil
        startRequestID = nil
        if shouldFinishImmediately {
            finish(fileURL: nil)
            return
        }
        finish(fileURL: recordingURL)
    }

    func setErrorMessage(_ message: String?) {
        errorMessage = message
        if message != nil {
            noticeMessage = nil
        }
    }

    func setNoticeMessage(_ message: String?) {
        noticeMessage = message
        if message != nil {
            errorMessage = nil
        }
    }

    private func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw VoiceInputError.recordingFailed
        }
        self.recorder = recorder
        recordingURL = url
        recordingStartedAt = Date()
        levelMeter.prepareForRecording()
        isPreparing = false
        isRecording = true
        VoiceHaptics.recordingStarted()
        startMetering()
    }

    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                await MainActor.run {
                    guard let self, let recorder = self.recorder, self.isRecording else {
                        return
                    }
                    recorder.updateMeters()
                    let level = Self.normalizedPower(fromDecibels: recorder.averagePower(forChannel: 0))
                    self.levelMeter.push(level)
                }
            }
        }
    }

    private func requestRecordPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func recordPermissionState() -> VoiceRecordPermissionState {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined:
                return .undetermined
            case .denied:
                return .denied
            case .granted:
                return .granted
            @unknown default:
                return .denied
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .undetermined:
                return .undetermined
            case .denied:
                return .denied
            case .granted:
                return .granted
            @unknown default:
                return .denied
            }
        }
    }

    private func finish(fileURL: URL?) {
        let now = Date()
        let pressDuration = pressStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let recordedDuration = max(
            recorder?.currentTime ?? 0,
            recordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
        )
        recorder?.stop()
        recorder = nil
        meteringTask?.cancel()
        meteringTask = nil
        recordingURL = nil
        startRequestID = nil
        pressStartedAt = nil
        recordingStartedAt = nil
        isPreparing = false
        isRecording = false
        levelMeter.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let fileURL {
            finishHandler?(VoiceRecordingResult(
                fileURL: fileURL,
                recordedDuration: recordedDuration,
                pressDuration: pressDuration
            ))
        } else {
            finishHandler?(nil)
        }
        finishHandler = nil
    }

    nonisolated private static func normalizedPower(fromDecibels db: Float) -> CGFloat {
        // 录音器直接给 dBFS；-60dB 以下按静音处理，映射到波形高度 0...1。
        let clamped = max(-60, min(0, db))
        return CGFloat((clamped + 60) / 60)
    }
}

private struct VoiceRecordingResult {
    let fileURL: URL
    let recordedDuration: TimeInterval
    let pressDuration: TimeInterval
}

private enum VoiceRecordPermissionState {
    case undetermined
    case denied
    case granted
}

private enum VoiceInputError: LocalizedError {
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .recordingFailed:
            return "录音启动失败"
        }
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let font: UIFont
    let textColor: UIColor
    let tintColor: UIColor
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSubmit: () -> Bool
    let onContentHeightChange: (CGFloat) -> Void
    let onVoiceShortcutPressChanged: (Bool) -> Void

    func makeUIView(context: Context) -> CommandSubmitTextView {
        let textView = CommandSubmitTextView()
        textView.delegate = context.coordinator
        textView.text = text
        context.coordinator.lastSyncedText = text
        textView.onCommandSubmit = onSubmit
        textView.onContentLayoutChanged = { textView in
            context.coordinator.reportContentHeight(for: textView)
        }
        textView.onVoiceShortcutPressChanged = onVoiceShortcutPressChanged
        textView.backgroundColor = .clear
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.accessibilityLabel = "输入任务或后续指令"
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: CommandSubmitTextView, context: Context) {
        context.coordinator.parent = self
        uiView.onCommandSubmit = onSubmit
        uiView.onContentLayoutChanged = { textView in
            context.coordinator.reportContentHeight(for: textView)
        }
        uiView.onVoiceShortcutPressChanged = onVoiceShortcutPressChanged

        // 字体/颜色只在真正变化时赋值：UITextView 的 font setter 会让 TextKit 对整段文本重新排版，
        // 打字时（尤其是中文 marked text 合成期间）每次按键都重设会打断输入法合成并造成可感知卡顿。
        var needsContentHeightReport = false
        if uiView.font != font {
            uiView.font = font
            needsContentHeightReport = true
        }
        if uiView.textColor != textColor {
            uiView.textColor = textColor
        }
        if uiView.tintColor != tintColor {
            uiView.tintColor = tintColor
        }

        guard context.coordinator.lastSyncedText != text else {
            if needsContentHeightReport {
                context.coordinator.reportContentHeight(for: uiView)
            }
            return
        }

        // 外部清空/恢复草稿时才同步 UIKit 文本；用户正常输入由 delegate 单向写回，
        // 避免中文 marked text 和光标位置在 SwiftUI 重算时被反复重置。
        let selectedRange = uiView.selectedRange
        context.coordinator.isApplyingExternalText = true
        uiView.text = text
        context.coordinator.lastSyncedText = text
        context.coordinator.isApplyingExternalText = false
        uiView.selectedRange = clampedRange(selectedRange, in: uiView.text)
        context.coordinator.reportContentHeight(for: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func clampedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(range.location, length)
        let remaining = max(0, length - location)
        return NSRange(location: location, length: min(range.length, remaining))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var isApplyingExternalText = false
        var lastSyncedText = ""
        private var lastReportedContentHeight: CGFloat = 0
        private var pendingContentHeight: CGFloat?
        private var isContentHeightReportScheduled = false

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalText else {
                return
            }
            lastSyncedText = textView.text
            parent.text = textView.text
            reportContentHeight(for: textView)
        }

        func reportContentHeight(for textView: UITextView) {
            let height = visibleContentHeight(for: textView)
            guard abs(lastReportedContentHeight - height) > 0.5 else {
                return
            }
            pendingContentHeight = height
            guard !isContentHeightReportScheduled else {
                return
            }
            isContentHeightReportScheduled = true
            // UIKit 布局回调可能发生在 SwiftUI 更新周期里，异步并合并回写可避免
            // 长语音草稿编辑时 size/状态更新形成一串主线程抖动。
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isContentHeightReportScheduled = false
                guard let height = self.pendingContentHeight else {
                    return
                }
                self.pendingContentHeight = nil
                guard abs(self.lastReportedContentHeight - height) > 0.5 else {
                    return
                }
                self.lastReportedContentHeight = height
                self.parent.onContentHeightChange(height)
            }
        }

        private func visibleContentHeight(for textView: UITextView) -> CGFloat {
            let contentHeight = ceil(textView.contentSize.height)
            if contentHeight > 0 {
                return clampedVisibleHeight(contentHeight)
            }
            let width = max(textView.bounds.width, 1)
            let fittingSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            return clampedVisibleHeight(ceil(textView.sizeThatFits(fittingSize).height))
        }

        private func clampedVisibleHeight(_ height: CGFloat) -> CGFloat {
            min(max(height, parent.minHeight), parent.maxHeight)
        }
    }
}

private final class CommandSubmitTextView: UITextView {
    var onCommandSubmit: (() -> Bool)?
    var onContentLayoutChanged: ((CommandSubmitTextView) -> Void)?
    var onVoiceShortcutPressChanged: ((Bool) -> Void)?
    private var isVoiceShortcutPressed = false
    private var lastReportedLayoutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.width - lastReportedLayoutWidth) > 0.5 else {
            return
        }
        lastReportedLayoutWidth = bounds.width
        onContentLayoutChanged?(self)
    }

    override var keyCommands: [UIKeyCommand]? {
        let submit = UIKeyCommand(
            title: "发送",
            action: #selector(handleCommandReturn),
            input: "\r",
            modifierFlags: .command,
            discoverabilityTitle: "发送"
        )
        return (super.keyCommands ?? []) + [submit]
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if containsVoiceShortcutPress(presses) {
            guard !isVoiceShortcutPressed else {
                return
            }
            isVoiceShortcutPressed = true
            onVoiceShortcutPressChanged?(true)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if containsVoiceShortcutPress(presses) {
            finishVoiceShortcutPress()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if containsVoiceShortcutPress(presses) {
            finishVoiceShortcutPress()
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    @objc private func handleCommandReturn() {
        // 普通回车仍由 UITextView 插入换行；只有 Command + Return 走发送。
        _ = onCommandSubmit?()
    }

    private func finishVoiceShortcutPress() {
        guard isVoiceShortcutPressed else {
            return
        }
        isVoiceShortcutPressed = false
        onVoiceShortcutPressChanged?(false)
    }

    private func containsVoiceShortcutPress(_ presses: Set<UIPress>) -> Bool {
        presses.contains { press in
            Self.isVoiceShortcutKey(press.key)
        }
    }

    private static func isVoiceShortcutKey(_ key: UIKey?) -> Bool {
        guard let key else {
            return false
        }
        switch key.keyCode {
        case .keyboardLANG1, .keyboardLANG2, .keyboardLANG3, .keyboardLANG4, .keyboardLANG5,
             .keyboardLANG6, .keyboardLANG7, .keyboardLANG8, .keyboardLANG9:
            // UIKit 没有公开 Fn/Globe 的专用 keyCode；部分硬件键盘会把输入法切换键上报为 LANG1...LANG9。
            return key.charactersIgnoringModifiers.isEmpty
        default:
            return false
        }
    }
}

private struct PendingApprovalActionCard: View {
    let approval: ApprovalSummary
    let isSendingDecision: Bool
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text("等待审批")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    if isSendingDecision {
                        Label("决定已发送", systemImage: "hourglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(approval.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    approvalMeta
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            approvalButtons
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 审批是当前 turn 的阻塞点，放在输入框上方比放在 Inspector 更接近用户决策动作。
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
        }
    }

    private var approvalMeta: some View {
        HStack(spacing: 8) {
            Label(approval.kind, systemImage: "tag")
            if let count = approval.count {
                Label("\(count) 项", systemImage: "number")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var approvalButtons: some View {
        // iPad 触控优先：两个决策按钮等宽铺满、加大高度和字号，比并排小按钮更好点。
        HStack(spacing: 10) {
            Button(role: .destructive, action: onDecline) {
                Label("拒绝", systemImage: "xmark.circle")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isSendingDecision)

            Button(action: onApprove) {
                Label("批准", systemImage: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .disabled(isSendingDecision)
        }
    }
}
