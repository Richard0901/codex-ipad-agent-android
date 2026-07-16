import XCTest
@testable import MimiRemote

final class ConversationProcessGrouperTests: XCTestCase {
    func testBuilderGroupsReasoningAndFollowingActivitiesWithStableIdentity() throws {
        let reasoning = makeReasoning(id: "reasoning-1", turnID: "turn-1", text: "先检查实现，再完成修改。")
        let command = makeActivity(
            id: "command-1",
            turnID: "turn-1",
            kind: .commandSummary,
            payload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行 xcodebuild test",
                status: "completed",
                command: "xcodebuild test"
            )
        )
        let file = makeActivity(
            id: "file-1",
            turnID: "turn-1",
            kind: .fileChangeSummary,
            payload: ConversationActivityPayload(
                category: .editFile,
                displayTitle: "修改 ConversationView.swift",
                status: "completed",
                filePaths: ["ConversationView.swift"]
            )
        )

        let activeItems = ConversationTimelineItemBuilder.items(from: [reasoning, command])
        let activeGroup = try processGroup(in: activeItems, at: 0)
        XCTAssertEqual(activeGroup.title, "先检查实现，再完成修改。")
        XCTAssertEqual(activeGroup.activities.map(\.stableID), ["command-1"])
        XCTAssertEqual(activeGroup.status, .running)

        let completedItems = ConversationTimelineItemBuilder.items(from: [
            reasoning,
            command,
            file,
            makeAssistant(id: "assistant-1", turnID: "turn-1")
        ])
        let completedGroup = try processGroup(in: completedItems, at: 0)
        XCTAssertEqual(completedGroup.id, activeGroup.id)
        XCTAssertEqual(completedGroup.activities.map(\.stableID), ["command-1", "file-1"])
        XCTAssertEqual(completedGroup.status, .completed)
        XCTAssertEqual(completedItems.count, 2)
    }

    func testCommentaryDoesNotStartProcessGroup() {
        let commentary = ConversationMessage(
            stableID: "commentary-1",
            turnID: "turn-commentary",
            role: .assistant,
            kind: .commentary,
            content: "我先检查上下文。",
            sendStatus: .confirmed
        )
        let command = makeActivity(
            id: "command-commentary",
            turnID: "turn-commentary",
            kind: .commandSummary,
            payload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行 git status",
                status: "completed",
                command: "git status"
            )
        )

        let items = ConversationTimelineItemBuilder.items(from: [commentary, command])

        XCTAssertEqual(items.count, 2)
        guard case .message(let visibleCommentary) = items[0] else {
            return XCTFail("commentary 必须保持正文，不能作为阶段标题")
        }
        XCTAssertEqual(visibleCommentary.kind, .commentary)
        guard case .activity(let visibleCommand) = items[1] else {
            return XCTFail("没有 reasoning 标题时命令必须保持独立")
        }
        XCTAssertEqual(visibleCommand.stableID, "command-commentary")
    }

    func testLatestReasoningUpdatesSingleGroupWithoutChangingIdentity() throws {
        let firstReasoning = makeReasoning(id: "reasoning-a", turnID: "turn-a", text: "先定位问题")
        let firstCommand = makeActivity(
            id: "command-a",
            turnID: "turn-a",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "运行 rg", status: "completed")
        )
        let secondReasoning = makeReasoning(id: "reasoning-b", turnID: "turn-a", text: "再验证修复")
        let secondCommand = makeActivity(
            id: "command-b",
            turnID: "turn-a",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "运行测试", status: "completed")
        )

        let firstItems = ConversationTimelineItemBuilder.items(from: [firstReasoning, firstCommand])
        let firstGroup = try processGroup(in: firstItems, at: 0)

        let items = ConversationTimelineItemBuilder.items(from: [
            firstReasoning,
            firstCommand,
            secondReasoning,
            secondCommand
        ])

        XCTAssertEqual(items.count, 1)
        let updatedGroup = try processGroup(in: items, at: 0)
        XCTAssertEqual(updatedGroup.id, firstGroup.id)
        XCTAssertEqual(updatedGroup.title, "再验证修复")
        XCTAssertEqual(updatedGroup.activities.map(\.stableID), ["command-a", "command-b"])
    }

    func testBuilderDoesNotGroupAcrossTurnsOrCreateEmptyGroup() {
        let reasoning = makeReasoning(id: "reasoning-turn-a", turnID: "turn-a", text: "检查 A")
        let otherTurnCommand = makeActivity(
            id: "command-turn-b",
            turnID: "turn-b",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "运行 B", status: "completed")
        )

        let items = ConversationTimelineItemBuilder.items(from: [reasoning, otherTurnCommand])

        XCTAssertEqual(items.count, 1)
        guard case .activity(let standaloneCommand) = items[0] else {
            return XCTFail("跨 turn 命令不应并入上一阶段")
        }
        XCTAssertEqual(standaloneCommand.stableID, "command-turn-b")
    }

    func testResolvedInteractionCanJoinGroupButPendingInteractionEndsIt() {
        let reasoning = makeReasoning(id: "reasoning-input", turnID: "turn-input", text: "等待确认后继续")
        let command = makeActivity(
            id: "command-input",
            turnID: "turn-input",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "运行迁移", status: "completed")
        )
        let pending = ConversationMessage(
            stableID: "pending-input",
            turnID: "turn-input",
            role: .system,
            kind: .userInput,
            content: "请选择迁移方式",
            sendStatus: .confirmed
        )
        let submitted = ConversationMessage(
            stableID: "submitted-input",
            turnID: "turn-input",
            role: .system,
            kind: .userInput,
            content: "补充信息已提交：直接迁移",
            sendStatus: .confirmed
        )

        let pendingElements = ConversationProcessGrouper.elements(
            from: [reasoning, command, pending],
            turnCompleted: false
        )
        guard pendingElements.count == 2,
              case .group = pendingElements[0],
              case .activity(let visiblePending) = pendingElements[1] else {
            return XCTFail("待输入卡必须结束当前组并保持独立")
        }
        XCTAssertEqual(visiblePending.stableID, "pending-input")

        let submittedItems = ConversationTimelineItemBuilder.items(from: [reasoning, command, submitted])
        guard case .processGroup(let group) = submittedItems.first else {
            return XCTFail("已提交结果可以作为阶段里程碑收进组内")
        }
        XCTAssertEqual(group.activities.map(\.stableID), ["command-input", "submitted-input"])
    }

    func testCommentaryReplacesCompletedInternalBatchAndKeepsOnlyTrailingProcess() throws {
        let firstReasoning = makeReasoning(id: "reasoning-first", turnID: "turn-real", text: "先检查登录链路")
        let firstCommand = makeActivity(
            id: "command-first",
            turnID: "turn-real",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "查看登录日志", status: "completed")
        )
        let firstCommentary = makeCommentary(
            id: "commentary-first",
            turnID: "turn-real",
            text: "链路已经确认：登录和 ticket 创建都成功。"
        )
        let secondReasoning = makeReasoning(id: "reasoning-second", turnID: "turn-real", text: "检查私钥配置")
        let secondCommand = makeActivity(
            id: "command-second",
            turnID: "turn-real",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "读取生产配置", status: "completed")
        )
        let secondCommentary = makeCommentary(
            id: "commentary-second",
            turnID: "turn-real",
            text: "根因已经锁定：线上私钥文件不存在。"
        )
        let trailingReasoning = makeReasoning(id: "reasoning-trailing", turnID: "turn-real", text: "Planning credential validation")
        let trailingCommand = makeActivity(
            id: "command-trailing",
            turnID: "turn-real",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "检查备份", status: "running")
        )

        let items = ConversationTimelineItemBuilder.items(from: [
            firstReasoning,
            firstCommand,
            firstCommentary,
            secondReasoning,
            secondCommand,
            secondCommentary,
            trailingReasoning,
            trailingCommand
        ])

        XCTAssertEqual(items.count, 3)
        guard case .message(let firstVisible) = items[0],
              case .message(let secondVisible) = items[1] else {
            return XCTFail("commentary 应替代已经总结过的内部过程批次")
        }
        XCTAssertEqual(firstVisible.kind, .commentary)
        XCTAssertEqual(secondVisible.kind, .commentary)
        let trailingGroup = try processGroup(in: items, at: 2)
        XCTAssertEqual(trailingGroup.title, "Planning credential validation")
        XCTAssertEqual(trailingGroup.activities.map(\.stableID), ["command-trailing"])
    }

    func testReasoningSummaryDeltaCarriesThinkingPayload() throws {
        let notification = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thread-live","turnId":"turn-live","itemId":"reasoning-live","summaryIndex":0,"delta":"正在检查实现"}}"#.utf8)
        )
        var projector = CodexAppServerEventProjector()

        guard case .messageCompleted(let message, _) = try XCTUnwrap(projector.project(notification)) else {
            return XCTFail("reasoning delta 应投影为流式系统消息")
        }
        XCTAssertEqual(message.kind, .reasoningSummary)
        XCTAssertEqual(message.activityPayload?.category, .thinking)
        XCTAssertEqual(message.activityPayload?.subtitle, "正在检查实现")
        XCTAssertTrue(message.activityPayload?.isInProgress == true)
    }

    func testLiveAgentMessageKeepsCommentaryKindFromItemStarted() throws {
        let started = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/started","params":{"threadId":"thread-live","turnId":"turn-live","item":{"type":"agentMessage","id":"commentary-live","text":"","phase":"commentary"}}}"#.utf8)
        )
        let delta = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/agentMessage/delta","params":{"threadId":"thread-live","turnId":"turn-live","itemId":"commentary-live","delta":"链路已经确认"}}"#.utf8)
        )
        let completed = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/completed","params":{"threadId":"thread-live","turnId":"turn-live","item":{"type":"agentMessage","id":"commentary-live","text":"链路已经确认。"}}}"#.utf8)
        )
        var projector = CodexAppServerEventProjector()

        XCTAssertNil(projector.project(started))
        guard case .assistantDelta(let projectedDelta, _) = try XCTUnwrap(projector.project(delta)) else {
            return XCTFail("commentary delta 应保持助手正文语义")
        }
        XCTAssertEqual(projectedDelta.kind, .commentary)

        guard case .messageCompleted(let message, _) = try XCTUnwrap(projector.project(completed)) else {
            return XCTFail("commentary completed 应投影为完整助手正文")
        }
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.kind, .commentary)
    }

    @MainActor
    func testConversationStoreKeepsCommentaryKindAcrossBufferedDeltas() {
        let store = ConversationStore()
        let sessionID = "commentary-stream-store"
        let firstMetadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: "turn-commentary",
            itemID: "commentary-item",
            messageID: "commentary-item",
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )
        let secondMetadata = AgentEventMetadata(
            seq: 2,
            sessionID: sessionID,
            turnID: "turn-commentary",
            itemID: "commentary-item",
            messageID: "commentary-item",
            clientMessageID: nil,
            revision: 2,
            createdAt: nil
        )

        store.applyAssistantDelta(
            AgentDelta(text: "链路已经", role: .assistant, kind: .commentary),
            metadata: firstMetadata,
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: "确认。", role: .assistant, kind: .commentary),
            metadata: secondMetadata,
            fallbackSessionID: sessionID
        )
        store.resetLiveTranscript(sessionID: sessionID)

        XCTAssertEqual(store.messages(for: sessionID).first?.kind, .commentary)
        XCTAssertEqual(store.messages(for: sessionID).first?.content, "链路已经确认。")
    }

    private func processGroup(
        in items: [ConversationTimelineItem],
        at index: Int
    ) throws -> ConversationProcessGroup {
        guard case .processGroup(let group) = items[index] else {
            throw ProcessGroupTestError.expectedGroup
        }
        return group
    }

    private func makeReasoning(id: String, turnID: TurnID, text: String) -> ConversationMessage {
        ConversationMessage(
            stableID: id,
            turnID: turnID,
            role: .system,
            kind: .reasoningSummary,
            content: text,
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .thinking,
                displayTitle: "推理摘要",
                subtitle: text,
                status: "inProgress"
            )
        )
    }

    private func makeActivity(
        id: String,
        turnID: TurnID,
        kind: MessageKind,
        payload: ConversationActivityPayload
    ) -> ConversationMessage {
        ConversationMessage(
            stableID: id,
            turnID: turnID,
            role: .system,
            kind: kind,
            content: payload.summaryText,
            sendStatus: .confirmed,
            activityPayload: payload
        )
    }

    private func makeCommentary(id: String, turnID: TurnID, text: String) -> ConversationMessage {
        ConversationMessage(
            stableID: id,
            turnID: turnID,
            role: .assistant,
            kind: .commentary,
            content: text,
            sendStatus: .confirmed
        )
    }

    private func makeAssistant(id: String, turnID: TurnID) -> ConversationMessage {
        ConversationMessage(
            stableID: id,
            turnID: turnID,
            role: .assistant,
            content: "已完成。",
            sendStatus: .confirmed
        )
    }
}

private enum ProcessGroupTestError: Error {
    case expectedGroup
}
