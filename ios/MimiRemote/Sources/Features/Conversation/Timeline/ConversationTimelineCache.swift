import Foundation

final class ConversationTimelineItemCache {
    private var keys: [ConversationTimelineCacheKey] = []
    private var cachedItems: [ConversationTimelineItem] = []

    func items(from messages: [ConversationMessage]) -> [ConversationTimelineItem] {
        let nextKeys = messages.map { ConversationTimelineCacheKey(message: $0) }
        guard nextKeys != keys else {
            return cachedItems
        }
        let nextItems = ConversationTimelineItemBuilder.items(from: messages)
        keys = nextKeys
        cachedItems = nextItems
        return nextItems
    }

    func removeAll() {
        keys.removeAll()
        cachedItems.removeAll()
    }
}

private struct ConversationTimelineCacheKey: Equatable {
    let id: UUID
    let stableID: MessageID?
    let clientMessageID: ClientMessageID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    let role: ConversationMessage.Role
    let kind: MessageKind
    let createdAt: Date
    let updatedAt: Date?
    let sendStatus: MessageSendStatus
    let revision: ModelRevision?
    let renderFingerprint: ConversationMessageRenderFingerprint
    let turnPayload: CodexAppServerTurnPayload?
    let activityPayload: ConversationActivityPayload?
    let isTimestampFallback: Bool

    init(message: ConversationMessage) {
        self.id = message.id
        self.stableID = message.stableID
        self.clientMessageID = message.clientMessageID
        self.turnID = message.turnID
        self.itemID = message.itemID
        self.role = message.role
        self.kind = message.kind
        self.createdAt = message.createdAt
        self.updatedAt = message.updatedAt
        self.sendStatus = message.sendStatus
        self.revision = message.revision
        self.renderFingerprint = message.renderFingerprint
        self.turnPayload = message.turnPayload
        self.activityPayload = message.activityPayload
        self.isTimestampFallback = message.isTimestampFallback
    }
}
