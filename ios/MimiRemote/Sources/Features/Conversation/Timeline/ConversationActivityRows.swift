import SwiftUI

struct ConversationExplorationRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let group: ConversationExplorationGroup
    let layout: ConversationLayout

    static func == (lhs: ConversationExplorationRow, rhs: ConversationExplorationRow) -> Bool {
        lhs.group == rhs.group && lhs.layout == rhs.layout
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if group.isCompleted {
                        Image(systemName: "circle.fill")
                            .font(themeStore.uiFont(size: 5, weight: .semibold))
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .frame(width: 14, height: 16)
                .foregroundStyle(tokens.secondaryText)

                Text(explorationText)
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(explorationText)

            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var explorationText: String {
        guard let detail = group.latestDetail else {
            return group.title
        }
        return "\(group.title) · \(detail)"
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

struct ConversationActivityRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout
    let isExpanded: Bool
    let toggle: () -> Void

    static func == (lhs: ConversationActivityRow, rhs: ConversationActivityRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.renderFingerprint == rhs.message.renderFingerprint
            && lhs.message.activityPayload == rhs.message.activityPayload
            && lhs.layout == rhs.layout
            && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        HStack(spacing: 0) {
            rowSurface
                .messageContextMenu(for: message) {
                    rowSurface.frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)
                }
                .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)

            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var rowSurface: some View {
        if hasExpandableDetails {
            Button(action: toggle) {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activityTitle)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            .accessibilityHint(isExpanded ? "收起当前过程详情" : "展开当前过程详情")
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(alignment: isReasoning ? .top : .firstTextBaseline, spacing: 8) {
            activityMarker

            if isReasoning {
                Text(reasoningText)
                    .font(themeStore.uiFont(.caption))
                    .italic()
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activityTitle)
                        .font(themeStore.uiFont(.caption, weight: .medium))
                        .foregroundStyle(activityTint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = activityDetail {
                        Text(detail)
                            .font(themeStore.uiFont(.caption2))
                            .foregroundStyle(tokens.secondaryText.opacity(0.84))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if isExpanded {
                        expandedDetails
                            .padding(.top, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hasExpandableDetails {
                Image(systemName: "chevron.right")
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText.opacity(0.75))
                    .frame(width: 12, height: 16)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var expandedDetails: some View {
        if let payload = message.activityPayload {
            VStack(alignment: .leading, spacing: 4) {
                if let command = payload.command?.conversationActivityTrimmedNonEmpty {
                    activityDetailLine("命令", value: command, monospaced: true)
                }
                if let cwd = payload.cwd?.conversationActivityTrimmedNonEmpty {
                    activityDetailLine("目录", value: cwd, monospaced: true)
                }
                if !payload.filePaths.isEmpty {
                    activityDetailLine("文件", value: payload.filePaths.joined(separator: "\n"), monospaced: true)
                }
                let status = [
                    payload.displayStatusText,
                    payload.exitCode.map { "退出码 \($0)" }
                ]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !status.isEmpty {
                    activityDetailLine("状态", value: status)
                }
                if let output = payload.outputPreview?.conversationActivityTrimmedNonEmpty {
                    Text(output)
                        .font(themeStore.uiFont(.caption2).monospaced())
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func activityDetailLine(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.secondaryText.opacity(0.76))
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(monospaced ? themeStore.uiFont(.caption2).monospaced() : themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var activityMarker: some View {
        if isRunning {
            ProgressView()
                .controlSize(.mini)
                .tint(activityTint)
                .frame(width: 14, height: 16)
        } else {
            Image(systemName: markerSymbol)
                .font(themeStore.uiFont(size: markerSymbol == "circle.fill" ? 5 : 11, weight: .semibold))
                .foregroundStyle(activityTint)
                .frame(width: 14, height: 16)
        }
    }

    private var isReasoning: Bool {
        message.kind == .reasoningSummary
    }

    private var reasoningText: String {
        ConversationActivityPayload.plainProgressText(
            message.activityPayload?.subtitle?.conversationActivityTrimmedNonEmpty ?? message.content
        )
    }

    private var activityTitle: String {
        if let payload = message.activityPayload {
            return payload.displayTitle
        }
        switch message.kind {
        case .commentary:
            return message.content
        case .commandSummary:
            return message.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "运行命令"
        case .fileChangeSummary:
            return message.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "文件变更"
        case .approval:
            if isApprovedInteraction {
                return "审批已批准"
            }
            if isDeclinedInteraction {
                return "审批已拒绝"
            }
            return "审批状态"
        case .userInput:
            return isSkippedInteraction ? "已跳过补充信息" : "补充信息已提交"
        default:
            return message.content
        }
    }

    private var activityDetail: String? {
        guard let payload = message.activityPayload else {
            return interactionDetail
        }
        switch payload.category {
        case .editFile:
            return payload.filePaths.isEmpty ? payload.displayStatusText : payload.filePaths.prefix(4).joined(separator: ", ")
        case .runCommand:
            if let exitCode = payload.exitCode, exitCode != 0 {
                return "退出码 \(exitCode)"
            }
            return payload.cwd
        case .toolCall:
            return payload.displayStatusText == "已完成" ? nil : payload.displayStatusText
        case .thinking, .plan, .error:
            return payload.subtitle.map(ConversationActivityPayload.plainProgressText)
        }
    }

    private var interactionDetail: String? {
        guard message.kind == .approval || message.kind == .userInput else {
            return nil
        }
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = content.firstIndex(where: { $0 == "：" || $0 == ":" }) {
            return String(content[content.index(after: separator)...]).conversationActivityTrimmedNonEmpty
        }
        return nil
    }

    private var hasExpandableDetails: Bool {
        if isReasoning {
            return reasoningText.count > 160 || reasoningText.filter { $0 == "\n" }.count >= 3
        }
        guard let payload = message.activityPayload else {
            return false
        }
        return payload.command?.conversationActivityTrimmedNonEmpty != nil ||
            payload.cwd?.conversationActivityTrimmedNonEmpty != nil ||
            !payload.filePaths.isEmpty ||
            payload.outputPreview?.conversationActivityTrimmedNonEmpty != nil
    }

    private var isRunning: Bool {
        message.activityPayload?.isInProgress == true
    }

    private var isFailure: Bool {
        message.activityPayload?.isFailure == true
    }

    private var markerSymbol: String {
        if isFailure {
            return "exclamationmark.circle.fill"
        }
        if isApprovedInteraction || (message.kind == .userInput && !isSkippedInteraction) {
            return "checkmark.circle.fill"
        }
        if isDeclinedInteraction || isSkippedInteraction {
            return "xmark.circle"
        }
        if message.activityPayload?.category == .editFile {
            return "pencil"
        }
        return "circle.fill"
    }

    private var activityTint: Color {
        if isFailure {
            return .red
        }
        if isApprovedInteraction || (message.kind == .userInput && !isSkippedInteraction) {
            return tokens.success
        }
        if message.activityPayload?.category == .editFile {
            return tokens.accent
        }
        return tokens.secondaryText
    }

    private var isApprovedInteraction: Bool {
        message.kind == .approval &&
            (message.content.hasPrefix("审批已批准") || message.content.hasPrefix("已批准"))
    }

    private var isDeclinedInteraction: Bool {
        message.kind == .approval &&
            (message.content.hasPrefix("审批已拒绝") || message.content.hasPrefix("已拒绝"))
    }

    private var isSkippedInteraction: Bool {
        message.kind == .userInput &&
            (message.content.hasPrefix("已跳过补充信息") || message.content.hasPrefix("已跳过引导输入"))
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

enum ProcessedActivitySymbol {
    static func symbolName(for category: ConversationActivityCategory) -> String {
        switch category {
        case .thinking:
            return "brain.head.profile"
        case .plan:
            return "list.clipboard"
        case .runCommand:
            return "terminal"
        case .editFile:
            return "doc.text"
        case .toolCall:
            return "wrench.and.screwdriver"
        case .error:
            return "exclamationmark.triangle"
        }
    }
}

private extension String {
    var conversationActivityTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
