import SwiftUI
import UIKit

struct FileReferencePreviewStrip: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let references: [ConversationFileReference]
    let previewingPath: String?
    let previewError: String?
    let onPreview: (ConversationFileReference) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 6) {
            ForEach(references) { reference in
                Button {
                    onPreview(reference)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.viewfinder")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.accent)
                            .frame(width: 18, height: 18)
                        Text(reference.name)
                            .font(themeStore.uiFont(.caption, weight: .medium))
                            .foregroundStyle(tokens.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if previewingPath == reference.path {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(tokens.border, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(previewingPath != nil)
                .accessibilityLabel("预览 \(reference.name)")
            }

            if let previewError {
                Text(previewError)
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SystemNotice: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout

    var body: some View {
        noticeSurface
            .contentShape(Capsule())
            .messageContextMenu(for: message) {
                noticeSurface
                    .frame(maxWidth: layout.systemMaxWidth)
            }
            .frame(maxWidth: layout.systemMaxWidth)
    }

    private var noticeSurface: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return ZStack(alignment: .bottomTrailing) {
            Text(message.content)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            MessageTimestampCaption(text: message.timestampCaptionText, isFallback: message.isTimestampFallback)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tokens.systemBubble, in: Capsule())
    }
}

struct RuntimeSummaryCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout

    var body: some View {
        cardSurface
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .messageContextMenu(for: message) {
                cardSurface
                    .frame(maxWidth: cardMaxWidth, alignment: .leading)
            }
            .frame(maxWidth: cardMaxWidth, alignment: .leading)
    }

    private var cardSurface: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbolName)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                contentView
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    MessageTimestampCaption(text: message.timestampCaptionText, isFallback: message.isTimestampFallback)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if let payload = message.activityPayload {
            activityContent(payload)
        } else if message.kind == .plan {
            planMarkdownContent
        } else {
            Text(message.content)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(3)
        }
    }

    private func activityContent(_ payload: ConversationActivityPayload) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if payload.category == .plan {
                planMarkdownContent
            } else if payload.category == .thinking, let subtitle = payload.subtitle {
                Text(subtitle)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(3)
            } else {
                if let command = payload.command {
                    activityDetailRow("命令", value: command, monospaced: true)
                }
                if let cwd = payload.cwd {
                    activityDetailRow("目录", value: cwd, monospaced: true)
                }
                if !payload.filePaths.isEmpty {
                    activityDetailRow("文件", value: payload.filePaths.prefix(5).joined(separator: ", "), monospaced: true)
                }
                if let toolName = payload.toolName, payload.category == .toolCall {
                    activityDetailRow("工具", value: toolName, monospaced: true)
                }
                let statusText = [payload.status.map { "状态 \($0)" }, payload.exitCode.map { "退出码 \($0)" }]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                if let output = payload.outputPreview {
                    Text(output)
                        .font(themeStore.uiFont(.caption2).monospaced())
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityDetailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.secondaryText.opacity(0.82))
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(monospaced ? themeStore.uiFont(.caption2).monospaced() : themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var planMarkdownContent: some View {
        let style = MarkdownStyle.make(
            role: .assistant,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale * 0.94,
            tokens: tokens
        )
        let plan = MessageRenderPlanCache.shared.plan(for: message)
        let blocks = displayBlocks(for: plan)

        return VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, style: style)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardMaxWidth: CGFloat {
        message.kind == .plan ? layout.assistantBubbleMaxWidth : layout.runtimeCardMaxWidth
    }

    private func displayBlocks(for plan: MessageRenderPlan) -> [MarkdownBlock] {
        guard plan.blocks.count == 1,
              case let .proposedPlan(blocks, _) = plan.blocks[0].kind
        else {
            return plan.blocks
        }
        return blocks
    }

    private var title: String {
        if let payload = message.activityPayload {
            return payload.displayTitle
        }
        switch message.kind {
        case .commentary:
            return "过程说明"
        case .plan:
            return "计划"
        case .reasoningSummary:
            return "推理摘要"
        case .commandSummary:
            return "命令"
        case .fileChangeSummary:
            return "文件变更"
        case .approval:
            if isApprovedApproval {
                return "审批已批准"
            }
            if isDeclinedApproval {
                return "审批已拒绝"
            }
            return "等待审批"
        case .userInput:
            if message.content.hasPrefix("已跳过补充信息") || message.content.hasPrefix("已跳过引导输入") {
                return "补充信息已跳过"
            }
            if message.content.hasPrefix("补充信息已提交") || message.content.hasPrefix("引导输入已提交") {
                return "补充信息已提交"
            }
            return "等待补充信息"
        case .error:
            return "运行异常"
        case .message:
            return "状态"
        }
    }

    private var symbolName: String {
        if let category = message.activityPayload?.category {
            return ProcessedActivitySymbol.symbolName(for: category)
        }
        switch message.kind {
        case .commentary:
            return "text.bubble"
        case .plan:
            return "list.clipboard"
        case .reasoningSummary:
            return "brain.head.profile"
        case .commandSummary:
            return "terminal"
        case .fileChangeSummary:
            return "doc.text.magnifyingglass"
        case .approval:
            if isApprovedApproval {
                return "checkmark.circle"
            }
            if isDeclinedApproval {
                return "xmark.circle"
            }
            return "exclamationmark.shield"
        case .userInput:
            return "questionmark.bubble"
        case .error:
            return "exclamationmark.triangle"
        case .message:
            return "info.circle"
        }
    }

    private var tint: Color {
        if let category = message.activityPayload?.category {
            switch category {
            case .plan, .editFile:
                return tokens.accent
            case .error:
                return .red
            case .thinking, .runCommand, .toolCall:
                return tokens.secondaryText
            }
        }
        switch message.kind {
        case .plan:
            return tokens.accent
        case .approval:
            if isApprovedApproval {
                return tokens.success
            }
            if isDeclinedApproval {
                return .red
            }
            return tokens.warning
        case .userInput:
            return tokens.accent
        case .error:
            return .red
        case .fileChangeSummary:
            return tokens.accent
        default:
            return tokens.secondaryText
        }
    }

    private var background: Color {
        if let category = message.activityPayload?.category {
            switch category {
            case .plan:
                return tokens.accent.opacity(0.08)
            case .editFile:
                return tokens.accent.opacity(0.10)
            case .error:
                return Color.red.opacity(0.10)
            case .thinking, .runCommand, .toolCall:
                return tokens.systemBubble
            }
        }
        switch message.kind {
        case .plan:
            return tokens.accent.opacity(0.08)
        case .approval:
            if isApprovedApproval {
                return tokens.success.opacity(0.10)
            }
            if isDeclinedApproval {
                return Color.red.opacity(0.10)
            }
            return tokens.warning.opacity(0.12)
        case .error:
            return Color.red.opacity(0.10)
        case .fileChangeSummary:
            return tokens.accent.opacity(0.10)
        default:
            return tokens.systemBubble
        }
    }

    private var isApprovedApproval: Bool {
        message.content.hasPrefix("审批已批准") || message.content.hasPrefix("已批准")
    }

    private var isDeclinedApproval: Bool {
        message.content.hasPrefix("审批已拒绝") || message.content.hasPrefix("已拒绝")
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

extension View {
    func messageContextMenu<Preview: View>(
        for message: ConversationMessage,
        retry: (() -> Void)? = nil,
        stop: (() -> Void)? = nil,
        @ViewBuilder preview: @escaping () -> Preview
    ) -> some View {
        _ = preview
        // iPadOS 对 contextMenu 自定义预览会重新构建复杂 Markdown/图片气泡，长按时容易触发 SwiftUI 内部崩溃；
        // 这里保留复制/重试/停止动作，禁用预览来换取稳定性。
        return contextMenu {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }

            if message.role == .user && message.sendStatus == .failed, let retry {
                Button(action: retry) {
                    Label("重试", systemImage: "arrow.clockwise")
                }
            }

            if message.role == .assistant && message.sendStatus == .sending, let stop {
                Button(role: .destructive, action: stop) {
                    Label("停止", systemImage: "stop.circle")
                }
            }
        }
    }
}

struct MessageTimestampCaption: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    var isFallback = false
    var foreground: Color?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        Text(text)
            .font(themeStore.uiFont(.caption2, weight: .medium))
            .foregroundStyle(isFallback ? tokens.warning : (foreground ?? tokens.tertiaryText))
            .lineLimit(1)
            .minimumScaleFactor(0.88)
            .accessibilityLabel(isFallback ? "消息时间 兜底估算 \(text)" : "消息时间 \(text)")
    }
}

extension ConversationMessage {
    var timestampCaptionText: String {
        let text: String
        switch role {
        case .user:
            text = "发出 \(Self.compactTime(createdAt))"
        case .assistant:
            guard sendStatus != .sending else {
                let started = Self.compactTime(createdAt)
                guard let updatedAt else {
                    return "开始 \(started)"
                }
                let latest = Self.compactTime(updatedAt)
                return started == latest ? "开始 \(started)" : "开始 \(started) · 最近 \(latest)"
            }
            let completedAt = updatedAt ?? createdAt
            let started = Self.compactTime(createdAt)
            let completed = Self.compactTime(completedAt)
            // 同一分钟内开始和完成显示相同时间时，只保留完成时间，减少气泡右下角噪音。
            if started == completed {
                text = "完成 \(completed)"
            } else {
                text = "开始 \(started) · 完成 \(completed)"
            }
        case .system:
            if let updatedAt, Self.compactTime(updatedAt) != Self.compactTime(createdAt) {
                text = "\(Self.compactTime(createdAt)) · \(Self.compactTime(updatedAt))"
            } else {
                text = Self.compactTime(createdAt)
            }
        }
        return text
    }

    private static func compactTime(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
}
