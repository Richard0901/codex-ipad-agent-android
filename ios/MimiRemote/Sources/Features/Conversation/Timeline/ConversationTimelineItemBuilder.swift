import Foundation

struct ConversationTimelineItemBuilder {
    static func items(from messages: [ConversationMessage]) -> [ConversationTimelineItem] {
        let completedAssistantByTurnID = completedAssistantMessagesByTurnID(in: messages)
        let completedTurnIDs = Set(completedAssistantByTurnID.keys)
        let planMessagesByTurnID = planMessagesByTurnID(in: messages, completedTurnIDs: completedTurnIDs)
        let lateProcessMessagesByTurnID = lateProcessMessagesByTurnID(
            in: messages,
            completedAssistantByTurnID: completedAssistantByTurnID
        )
        let lateProcessMessageIDs = Set(lateProcessMessagesByTurnID.values.flatMap { $0.map(\.id) })
        let pinnedPlanMessageIDs = Set(planMessagesByTurnID.values.flatMap { $0.map(\.id) })
        var insertedLateProcessTurnIDs = Set<TurnID>()
        var insertedPlanTurnIDs = Set<TurnID>()
        var items: [ConversationTimelineItem] = []
        var index = messages.startIndex

        while index < messages.endIndex {
            let message = messages[index]
            if lateProcessMessageIDs.contains(message.id) || pinnedPlanMessageIDs.contains(message.id) {
                index = messages.index(after: index)
                continue
            }
            if let turnID = message.turnID,
               isCompletedAssistantMessage(message),
               let lateProcessMessages = lateProcessMessagesByTurnID[turnID],
               !insertedLateProcessTurnIDs.contains(turnID) {
                // app-server 可能在最终回答后补到 diff；只把迟到部分归位，不能打散 commentary 边界。
                items.append(contentsOf: activityItems(from: lateProcessMessages, turnCompleted: true))
                insertedLateProcessTurnIDs.insert(turnID)
            }
            guard isActivityMessage(message) else {
                items.append(.message(message))
                if let turnID = message.turnID,
                   isCompletedAssistantMessage(message),
                   let plans = planMessagesByTurnID[turnID],
                   !insertedPlanTurnIDs.contains(turnID) {
                    items.append(contentsOf: plans.map(ConversationTimelineItem.message))
                    insertedPlanTurnIDs.insert(turnID)
                }
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
            let nextMessage = messages[safe: index]
            if !isProcessBatchSummarizedByCommentary(activityMessages, nextMessage: nextMessage) {
                items.append(contentsOf: activityItems(from: activityMessages, turnCompleted: turnCompleted))
            }
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
            return content.hasPrefix("审批已批准") || content.hasPrefix("已批准") ||
                content.hasPrefix("审批已拒绝") || content.hasPrefix("已拒绝")
        case .userInput:
            return content.hasPrefix("补充信息已提交") || content.hasPrefix("引导输入已提交") ||
                content.hasPrefix("已跳过补充信息") || content.hasPrefix("已跳过引导输入")
        case .message, .commentary, .plan, .reasoningSummary, .commandSummary, .fileChangeSummary, .error:
            return false
        }
    }

    private static func isExplorationMessage(_ message: ConversationMessage) -> Bool {
        guard message.activityPayload?.category == .runCommand else {
            return false
        }
        return message.activityPayload?.displayTitle.hasPrefix("查看 ") == true ||
            message.activityPayload?.displayTitle.hasPrefix("列出 ") == true ||
            message.activityPayload?.displayTitle.hasPrefix("搜索 ") == true
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

    private static func completedAssistantMessagesByTurnID(
        in messages: [ConversationMessage]
    ) -> [TurnID: ConversationMessage] {
        var result: [TurnID: ConversationMessage] = [:]
        for message in messages {
            guard let turnID = message.turnID, !turnID.isEmpty, isCompletedAssistantMessage(message) else {
                continue
            }
            result[turnID] = result[turnID] ?? message
        }
        return result
    }

    private static func lateProcessMessagesByTurnID(
        in messages: [ConversationMessage],
        completedAssistantByTurnID: [TurnID: ConversationMessage]
    ) -> [TurnID: [ConversationMessage]] {
        let assistantIndexByTurnID: [TurnID: Int] = Dictionary(uniqueKeysWithValues: messages.indices.compactMap { index -> (TurnID, Int)? in
            let message = messages[index]
            guard let turnID = message.turnID,
                  completedAssistantByTurnID[turnID]?.id == message.id else {
                return nil
            }
            return (turnID, index)
        })
        var result: [TurnID: [ConversationMessage]] = [:]
        for index in messages.indices {
            let message = messages[index]
            guard let turnID = message.turnID,
                  let assistantIndex = assistantIndexByTurnID[turnID],
                  index > assistantIndex,
                  isActivityMessage(message) else {
                continue
            }
            result[turnID, default: []].append(message)
        }
        return result
    }

    private static func isProcessBatchSummarizedByCommentary(
        _ processMessages: [ConversationMessage],
        nextMessage: ConversationMessage?
    ) -> Bool {
        guard let turnID = sharedTurnID(in: processMessages),
              let nextMessage,
              nextMessage.role == .assistant,
              nextMessage.kind == .commentary,
              nextMessage.turnID == turnID else {
            return false
        }
        // commentary 已经把刚才的内部推理与工具结果整理成面向用户的检查点；
        // 数据仍保留在 ConversationStore，只是不重复占据主时间线。
        return true
    }

    private static func planMessagesByTurnID(
        in messages: [ConversationMessage],
        completedTurnIDs: Set<TurnID>
    ) -> [TurnID: [ConversationMessage]] {
        var result: [TurnID: [ConversationMessage]] = [:]
        for message in messages {
            guard let turnID = message.turnID,
                  completedTurnIDs.contains(turnID),
                  message.role == .system,
                  message.kind == .plan else {
                continue
            }
            result[turnID, default: []].append(message)
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
