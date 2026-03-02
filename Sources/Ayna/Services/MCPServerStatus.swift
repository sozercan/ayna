import Foundation

struct MCPServerStatus: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case disabled
        case connecting
        case connected
        case reconnecting
        case error(String)
        case idle
    }

    var id: UUID {
        configID
    }

    let configID: UUID
    let name: String
    let state: State
    let lastError: String?
    let toolsCount: Int
    let lastUpdated: Date
}
