//
//  CouncilModels.swift
//  ayna
//
//  Created on 12/10/25.
//

import Foundation

// MARK: - Council Stage

/// Tracks the current stage of a council deliberation
enum CouncilStage: String, Codable, Equatable, Sendable {
    /// Council not yet started
    case idle
    /// Stage 1: Collecting individual responses from all council models
    case stage1Collecting
    /// Stage 1 complete, all responses collected
    case stage1Complete
    /// Stage 2: Models reviewing and ranking each other's responses
    case stage2Reviewing
    /// Stage 2 complete, all rankings collected
    case stage2Complete
    /// Stage 3: Chairman synthesizing final answer
    case stage3Synthesizing
    /// Council deliberation complete
    case complete
    /// Council failed (error occurred)
    case failed

    /// Human-readable description of the stage
    var displayName: String {
        switch self {
        case .idle:
            "Idle"
        case .stage1Collecting:
            "Collecting Responses"
        case .stage1Complete:
            "Responses Collected"
        case .stage2Reviewing:
            "Peer Review"
        case .stage2Complete:
            "Review Complete"
        case .stage3Synthesizing:
            "Synthesizing"
        case .complete:
            "Complete"
        case .failed:
            "Failed"
        }
    }

    /// The stage number (1, 2, or 3), or nil for idle/complete/failed
    var stageNumber: Int? {
        switch self {
        case .stage1Collecting, .stage1Complete:
            1
        case .stage2Reviewing, .stage2Complete:
            2
        case .stage3Synthesizing:
            3
        case .idle, .complete, .failed:
            nil
        }
    }
}

// MARK: - Council Response (Stage 1)

/// A single model's response in Stage 1 of the council deliberation
struct CouncilResponse: Identifiable, Codable, Equatable, Sendable {
    /// Unique identifier for this response
    let id: UUID
    /// The model that generated this response
    let model: String
    /// The response content (may be updated during streaming)
    var content: String
    /// Current status of the response
    var status: ResponseGroupStatus
    /// Anonymous label assigned for peer review (e.g., "Response A")
    let anonymousLabel: String
    /// When the response started streaming
    let startedAt: Date
    /// When the response completed (nil if still streaming)
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        model: String,
        content: String = "",
        status: ResponseGroupStatus = .streaming,
        anonymousLabel: String,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.model = model
        self.content = content
        self.status = status
        self.anonymousLabel = anonymousLabel
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// Check if this response is still in progress
    var isStreaming: Bool {
        status == .streaming
    }

    /// Check if this response completed successfully
    var isCompleted: Bool {
        status == .completed
    }

    /// Check if this response failed
    var isFailed: Bool {
        status == .failed
    }
}

// MARK: - Council Ranking (Stage 2)

/// A single model's ranking evaluation in Stage 2 of the council deliberation
struct CouncilRanking: Identifiable, Codable, Equatable, Sendable {
    /// Unique identifier for this ranking
    let id: UUID
    /// The model that performed this review
    let reviewerModel: String
    /// The full evaluation text from the model
    var evaluationText: String
    /// Parsed ranking extracted from evaluation (e.g., ["Response B", "Response A", "Response C"])
    var parsedRanking: [String]
    /// Current status of the ranking
    var status: ResponseGroupStatus

    init(
        id: UUID = UUID(),
        reviewerModel: String,
        evaluationText: String = "",
        parsedRanking: [String] = [],
        status: ResponseGroupStatus = .streaming
    ) {
        self.id = id
        self.reviewerModel = reviewerModel
        self.evaluationText = evaluationText
        self.parsedRanking = parsedRanking
        self.status = status
    }

    /// Check if this ranking is still in progress
    var isStreaming: Bool {
        status == .streaming
    }

    /// Check if this ranking completed successfully
    var isCompleted: Bool {
        status == .completed
    }

    /// Check if this ranking failed
    var isFailed: Bool {
        status == .failed
    }
}

// MARK: - Aggregate Ranking

/// Aggregated ranking result across all reviewers
struct AggregateRanking: Codable, Equatable, Sendable {
    /// The model being ranked
    let model: String
    /// Average rank position (lower is better, 1.0 = always ranked first)
    let averageRank: Double
    /// Number of votes/rankings this model received
    let votesCount: Int

    init(model: String, averageRank: Double, votesCount: Int) {
        self.model = model
        self.averageRank = averageRank
        self.votesCount = votesCount
    }

    /// Formatted average rank for display (e.g., "1.33")
    var formattedAverageRank: String {
        String(format: "%.2f", averageRank)
    }
}

// MARK: - Council Session

/// A complete council deliberation session attached to a user message
struct CouncilSession: Identifiable, Codable, Equatable, Sendable {
    /// Unique identifier for this session
    let id: UUID
    /// The user message that triggered this council session
    let userMessageId: UUID
    /// Current stage of the council
    var stage: CouncilStage

    // MARK: Configuration

    /// Models participating in the council (Stage 1 responders and Stage 2 reviewers)
    let councilModels: [String]
    /// Model designated to synthesize the final answer (Stage 3)
    let chairmanModel: String

    // MARK: Stage 1 Data

    /// Individual responses from each council model
    var responses: [CouncilResponse]
    /// Mapping from anonymous labels to model names (e.g., "Response A" -> "gpt-4o")
    var labelToModel: [String: String]

    // MARK: Stage 2 Data

    /// Rankings from each council model
    var rankings: [CouncilRanking]
    /// Aggregated rankings across all reviewers
    var aggregateRankings: [AggregateRanking]

    // MARK: Stage 3 Data

    /// The chairman's final synthesized answer
    var finalSynthesis: String?
    /// Status of the final synthesis
    var finalSynthesisStatus: ResponseGroupStatus?

    // MARK: Metadata

    /// When the council session was created
    let createdAt: Date
    /// When the council session completed (nil if still in progress)
    var completedAt: Date?
    /// Error message if the council failed
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        userMessageId: UUID,
        councilModels: [String],
        chairmanModel: String,
        stage: CouncilStage = .idle,
        responses: [CouncilResponse] = [],
        labelToModel: [String: String] = [:],
        rankings: [CouncilRanking] = [],
        aggregateRankings: [AggregateRanking] = [],
        finalSynthesis: String? = nil,
        finalSynthesisStatus: ResponseGroupStatus? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.userMessageId = userMessageId
        self.councilModels = councilModels
        self.chairmanModel = chairmanModel
        self.stage = stage
        self.responses = responses
        self.labelToModel = labelToModel
        self.rankings = rankings
        self.aggregateRankings = aggregateRankings
        self.finalSynthesis = finalSynthesis
        self.finalSynthesisStatus = finalSynthesisStatus
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }

    // MARK: Computed Properties

    /// Check if the council is currently in progress
    var isInProgress: Bool {
        switch stage {
        case .stage1Collecting, .stage2Reviewing, .stage3Synthesizing:
            true
        default:
            false
        }
    }

    /// Check if the council completed successfully
    var isComplete: Bool {
        stage == .complete
    }

    /// Check if the council failed
    var isFailed: Bool {
        stage == .failed
    }

    /// Number of responses that completed successfully
    var completedResponsesCount: Int {
        responses.filter(\.isCompleted).count
    }

    /// Number of rankings that completed successfully
    var completedRankingsCount: Int {
        rankings.filter(\.isCompleted).count
    }

    /// Check if all Stage 1 responses are complete
    var allResponsesComplete: Bool {
        !responses.isEmpty && responses.allSatisfy { $0.status == .completed || $0.status == .failed }
    }

    /// Check if all Stage 2 rankings are complete
    var allRankingsComplete: Bool {
        !rankings.isEmpty && rankings.allSatisfy { $0.status == .completed || $0.status == .failed }
    }

    // MARK: Helper Methods

    /// Get the response for a specific model
    func getResponse(for model: String) -> CouncilResponse? {
        responses.first { $0.model == model }
    }

    /// Get the ranking from a specific reviewer
    func getRanking(from reviewer: String) -> CouncilRanking? {
        rankings.first { $0.reviewerModel == reviewer }
    }

    /// Get the model name for an anonymous label (e.g., "Response A" -> "gpt-4o")
    func getModel(for label: String) -> String? {
        labelToModel[label]
    }

    /// Get the anonymous label for a model (e.g., "gpt-4o" -> "Response A")
    func getLabel(for model: String) -> String? {
        labelToModel.first { $0.value == model }?.key
    }

    // MARK: Mutation Methods

    /// Update a response's content (used during streaming)
    mutating func updateResponseContent(for model: String, content: String) {
        if let index = responses.firstIndex(where: { $0.model == model }) {
            responses[index].content = content
        }
    }

    /// Append content to a response (used during streaming)
    mutating func appendToResponse(for model: String, chunk: String) {
        if let index = responses.firstIndex(where: { $0.model == model }) {
            responses[index].content += chunk
        }
    }

    /// Mark a response as completed
    mutating func completeResponse(for model: String) {
        if let index = responses.firstIndex(where: { $0.model == model }) {
            responses[index].status = .completed
            responses[index].completedAt = Date()
        }
    }

    /// Mark a response as failed
    mutating func failResponse(for model: String) {
        if let index = responses.firstIndex(where: { $0.model == model }) {
            responses[index].status = .failed
            responses[index].completedAt = Date()
        }
    }

    /// Update a ranking's evaluation text (used during streaming)
    mutating func updateRankingText(for reviewer: String, text: String) {
        if let index = rankings.firstIndex(where: { $0.reviewerModel == reviewer }) {
            rankings[index].evaluationText = text
        }
    }

    /// Append text to a ranking (used during streaming)
    mutating func appendToRanking(for reviewer: String, chunk: String) {
        if let index = rankings.firstIndex(where: { $0.reviewerModel == reviewer }) {
            rankings[index].evaluationText += chunk
        }
    }

    /// Mark a ranking as completed with parsed ranking
    mutating func completeRanking(for reviewer: String, parsedRanking: [String]) {
        if let index = rankings.firstIndex(where: { $0.reviewerModel == reviewer }) {
            rankings[index].status = .completed
            rankings[index].parsedRanking = parsedRanking
        }
    }

    /// Mark a ranking as failed
    mutating func failRanking(for reviewer: String) {
        if let index = rankings.firstIndex(where: { $0.reviewerModel == reviewer }) {
            rankings[index].status = .failed
        }
    }

    /// Append content to final synthesis (used during streaming)
    mutating func appendToFinalSynthesis(_ chunk: String) {
        if finalSynthesis == nil {
            finalSynthesis = chunk
        } else {
            finalSynthesis?.append(chunk)
        }
    }
}
