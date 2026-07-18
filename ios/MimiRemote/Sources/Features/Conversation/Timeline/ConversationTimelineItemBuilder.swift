import Foundation

struct ConversationTimelineItemBuilder {
    static func items(from messages: [ConversationMessage]) -> [ConversationTimelineItem] {
        let completedTurnIDs = completedTurnIDs(in: messages)
        var items: [ConversationTimelineItem] = []
        var index = messages.startIndex

        while index < messages.endIndex {
            let message = messages[index]
            guard isActivityMessage(message) else {
                items.append(.message(message))
                index = messages.index(after: index)
                continue
            }

            var activityMessages: [ConversationMessage] = []
            while index < messages.endIndex,
                  isActivityMessage(messages[index]),
                  belongsToSameActivitySequence(message, messages[index]) {
                activityMessages.append(messages[index])
                index = messages.index(after: index)
            }
            let turnCompleted = message.turnID.map { completedTurnIDs.contains($0) }
                ?? (fallbackCompletedAssistant(for: activityMessages, nextIndex: index, messages: messages) != nil)
            // 时间线只折叠相邻过程项，不跨 commentary、plan 或 final 搬运内容。
            // 输入顺序由上游 canonical timeline 决定，视图投影不能再次改写语义顺序。
            items.append(contentsOf: activityItems(from: activityMessages, turnCompleted: turnCompleted))
        }

        return items
    }

    private static func isActivityMessage(_ message: ConversationMessage) -> Bool {
        guard message.role == .system else {
            return false
        }
        switch message.kind {
        case .reasoningSummary, .commandSummary, .fileChangeSummary:
            return true
        case .approval, .userInput:
            return isResolvedInteractionMessage(message)
        case .commentary, .plan, .error, .message:
            return false
        }
    }

    private static func isResolvedInteractionMessage(_ message: ConversationMessage) -> Bool {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch message.kind {
        case .approval:
            return content.hasPrefix(L10n.text("ui.approval_approved")) || content.hasPrefix(L10n.text("ui.approved")) ||
                content.hasPrefix(L10n.text("ui.approval_rejected")) || content.hasPrefix(L10n.text("ui.rejected"))
        case .userInput:
            return content.hasPrefix(L10n.text("ui.additional_information_has_been_submitted")) || content.hasPrefix(L10n.text("ui.boot_input_submitted")) ||
                content.hasPrefix(L10n.text("ui.additional_information_skipped")) || content.hasPrefix(L10n.text("ui.boot_input_skipped"))
        case .message, .commentary, .plan, .reasoningSummary, .commandSummary, .fileChangeSummary, .error:
            return false
        }
    }

    private static func isExplorationMessage(_ message: ConversationMessage) -> Bool {
        guard message.activityPayload?.category == .runCommand else {
            return false
        }
        return message.activityPayload?.displayTitle.hasPrefix(L10n.text("ui.view_f9c527c2")) == true ||
            message.activityPayload?.displayTitle.hasPrefix(L10n.text("ui.list_e89ea827")) == true ||
            message.activityPayload?.displayTitle.hasPrefix(L10n.text("ui.search_45a71f26")) == true
    }

    private static func belongsToSameActivitySequence(
        _ first: ConversationMessage,
        _ candidate: ConversationMessage
    ) -> Bool {
        first.turnID == candidate.turnID
    }

    private static func isCompletedAssistantMessage(_ message: ConversationMessage) -> Bool {
        guard message.role == .assistant && message.kind == .message else {
            return false
        }
        return message.sendStatus == .confirmed || message.sendStatus == .sent
    }

    private static func completedTurnIDs(
        in messages: [ConversationMessage]
    ) -> Set<TurnID> {
        let messagesByTurnID = Dictionary(grouping: messages.compactMap { message -> (TurnID, ConversationMessage)? in
            guard let turnID = message.turnID, !turnID.isEmpty else { return nil }
            return (turnID, message)
        }, by: { $0.0 })
        var result = Set<TurnID>()
        for (turnID, entries) in messagesByTurnID {
            let turnMessages = entries.map(\.1)
            if turnMessages.contains(where: { $0.turnLifecycle?.isTerminal == true }) {
                result.insert(turnID)
                continue
            }
            // 旧 gateway 没有可靠 lifecycle 时才回退到 final；显式 inProgress 不能被提前收口。
            if turnMessages.allSatisfy({ $0.turnLifecycle == nil || $0.turnLifecycle == .unknown }),
               turnMessages.contains(where: isCompletedAssistantMessage) {
                result.insert(turnID)
            }
        }
        return result
    }

    private static func fallbackCompletedAssistant(
        for processMessages: [ConversationMessage],
        nextIndex: [ConversationMessage].Index,
        messages: [ConversationMessage]
    ) -> ConversationMessage? {
        guard sharedTurnID(in: processMessages) == nil,
              let next = messages[safe: nextIndex],
              isCompletedAssistantMessage(next) else {
            return nil
        }
        return next
    }

    private static func sharedTurnID(in messages: [ConversationMessage]) -> TurnID? {
        let turnIDs = Set(messages.compactMap(\.turnID))
        guard turnIDs.count == 1, let turnID = turnIDs.first, !turnID.isEmpty else {
            return nil
        }
        return turnID
    }

    private static func activityItems(
        from messages: [ConversationMessage],
        turnCompleted: Bool
    ) -> [ConversationTimelineItem] {
        var result: [ConversationTimelineItem] = []
        var explorations: [ConversationMessage] = []

        func flushExplorations() {
            guard !explorations.isEmpty else {
                return
            }
            result.append(.exploration(explorationGroup(from: explorations, turnCompleted: turnCompleted)))
            explorations.removeAll(keepingCapacity: true)
        }

        for element in ConversationProcessGrouper.elements(from: messages, turnCompleted: turnCompleted) {
            switch element {
            case .group(let group):
                flushExplorations()
                result.append(.processGroup(group))
            case .activity(let message):
                if isExplorationMessage(message) {
                    explorations.append(message)
                } else {
                    flushExplorations()
                    result.append(.activity(message))
                }
            }
        }
        flushExplorations()
        return result
    }

    private static func explorationGroup(
        from messages: [ConversationMessage],
        turnCompleted: Bool
    ) -> ConversationExplorationGroup {
        let firstID = messages.first?.id.uuidString ?? UUID().uuidString
        let allItemsTerminal = messages.allSatisfy { message in
            guard let status = message.activityPayload?.status?.lowercased() else {
                return false
            }
            return status == "completed" || status == "failed" || status == "cancelled"
        }
        return ConversationExplorationGroup(
            id: "exploration:\(firstID)",
            messages: messages,
            isCompleted: turnCompleted || allItemsTerminal
        )
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
