import Foundation

enum ConversationTimelineItem: Identifiable, Equatable {
    case message(ConversationMessage)
    case activity(ConversationMessage)
    case exploration(ConversationExplorationGroup)
    case processGroup(ConversationProcessGroup)

    var id: String {
        switch self {
        case .message(let message):
            return "message:\(message.id.uuidString)"
        case .activity(let message):
            return Self.activityID(for: message)
        case .exploration(let group):
            return group.id
        case .processGroup(let group):
            return group.id
        }
    }

    static func activityID(for message: ConversationMessage) -> String {
        "activity:\(message.id.uuidString)"
    }
}

struct ConversationExplorationGroup: Identifiable, Equatable {
    let id: String
    let messages: [ConversationMessage]
    let isCompleted: Bool

    var title: String {
        isCompleted
            ? L10n.plural("ui.items_explored_count", count: messages.count)
            : L10n.plural("ui.items_being_explored_count", count: messages.count)
    }

    var latestDetail: String? {
        guard let title = messages.last?.activityPayload?.displayTitle else {
            return nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ConversationProcessGroupStatus: Equatable {
    case running
    case completed
    case failed
}

struct ConversationProcessGroup: Identifiable, Equatable {
    let id: String
    let turnID: TurnID
    let header: ConversationMessage
    let activities: [ConversationMessage]
    let status: ConversationProcessGroupStatus

    var title: String {
        let source = header.activityPayload?.subtitle ?? header.content
        let plainText = ConversationActivityPayload.plainProgressText(source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plainText.isEmpty ? L10n.text("ui.processing_task") : plainText
    }
}
