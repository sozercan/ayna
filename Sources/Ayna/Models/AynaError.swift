import Foundation

enum AynaError: LocalizedError, Sendable {
    case networkError(underlying: Error)

    case httpError(statusCode: Int, message: String?)

    case timeout

    case rateLimited(retryAfter: TimeInterval?)

    case missingAPIKey(provider: String)

    case invalidAPIKey(provider: String)

    case missingConfiguration(detail: String)

    case authenticationFailed(reason: String)

    case invalidEndpoint(String)

    case noModelSelected

    case modelNotFound(modelName: String)

    case unsupportedProvider(provider: String, operation: String)

    case capabilityMismatch(expected: String, actual: String)

    case invalidResponse(detail: String?)

    case contentFiltered(reason: String)

    case apiError(message: String)

    case toolNotFound(toolName: String)

    case toolExecutionFailed(toolName: String, reason: String)

    case toolChainDepthExceeded(maxDepth: Int)

    case encodingFailed(detail: String)

    case decodingFailed(detail: String)

    case fileOperationFailed(operation: String, path: String?)

    case keychainError(operation: String, status: OSStatus?)

    case conversationNotFound(id: UUID)

    case messageNotFound(id: UUID)

    case cancelled

    case unknown(message: String, underlying: Error?)

    var errorDescription: String? {
        switch self {
        case let .networkError(underlying):
            return "Network error: \(underlying.localizedDescription)"
        case let .httpError(statusCode, message):
            if let message {
                return message
            }
            return "Server error (HTTP \(statusCode))"
        case .timeout:
            return "Request timed out"
        case .rateLimited:
            return "Rate limit exceeded. Please wait before trying again."
        case let .missingAPIKey(provider):
            return "\(provider) API key not configured"
        case let .invalidAPIKey(provider):
            return "Invalid \(provider) API key"
        case let .missingConfiguration(detail):
            return "Missing configuration: \(detail)"
        case let .authenticationFailed(reason):
            return "Authentication failed: \(reason)"
        case let .invalidEndpoint(detail):
            return "Invalid endpoint: \(detail)"
        case .noModelSelected:
            return "No model selected"
        case let .modelNotFound(modelName):
            return "Model '\(modelName)' not found"
        case let .unsupportedProvider(provider, operation):
            return "\(operation) is not supported for \(provider)"
        case let .capabilityMismatch(expected, actual):
            return "Expected \(expected) model, but got \(actual)"
        case let .invalidResponse(detail):
            if let detail {
                return "Invalid API response: \(detail)"
            }
            return "Invalid response from API"
        case let .contentFiltered(reason):
            return "Content filtered: \(reason)"
        case let .apiError(message):
            return message
        case let .toolNotFound(toolName):
            return "Tool '\(toolName)' not found"
        case let .toolExecutionFailed(toolName, reason):
            return "Tool '\(toolName)' failed: \(reason)"
        case let .toolChainDepthExceeded(maxDepth):
            return "Tool chain exceeded maximum depth of \(maxDepth)"
        case let .encodingFailed(detail):
            return "Failed to encode data: \(detail)"
        case let .decodingFailed(detail):
            return "Failed to decode data: \(detail)"
        case let .fileOperationFailed(operation, path):
            if let path {
                return "File \(operation) failed: \(path)"
            }
            return "File \(operation) failed"
        case let .keychainError(operation, status):
            if let status {
                return "Keychain \(operation) failed (status: \(status))"
            }
            return "Keychain \(operation) failed"
        case .conversationNotFound:
            return "Conversation not found"
        case .messageNotFound:
            return "Message not found"
        case .cancelled:
            return "Operation was cancelled"
        case let .unknown(message, _):
            return message
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .networkError:
            return "Check your internet connection and try again"
        case let .httpError(statusCode, _):
            if statusCode >= 500 {
                return "The server is having issues. Please try again later."
            }
            return "Check your configuration and try again"
        case .timeout:
            return "The request took too long. Try again or use a shorter message."
        case let .rateLimited(retryAfter):
            if let seconds = retryAfter {
                return "Wait \(Int(seconds)) seconds before trying again"
            }
            return "Wait a moment before trying again"
        case let .missingAPIKey(provider):
            return "Add your \(provider) API key in Settings → Models"
        case let .invalidAPIKey(provider):
            return "Check your \(provider) API key in Settings → Models"
        case .missingConfiguration:
            return "Check Settings to complete configuration"
        case .authenticationFailed:
            return "Try signing in again"
        case .invalidEndpoint:
            return "Check the endpoint URL in Settings → Models"
        case .noModelSelected:
            return "Select a model in Settings → Models"
        case .modelNotFound:
            return "The model may have been removed. Select a different model."
        case .unsupportedProvider:
            return "Switch to a compatible model"
        case .capabilityMismatch:
            return "Select a model with the right capabilities"
        case .invalidResponse:
            return "Try again. If the issue persists, the API may be having problems."
        case .contentFiltered:
            return "Try rephrasing your message"
        case .apiError:
            return "Check your configuration or try again later"
        case .toolNotFound:
            return "Check that the required tool is configured in Settings → Tools"
        case .toolExecutionFailed:
            return "The tool encountered an error. Try again or use a different approach."
        case .toolChainDepthExceeded:
            return "Simplify your request to reduce tool usage"
        case .encodingFailed, .decodingFailed:
            return "The data may be corrupted. Try again with fresh data."
        case .fileOperationFailed:
            return "Check file permissions and disk space"
        case .keychainError:
            return "Check that the app has keychain access"
        case .conversationNotFound:
            return "The conversation may have been deleted"
        case .messageNotFound:
            return "The message may have been deleted"
        case .cancelled:
            return nil
        case .unknown:
            return "Try again. If the issue persists, restart the app."
        }
    }

    var failureReason: String? {
        errorDescription
    }
}

extension AynaError {
    static func wrap(_ error: Error) -> AynaError {
        if let aynaError = error as? AynaError {
            return aynaError
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .networkConnectionLost:
                return .networkError(underlying: urlError)
            case .cancelled:
                return .cancelled
            default:
                return .networkError(underlying: urlError)
            }
        }

        if error is CancellationError {
            return .cancelled
        }

        return .unknown(message: error.localizedDescription, underlying: error)
    }

    static func fromHTTPResponse(statusCode: Int, data: Data?) -> AynaError {
        var message: String?

        if let data {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? [String: Any],
                   let errorMessage = error["message"] as? String
                {
                    message = errorMessage
                } else if let errorMessage = json["message"] as? String {
                    message = errorMessage
                }
            } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                message = String(text.prefix(200))
            }
        }

        switch statusCode {
        case 401:
            return .invalidAPIKey(provider: "API")
        case 403:
            return .authenticationFailed(reason: message ?? "Access denied")
        case 404:
            return .modelNotFound(modelName: message ?? "unknown")
        case 429:
            return .rateLimited(retryAfter: nil)
        default:
            return .httpError(statusCode: statusCode, message: message)
        }
    }
}

extension AynaError: Equatable {
    static func == (lhs: AynaError, rhs: AynaError) -> Bool {
        switch (lhs, rhs) {
        case (.timeout, .timeout),
             (.noModelSelected, .noModelSelected),
             (.cancelled, .cancelled):
            true
        case let (.missingAPIKey(lhs), .missingAPIKey(rhs)):
            lhs == rhs
        case let (.invalidAPIKey(lhs), .invalidAPIKey(rhs)):
            lhs == rhs
        case let (.invalidEndpoint(lhs), .invalidEndpoint(rhs)):
            lhs == rhs
        case let (.modelNotFound(lhs), .modelNotFound(rhs)):
            lhs == rhs
        case let (.toolNotFound(lhs), .toolNotFound(rhs)):
            lhs == rhs
        case let (.contentFiltered(lhs), .contentFiltered(rhs)):
            lhs == rhs
        case let (.apiError(lhs), .apiError(rhs)):
            lhs == rhs
        case let (.httpError(lCode, lMsg), .httpError(rCode, rMsg)):
            lCode == rCode && lMsg == rMsg
        case let (.rateLimited(lhs), .rateLimited(rhs)):
            lhs == rhs
        default:
            lhs.errorDescription == rhs.errorDescription
        }
    }
}

struct AnyCodable: Codable, Equatable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let uint = try? container.decode(UInt64.self) {
            value = NSNumber(value: uint)
        } else if let decimal = try? container.decode(Decimal.self) {
            if let double = try? container.decode(Double.self),
               Decimal(
                   string: String(double),
                   locale: Locale(identifier: "en_US_POSIX")
               ) == decimal
            {
                value = double
            } else {
                value = NSDecimalNumber(decimal: decimal)
            }
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        if Mirror(reflecting: value).displayStyle == .class,
           let number = value as? NSNumber
        {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                try container.encode(number.boolValue)
            } else if let decimalNumber = number as? NSDecimalNumber {
                let decimal = decimalNumber.decimalValue
                if decimal.isNaN {
                    try container.encodeNil()
                } else {
                    try container.encode(decimal)
                }
            } else if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                if double.isFinite {
                    try container.encode(double)
                } else {
                    try container.encodeNil()
                }
            } else if let int = Int64(number.stringValue) {
                try container.encode(int)
            } else if let uint = UInt64(number.stringValue) {
                try container.encode(uint)
            } else {
                try container.encodeNil()
            }
            return
        }

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        let lhsBoolean = jsonBooleanValue(lhs.value)
        let rhsBoolean = jsonBooleanValue(rhs.value)
        if lhsBoolean != nil || rhsBoolean != nil {
            return lhsBoolean == rhsBoolean
        }

        let lhsNumber = jsonNumberValue(lhs.value)
        let rhsNumber = jsonNumberValue(rhs.value)
        if lhsNumber != nil || rhsNumber != nil {
            return lhsNumber == rhsNumber
        }

        return switch (lhs.value, rhs.value) {
        case let (lhs as Bool, rhs as Bool):
            lhs == rhs
        case let (lhs as Int, rhs as Int):
            lhs == rhs
        case let (lhs as Double, rhs as Double):
            lhs == rhs
        case let (lhs as String, rhs as String):
            lhs == rhs
        case let (lhs as [AnyCodable], rhs as [AnyCodable]):
            lhs == rhs
        case let (lhs as [String: AnyCodable], rhs as [String: AnyCodable]):
            lhs == rhs
        case let (lhs as [Any], rhs as [Any]):
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
                AnyCodable($0) == AnyCodable($1)
            }
        case let (lhs as [String: Any], rhs as [String: Any]):
            lhs.count == rhs.count && lhs.allSatisfy { key, value in
                guard let rhsValue = rhs[key] else { return false }
                return AnyCodable(value) == AnyCodable(rhsValue)
            }
        case (is NSNull, is NSNull):
            true
        default:
            false
        }
    }

    private static func jsonBooleanValue(_ value: Any) -> Bool? {
        if Mirror(reflecting: value).displayStyle == .class,
           let number = value as? NSNumber
        {
            guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        return value as? Bool
    }

    private static func jsonNumberValue(_ value: Any) -> Decimal? {
        if Mirror(reflecting: value).displayStyle == .class,
           let number = value as? NSNumber
        {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let decimal = number.decimalValue
            return decimal.isNaN ? nil : decimal
        }

        return switch value {
        case let int as Int:
            Decimal(int)
        case let double as Double where double.isFinite:
            Decimal(
                string: String(double),
                locale: Locale(identifier: "en_US_POSIX")
            )
        default:
            nil
        }
    }
}
