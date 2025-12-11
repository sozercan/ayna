@testable import Ayna
import XCTest

final class CouncilModelsTests: XCTestCase {
    // MARK: - CouncilStage Tests

    func testCouncilStageRawValues() {
        XCTAssertEqual(CouncilStage.idle.rawValue, "idle")
        XCTAssertEqual(CouncilStage.stage1Collecting.rawValue, "stage1Collecting")
        XCTAssertEqual(CouncilStage.stage1Complete.rawValue, "stage1Complete")
        XCTAssertEqual(CouncilStage.stage2Reviewing.rawValue, "stage2Reviewing")
        XCTAssertEqual(CouncilStage.stage2Complete.rawValue, "stage2Complete")
        XCTAssertEqual(CouncilStage.stage3Synthesizing.rawValue, "stage3Synthesizing")
        XCTAssertEqual(CouncilStage.complete.rawValue, "complete")
        XCTAssertEqual(CouncilStage.failed.rawValue, "failed")
    }

    func testCouncilStageNumbers() {
        XCTAssertNil(CouncilStage.idle.stageNumber)
        XCTAssertEqual(CouncilStage.stage1Collecting.stageNumber, 1)
        XCTAssertEqual(CouncilStage.stage1Complete.stageNumber, 1)
        XCTAssertEqual(CouncilStage.stage2Reviewing.stageNumber, 2)
        XCTAssertEqual(CouncilStage.stage2Complete.stageNumber, 2)
        XCTAssertEqual(CouncilStage.stage3Synthesizing.stageNumber, 3)
        XCTAssertNil(CouncilStage.complete.stageNumber)
        XCTAssertNil(CouncilStage.failed.stageNumber)
    }

    func testCouncilStageDisplayNames() {
        XCTAssertEqual(CouncilStage.idle.displayName, "Idle")
        XCTAssertEqual(CouncilStage.stage1Collecting.displayName, "Collecting Responses")
        XCTAssertEqual(CouncilStage.stage3Synthesizing.displayName, "Synthesizing")
        XCTAssertEqual(CouncilStage.complete.displayName, "Complete")
        XCTAssertEqual(CouncilStage.failed.displayName, "Failed")
    }

    func testCouncilStageCodable() throws {
        let stages: [CouncilStage] = [.idle, .stage1Collecting, .stage2Reviewing, .stage3Synthesizing, .complete, .failed]

        for stage in stages {
            let encoded = try JSONEncoder().encode(stage)
            let decoded = try JSONDecoder().decode(CouncilStage.self, from: encoded)
            XCTAssertEqual(stage, decoded, "Stage \(stage) should round-trip through JSON")
        }
    }

    // MARK: - CouncilResponse Tests

    func testCouncilResponseInitialization() {
        let response = CouncilResponse(
            model: "gpt-4o",
            content: "Test response",
            status: .streaming,
            anonymousLabel: "Response A"
        )

        XCTAssertEqual(response.model, "gpt-4o")
        XCTAssertEqual(response.content, "Test response")
        XCTAssertEqual(response.status, .streaming)
        XCTAssertEqual(response.anonymousLabel, "Response A")
        XCTAssertTrue(response.isStreaming)
        XCTAssertFalse(response.isCompleted)
        XCTAssertFalse(response.isFailed)
        XCTAssertNil(response.completedAt)
    }

    func testCouncilResponseStatusFlags() {
        var response = CouncilResponse(model: "gpt-4o", anonymousLabel: "Response A")

        XCTAssertTrue(response.isStreaming)
        XCTAssertFalse(response.isCompleted)
        XCTAssertFalse(response.isFailed)

        response.status = .completed
        XCTAssertFalse(response.isStreaming)
        XCTAssertTrue(response.isCompleted)
        XCTAssertFalse(response.isFailed)

        response.status = .failed
        XCTAssertFalse(response.isStreaming)
        XCTAssertFalse(response.isCompleted)
        XCTAssertTrue(response.isFailed)
    }

    func testCouncilResponseCodable() throws {
        let original = CouncilResponse(
            id: UUID(),
            model: "claude-3.5-sonnet",
            content: "This is a test response with some content.",
            status: .completed,
            anonymousLabel: "Response B",
            startedAt: Date(),
            completedAt: Date()
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CouncilResponse.self, from: encoded)

        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.model, decoded.model)
        XCTAssertEqual(original.content, decoded.content)
        XCTAssertEqual(original.status, decoded.status)
        XCTAssertEqual(original.anonymousLabel, decoded.anonymousLabel)
    }

    // MARK: - CouncilRanking Tests

    func testCouncilRankingInitialization() {
        let ranking = CouncilRanking(
            reviewerModel: "gpt-4o",
            evaluationText: "Response A is better because...",
            parsedRanking: ["Response A", "Response B", "Response C"],
            status: .completed
        )

        XCTAssertEqual(ranking.reviewerModel, "gpt-4o")
        XCTAssertEqual(ranking.evaluationText, "Response A is better because...")
        XCTAssertEqual(ranking.parsedRanking, ["Response A", "Response B", "Response C"])
        XCTAssertTrue(ranking.isCompleted)
    }

    func testCouncilRankingCodable() throws {
        let original = CouncilRanking(
            id: UUID(),
            reviewerModel: "gemini-pro",
            evaluationText: "FINAL RANKING:\n1. Response C\n2. Response A",
            parsedRanking: ["Response C", "Response A"],
            status: .completed
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CouncilRanking.self, from: encoded)

        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.reviewerModel, decoded.reviewerModel)
        XCTAssertEqual(original.evaluationText, decoded.evaluationText)
        XCTAssertEqual(original.parsedRanking, decoded.parsedRanking)
        XCTAssertEqual(original.status, decoded.status)
    }

    // MARK: - AggregateRanking Tests

    func testAggregateRankingInitialization() {
        let ranking = AggregateRanking(model: "gpt-4o", averageRank: 1.5, votesCount: 4)

        XCTAssertEqual(ranking.model, "gpt-4o")
        XCTAssertEqual(ranking.averageRank, 1.5)
        XCTAssertEqual(ranking.votesCount, 4)
    }

    func testAggregateRankingFormattedAverage() {
        let ranking1 = AggregateRanking(model: "gpt-4o", averageRank: 1.0, votesCount: 3)
        XCTAssertEqual(ranking1.formattedAverageRank, "1.00")

        let ranking2 = AggregateRanking(model: "claude", averageRank: 2.333, votesCount: 3)
        XCTAssertEqual(ranking2.formattedAverageRank, "2.33")

        let ranking3 = AggregateRanking(model: "gemini", averageRank: 1.666666, votesCount: 3)
        XCTAssertEqual(ranking3.formattedAverageRank, "1.67")
    }

    func testAggregateRankingCodable() throws {
        let original = AggregateRanking(model: "claude-3.5-sonnet", averageRank: 1.25, votesCount: 4)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AggregateRanking.self, from: encoded)

        XCTAssertEqual(original.model, decoded.model)
        XCTAssertEqual(original.averageRank, decoded.averageRank)
        XCTAssertEqual(original.votesCount, decoded.votesCount)
    }

    // MARK: - CouncilSession Tests

    func testCouncilSessionInitialization() {
        let userMessageId = UUID()
        let session = CouncilSession(
            userMessageId: userMessageId,
            councilModels: ["gpt-4o", "claude-3.5-sonnet", "gemini-pro"],
            chairmanModel: "claude-3.5-sonnet"
        )

        XCTAssertEqual(session.userMessageId, userMessageId)
        XCTAssertEqual(session.councilModels, ["gpt-4o", "claude-3.5-sonnet", "gemini-pro"])
        XCTAssertEqual(session.chairmanModel, "claude-3.5-sonnet")
        XCTAssertEqual(session.stage, .idle)
        XCTAssertTrue(session.responses.isEmpty)
        XCTAssertTrue(session.labelToModel.isEmpty)
        XCTAssertTrue(session.rankings.isEmpty)
        XCTAssertTrue(session.aggregateRankings.isEmpty)
        XCTAssertNil(session.finalSynthesis)
        XCTAssertNil(session.completedAt)
        XCTAssertNil(session.errorMessage)
    }

    func testCouncilSessionStageFlags() {
        var session = CouncilSession(
            userMessageId: UUID(),
            councilModels: ["gpt-4o"],
            chairmanModel: "gpt-4o"
        )

        // Idle state
        XCTAssertFalse(session.isInProgress)
        XCTAssertFalse(session.isComplete)
        XCTAssertFalse(session.isFailed)

        // Stage 1 in progress
        session.stage = .stage1Collecting
        XCTAssertTrue(session.isInProgress)
        XCTAssertFalse(session.isComplete)
        XCTAssertFalse(session.isFailed)

        // Stage 2 in progress
        session.stage = .stage2Reviewing
        XCTAssertTrue(session.isInProgress)
        XCTAssertFalse(session.isComplete)
        XCTAssertFalse(session.isFailed)

        // Stage 3 in progress
        session.stage = .stage3Synthesizing
        XCTAssertTrue(session.isInProgress)
        XCTAssertFalse(session.isComplete)
        XCTAssertFalse(session.isFailed)

        // Complete
        session.stage = .complete
        XCTAssertFalse(session.isInProgress)
        XCTAssertTrue(session.isComplete)
        XCTAssertFalse(session.isFailed)

        // Failed
        session.stage = .failed
        XCTAssertFalse(session.isInProgress)
        XCTAssertFalse(session.isComplete)
        XCTAssertTrue(session.isFailed)
    }

    func testCouncilSessionResponseMutations() {
        var session = CouncilSession(
            userMessageId: UUID(),
            councilModels: ["gpt-4o", "claude"],
            chairmanModel: "gpt-4o"
        )

        // Add responses
        session.responses = [
            CouncilResponse(model: "gpt-4o", anonymousLabel: "Response A"),
            CouncilResponse(model: "claude", anonymousLabel: "Response B")
        ]

        // Append content
        session.appendToResponse(for: "gpt-4o", chunk: "Hello ")
        session.appendToResponse(for: "gpt-4o", chunk: "world!")
        XCTAssertEqual(session.getResponse(for: "gpt-4o")?.content, "Hello world!")

        // Update content
        session.updateResponseContent(for: "claude", content: "Full content")
        XCTAssertEqual(session.getResponse(for: "claude")?.content, "Full content")

        // Complete response
        session.completeResponse(for: "gpt-4o")
        XCTAssertEqual(session.getResponse(for: "gpt-4o")?.status, .completed)
        XCTAssertNotNil(session.getResponse(for: "gpt-4o")?.completedAt)

        // Fail response
        session.failResponse(for: "claude")
        XCTAssertEqual(session.getResponse(for: "claude")?.status, .failed)

        // Check counts
        XCTAssertEqual(session.completedResponsesCount, 1)
    }

    func testCouncilSessionRankingMutations() {
        var session = CouncilSession(
            userMessageId: UUID(),
            councilModels: ["gpt-4o", "claude"],
            chairmanModel: "gpt-4o"
        )

        // Add rankings
        session.rankings = [
            CouncilRanking(reviewerModel: "gpt-4o"),
            CouncilRanking(reviewerModel: "claude")
        ]

        // Append text
        session.appendToRanking(for: "gpt-4o", chunk: "Response A is good. ")
        session.appendToRanking(for: "gpt-4o", chunk: "Response B is better.")
        XCTAssertEqual(session.getRanking(from: "gpt-4o")?.evaluationText, "Response A is good. Response B is better.")

        // Complete ranking
        session.completeRanking(for: "gpt-4o", parsedRanking: ["Response B", "Response A"])
        XCTAssertEqual(session.getRanking(from: "gpt-4o")?.status, .completed)
        XCTAssertEqual(session.getRanking(from: "gpt-4o")?.parsedRanking, ["Response B", "Response A"])

        // Fail ranking
        session.failRanking(for: "claude")
        XCTAssertEqual(session.getRanking(from: "claude")?.status, .failed)

        // Check counts
        XCTAssertEqual(session.completedRankingsCount, 1)
    }

    func testCouncilSessionLabelMapping() {
        var session = CouncilSession(
            userMessageId: UUID(),
            councilModels: ["gpt-4o", "claude", "gemini"],
            chairmanModel: "gpt-4o"
        )

        session.labelToModel = [
            "Response A": "gpt-4o",
            "Response B": "claude",
            "Response C": "gemini"
        ]

        XCTAssertEqual(session.getModel(for: "Response A"), "gpt-4o")
        XCTAssertEqual(session.getModel(for: "Response B"), "claude")
        XCTAssertEqual(session.getModel(for: "Response C"), "gemini")
        XCTAssertNil(session.getModel(for: "Response D"))

        XCTAssertEqual(session.getLabel(for: "gpt-4o"), "Response A")
        XCTAssertEqual(session.getLabel(for: "claude"), "Response B")
        XCTAssertNil(session.getLabel(for: "unknown"))
    }

    func testCouncilSessionFinalSynthesis() {
        var session = CouncilSession(
            userMessageId: UUID(),
            councilModels: ["gpt-4o"],
            chairmanModel: "gpt-4o"
        )

        XCTAssertNil(session.finalSynthesis)

        session.appendToFinalSynthesis("Based on the council's ")
        XCTAssertEqual(session.finalSynthesis, "Based on the council's ")

        session.appendToFinalSynthesis("deliberation, the answer is...")
        XCTAssertEqual(session.finalSynthesis, "Based on the council's deliberation, the answer is...")
    }

    func testCouncilSessionAllResponsesComplete() {
        var session = CouncilSession(
            userMessageId: UUID(),
            councilModels: ["gpt-4o", "claude"],
            chairmanModel: "gpt-4o"
        )

        // No responses yet
        XCTAssertFalse(session.allResponsesComplete)

        // Add responses
        session.responses = [
            CouncilResponse(model: "gpt-4o", status: .streaming, anonymousLabel: "Response A"),
            CouncilResponse(model: "claude", status: .streaming, anonymousLabel: "Response B")
        ]
        XCTAssertFalse(session.allResponsesComplete)

        // One complete
        session.completeResponse(for: "gpt-4o")
        XCTAssertFalse(session.allResponsesComplete)

        // Both complete (one success, one fail)
        session.failResponse(for: "claude")
        XCTAssertTrue(session.allResponsesComplete)
    }

    func testCouncilSessionCodable() throws {
        let original = CouncilSession(
            id: UUID(),
            userMessageId: UUID(),
            councilModels: ["gpt-4o", "claude-3.5-sonnet", "gemini-pro"],
            chairmanModel: "claude-3.5-sonnet",
            stage: .stage2Complete,
            responses: [
                CouncilResponse(model: "gpt-4o", content: "Response 1", status: .completed, anonymousLabel: "Response A"),
                CouncilResponse(model: "claude-3.5-sonnet", content: "Response 2", status: .completed, anonymousLabel: "Response B"),
                CouncilResponse(model: "gemini-pro", content: "Response 3", status: .completed, anonymousLabel: "Response C")
            ],
            labelToModel: [
                "Response A": "gpt-4o",
                "Response B": "claude-3.5-sonnet",
                "Response C": "gemini-pro"
            ],
            rankings: [
                CouncilRanking(
                    reviewerModel: "gpt-4o",
                    evaluationText: "FINAL RANKING:\n1. Response B\n2. Response C\n3. Response A",
                    parsedRanking: ["Response B", "Response C", "Response A"],
                    status: .completed
                )
            ],
            aggregateRankings: [
                AggregateRanking(model: "claude-3.5-sonnet", averageRank: 1.0, votesCount: 1),
                AggregateRanking(model: "gemini-pro", averageRank: 2.0, votesCount: 1),
                AggregateRanking(model: "gpt-4o", averageRank: 3.0, votesCount: 1)
            ],
            finalSynthesis: "The synthesized answer is...",
            finalSynthesisStatus: .completed,
            createdAt: Date(),
            completedAt: Date(),
            errorMessage: nil
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CouncilSession.self, from: encoded)

        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.userMessageId, decoded.userMessageId)
        XCTAssertEqual(original.councilModels, decoded.councilModels)
        XCTAssertEqual(original.chairmanModel, decoded.chairmanModel)
        XCTAssertEqual(original.stage, decoded.stage)
        XCTAssertEqual(original.responses.count, decoded.responses.count)
        XCTAssertEqual(original.labelToModel, decoded.labelToModel)
        XCTAssertEqual(original.rankings.count, decoded.rankings.count)
        XCTAssertEqual(original.aggregateRankings.count, decoded.aggregateRankings.count)
        XCTAssertEqual(original.finalSynthesis, decoded.finalSynthesis)
        XCTAssertEqual(original.finalSynthesisStatus, decoded.finalSynthesisStatus)
    }

    // MARK: - Conversation Integration Tests

    func testConversationCouncilSessionIntegration() {
        var conversation = Conversation(title: "Test", model: "gpt-4o")
        let userMessage = Message(role: .user, content: "Test question")
        conversation.addMessage(userMessage)

        // Initially no council sessions
        XCTAssertTrue(conversation.councilSessions.isEmpty)
        XCTAssertFalse(conversation.hasCouncilSession(for: userMessage.id))
        XCTAssertNil(conversation.getCouncilSession(for: userMessage.id))

        // Add council session
        let session = CouncilSession(
            userMessageId: userMessage.id,
            councilModels: ["gpt-4o", "claude"],
            chairmanModel: "gpt-4o"
        )
        conversation.addCouncilSession(session)

        XCTAssertEqual(conversation.councilSessions.count, 1)
        XCTAssertTrue(conversation.hasCouncilSession(for: userMessage.id))
        XCTAssertNotNil(conversation.getCouncilSession(for: userMessage.id))
        XCTAssertEqual(conversation.getCouncilSession(for: userMessage.id)?.councilModels, ["gpt-4o", "claude"])

        // Update council session
        var updatedSession = session
        updatedSession.stage = .complete
        updatedSession.finalSynthesis = "The answer is 42"
        conversation.updateCouncilSession(updatedSession)

        XCTAssertEqual(conversation.getCouncilSession(for: userMessage.id)?.stage, .complete)
        XCTAssertEqual(conversation.getCouncilSession(for: userMessage.id)?.finalSynthesis, "The answer is 42")

        // Get by session ID
        XCTAssertNotNil(conversation.getCouncilSession(byId: session.id))
        XCTAssertEqual(conversation.getCouncilSession(byId: session.id)?.stage, .complete)
    }

    func testConversationWithCouncilSessionCodable() throws {
        var conversation = Conversation(title: "Test Conversation", model: "gpt-4o")
        let userMessage = Message(role: .user, content: "What is the meaning of life?")
        conversation.addMessage(userMessage)

        let session = CouncilSession(
            userMessageId: userMessage.id,
            councilModels: ["gpt-4o", "claude-3.5-sonnet"],
            chairmanModel: "gpt-4o",
            stage: .complete,
            finalSynthesis: "42"
        )
        conversation.addCouncilSession(session)

        let encoded = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode(Conversation.self, from: encoded)

        XCTAssertEqual(decoded.councilSessions.count, 1)
        XCTAssertEqual(decoded.councilSessions.first?.userMessageId, userMessage.id)
        XCTAssertEqual(decoded.councilSessions.first?.stage, .complete)
        XCTAssertEqual(decoded.councilSessions.first?.finalSynthesis, "42")
    }

    func testConversationBackwardCompatibilityWithoutCouncilSessions() throws {
        // Simulate JSON from an older version without councilSessions
        let oldJSON = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "title": "Old Conversation",
            "messages": [],
            "createdAt": 0,
            "updatedAt": 0,
            "model": "gpt-4o",
            "systemPromptMode": {"type": "inheritGlobal"},
            "temperature": 0.7,
            "multiModelEnabled": false,
            "activeModels": [],
            "responseGroups": []
        }
        """

        let data = oldJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)

        // Should decode successfully with empty councilSessions
        XCTAssertTrue(decoded.councilSessions.isEmpty)
        XCTAssertEqual(decoded.title, "Old Conversation")
    }
}
