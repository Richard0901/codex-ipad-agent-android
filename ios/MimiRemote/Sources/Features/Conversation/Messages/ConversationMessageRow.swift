import SwiftUI

struct MessageRow: View, Equatable {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let themeVersion: Int
    let layout: ConversationLayout
    let showsActiveDeliveryStatus: Bool

    // 只有内容 fingerprint / 状态变化时才重绘；长消息内容本身不参与这里的逐行比较。
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.role == rhs.message.role
            && lhs.message.kind == rhs.message.kind
            && lhs.message.sendStatus == rhs.message.sendStatus
            && lhs.message.revision == rhs.message.revision
            && lhs.message.userDelivery == rhs.message.userDelivery
            && lhs.message.createdAt == rhs.message.createdAt
            && lhs.message.updatedAt == rhs.message.updatedAt
            && lhs.message.renderFingerprint == rhs.message.renderFingerprint
            && lhs.message.turnPayload == rhs.message.turnPayload
            && lhs.message.activityPayload == rhs.message.activityPayload
            && lhs.themeVersion == rhs.themeVersion
            && lhs.layout == rhs.layout
            && lhs.showsActiveDeliveryStatus == rhs.showsActiveDeliveryStatus
    }

    var body: some View {
        Group {
            switch message.role {
            case .user:
                userRow
            case .assistant:
                assistantRow
            case .system:
                systemRow
            }
        }
        .frame(maxWidth: .infinity, alignment: rowAlignment)
    }

    private var userRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: layout.messageSideSpacer)
            VStack(alignment: .trailing, spacing: 3) {
                MessageBubble(message: message, layout: layout)
                statusCaption
            }
        }
    }

    private var assistantRow: some View {
        HStack(spacing: 0) {
            if message.kind == .commentary {
                ConversationCommentaryRow(message: message, layout: layout)
            } else {
                MessageBubble(message: message, layout: layout)
            }
            Spacer(minLength: layout.messageSideSpacer)
        }
    }

    private var systemRow: some View {
        Group {
            if isCenteredSystemNotice {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SystemNotice(message: message, layout: layout)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 0) {
                    RuntimeSummaryCard(message: message, layout: layout)
                    Spacer(minLength: layout.messageSideSpacer)
                }
            }
        }
    }

    private var isCenteredSystemNotice: Bool {
        message.kind == .message
    }

    // 状态以气泡下方的小字呈现（贴右），比浮在一旁的图标更直观，也避开了气泡定宽框的定位问题。
    @ViewBuilder
    private var statusCaption: some View {
        switch message.sendStatus {
        case .failed:
            Text("发送失败")
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(.red)
        case .sending:
            deliveryCaption(sendingDeliveryCaption)
        case .sent:
            if message.userDelivery == .injected {
                deliveryCaption("已引导对话")
            } else if showsActiveDeliveryStatus {
                deliveryCaption("已送达，等待回复")
            }
        case .confirmed:
            if message.userDelivery == .injected {
                deliveryCaption("已引导对话")
            }
        case .local:
            deliveryCaption(message.userDelivery == .queued ? "已排队，等待当前回复完成" : "待发送")
        }
    }

    private var sendingDeliveryCaption: String {
        switch message.userDelivery {
        case .queued:
            return "排队发送中…"
        case .guided, .injected:
            return "引导发送中…"
        case nil:
            return "发送中…"
        }
    }

    private func deliveryCaption(_ text: String) -> some View {
        Text(text)
            .font(themeStore.uiFont(.caption2))
            .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
    }

    private var rowAlignment: Alignment {
        switch message.role {
        case .user:
            return .trailing
        case .assistant:
            return .leading
        case .system:
            return isCenteredSystemNotice ? .center : .leading
        }
    }
}
