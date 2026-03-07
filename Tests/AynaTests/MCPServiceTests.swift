#if os(macOS)
    @testable import Ayna
    import Foundation
    import Testing

    @Suite("MCPService Tests", .tags(.async, .errorHandling), .serialized)
    struct MCPServiceTests {
        @Test("Initialize request times out and clears pending continuation", .timeLimit(.minutes(1)))
        func initializeRequestTimesOut() async throws {
            let harness = try MockMCPServerHarness(mode: .initializeTimeout)
            defer { harness.cleanup() }

            let service = harness.makeService(requestTimeoutSeconds: 1.0)
            defer { service.disconnect() }

            do {
                try await service.connect()
                Issue.record("Expected connect() to time out during initialize")
            } catch let error as MCPServiceError {
                switch error {
                case let .initializationFailed(message):
                    #expect(message.contains("Operation timed out"))
                default:
                    Issue.record("Unexpected MCPServiceError: \(error.localizedDescription)")
                }
            } catch {
                Issue.record("Unexpected error type: \(error.localizedDescription)")
            }

            #expect(service.pendingRequestCount == 0)
        }

        @Test("List tools request times out and clears pending continuation", .timeLimit(.minutes(1)))
        func listToolsRequestTimesOut() async throws {
            let harness = try MockMCPServerHarness(mode: .listTimeout)
            defer { harness.cleanup() }

            let service = harness.makeService(requestTimeoutSeconds: 1.0)
            try await service.connect()
            defer { service.disconnect() }

            do {
                _ = try await service.listTools()
                Issue.record("Expected listTools() to time out")
            } catch let error as MCPServiceError {
                guard case .timeout = error else {
                    Issue.record("Unexpected MCPServiceError: \(error.localizedDescription)")
                    return
                }
            } catch {
                Issue.record("Unexpected error type: \(error.localizedDescription)")
            }

            #expect(service.pendingRequestCount == 0)
        }

        @Test("Tool call request times out and clears pending continuation", .timeLimit(.minutes(1)))
        func callToolRequestTimesOut() async throws {
            let harness = try MockMCPServerHarness(mode: .callTimeout)
            defer { harness.cleanup() }

            let service = harness.makeService(requestTimeoutSeconds: 1.0)
            try await service.connect()
            defer { service.disconnect() }

            do {
                _ = try await service.callTool(name: "echo", arguments: [:])
                Issue.record("Expected callTool() to time out")
            } catch let error as MCPServiceError {
                guard case .timeout = error else {
                    Issue.record("Unexpected MCPServiceError: \(error.localizedDescription)")
                    return
                }
            } catch {
                Issue.record("Unexpected error type: \(error.localizedDescription)")
            }

            #expect(service.pendingRequestCount == 0)
        }
    }

    private struct MockMCPServerHarness {
        enum Mode: String {
            case initializeTimeout = "initialize-timeout"
            case listTimeout = "list-timeout"
            case callTimeout = "call-timeout"
        }

        let directory: URL
        let scriptURL: URL
        let mode: Mode

        init(mode: Mode) throws {
            self.mode = mode
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("MCPServiceTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

            scriptURL = directory.appendingPathComponent("mock-mcp-server.sh")
            try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        }

        func makeService(requestTimeoutSeconds: TimeInterval) -> MCPService {
            let config = MCPServerConfig(
                name: "mock-\(UUID().uuidString)",
                command: scriptURL.path,
                env: ["MCP_TEST_MODE": mode.rawValue]
            )

            return MCPService(serverConfig: config, requestTimeoutSeconds: requestTimeoutSeconds)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        private var scriptContents: String {
            """
            #!/bin/sh
            mode="${MCP_TEST_MODE:-ok}"

            while IFS= read -r line; do
              case "$line" in
                *'"method":"initialize"'*)
                  if [ "$mode" = "initialize-timeout" ]; then
                    sleep 60
                  else
                    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{}}}'
                  fi
                  ;;
                *'"method":"notifications/initialized"'*)
                  ;;
                *'"method":"tools/list"'*)
                  if [ "$mode" = "list-timeout" ]; then
                    sleep 60
                  else
                    printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}'
                  fi
                  ;;
                *'"method":"tools/call"'*)
                  if [ "$mode" = "call-timeout" ]; then
                    sleep 60
                  else
                    printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":"ok"}}'
                  fi
                  ;;
              esac
            done
            """
        }
    }
#endif
