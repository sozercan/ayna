import Foundation

enum ResponseGroupStatus: String, Codable, Equatable, Sendable {
    case streaming
    case completed
    case failed
    case selected
}

struct ResponseGroupEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let modelName: String
    var status: ResponseGroupStatus
}

struct ResponseGroup: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let userMessageId: UUID
    var responses: [ResponseGroupEntry]
    var selectedResponseId: UUID?
    let createdAt: Date

    typealias ResponseEntry = ResponseGroupEntry
    typealias ResponseStatus = ResponseGroupStatus

    init(
        id: UUID = UUID(),
        userMessageId: UUID,
        responses: [ResponseEntry] = [],
        selectedResponseId: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userMessageId = userMessageId
        self.responses = responses
        self.selectedResponseId = selectedResponseId
        self.createdAt = createdAt
    }

    var isComplete: Bool {
        responses.allSatisfy { $0.status == .completed || $0.status == .failed || $0.status == .selected }
    }

    var hasSelection: Bool {
        selectedResponseId != nil
    }

    var selectedEntry: ResponseEntry? {
        responses.first { $0.id == selectedResponseId }
    }

    mutating func selectResponse(_ messageId: UUID) {
        selectedResponseId = messageId
        for index in responses.indices where responses[index].status == .selected {
            responses[index].status = .completed
        }
        for index in responses.indices where responses[index].id == messageId {
            responses[index].status = .selected
        }
    }

    mutating func updateStatus(for messageId: UUID, status: ResponseGroupStatus) {
        if let index = responses.firstIndex(where: { $0.id == messageId }) {
            responses[index].status = status
        }
    }

    mutating func addResponse(messageId: UUID, modelName: String, status: ResponseGroupStatus = .streaming) {
        let entry = ResponseEntry(id: messageId, modelName: modelName, status: status)
        responses.append(entry)
    }
}
