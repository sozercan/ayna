//
//  BuiltinToolService+WebFetch.swift
//  Ayna
//
//  Web fetch functionality for builtin tool service.
//

import Foundation
import os.log

#if os(macOS)
    extension BuiltinToolService {
        // MARK: - Web Fetch

        /// Fetches content from a URL and returns it as text.
        ///
        /// - Parameters:
        ///   - url: The URL to fetch
        ///   - conversationId: The conversation requesting this operation
        /// - Returns: The page content as plain text
        func webFetch(url: String, conversationId _: UUID) async throws -> String {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "web_fetch requested", metadata: ["url": url])

            do {
                let result = try await WebFetchRequestExecutor.fetchText(
                    from: url,
                    timeoutSeconds: TimeInterval(commandTimeoutSeconds),
                    maxResponseSize: maxReadSize
                )

                log(.info, "web_fetch completed", metadata: ["url": url, "size": "\(result.count)"])
                return result
            } catch let error as WebFetchError {
                switch error {
                case .serviceDisabled:
                    throw ToolExecutionError.serviceDisabled
                case .invalidURL:
                    throw ToolExecutionError.invalidPath(path: url, reason: "Invalid URL format")
                case .ssrfBlocked:
                    throw ToolExecutionError.invalidPath(path: url, reason: "Access to internal addresses is not allowed")
                case let .httpError(statusCode):
                    throw ToolExecutionError.commandFailed(
                        command: "web_fetch",
                        exitCode: Int32(statusCode),
                        stderr: "HTTP \(statusCode)"
                    )
                case .responseToLarge:
                    throw ToolExecutionError.resourceLimitExceeded(
                        resource: "response size",
                        limit: "\(maxReadSize / 1024 / 1024) MB"
                    )
                case .binaryContent:
                    throw ToolExecutionError.binaryFileUnsupported(path: url)
                case let .networkError(underlying):
                    throw ToolExecutionError.commandFailed(command: "web_fetch", exitCode: -1, stderr: underlying)
                }
            }
        }
    }
#endif
