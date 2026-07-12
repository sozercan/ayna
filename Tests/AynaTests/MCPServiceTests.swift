#if os(macOS)
    @testable import Ayna
    import Darwin
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
            #expect(harness.recordedMessages(method: "notifications/cancelled").isEmpty)
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

        @Test("Cancelling a written tool call emits an MCP cancellation notification", .timeLimit(.minutes(1)))
        func cancellingWrittenToolCallEmitsCancellationNotification() async throws {
            let harness = try MockMCPServerHarness(mode: .callTimeout)
            defer { harness.cleanup() }

            let service = harness.makeService(requestTimeoutSeconds: 30.0)
            try await service.connect()
            defer { service.disconnect() }

            let task = Task {
                try await service.callTool(name: "echo", arguments: [:])
            }

            guard let toolCall = await harness.waitForMessage(method: "tools/call"),
                  let requestId = toolCall.id
            else {
                task.cancel()
                _ = try? await task.value
                Issue.record("Expected the mock server to receive the tool call")
                return
            }

            task.cancel()
            await expectCancellation(from: task)
            #expect(service.pendingRequestCount == 0)

            guard let notification = await harness.waitForMessage(method: "notifications/cancelled") else {
                Issue.record("Expected the mock server to receive a cancellation notification")
                return
            }

            #expect(notification.jsonrpc == "2.0")
            #expect(notification.id == nil)
            #expect(notification.requestId == requestId)
            #expect(notification.reason == "Client cancelled request")
            #expect(harness.recordedMessages(method: "notifications/cancelled").count == 1)
        }

        @Test("Cancellation before request write sends no tool call", .timeLimit(.minutes(1)))
        func cancellationBeforeRequestWriteSendsNoToolCall() async throws {
            let harness = try MockMCPServerHarness(mode: .callTimeout)
            defer { harness.cleanup() }

            let writeGate = MCPRequestWriteGate(targetMethod: "tools/call")
            let service = harness.makeService(
                requestTimeoutSeconds: 30.0,
                requestWriteHook: { _, method in writeGate.pauseIfTarget(method) }
            )
            try await service.connect()
            defer { service.disconnect() }
            defer { writeGate.release() }

            let task = Task {
                try await service.callTool(name: "echo", arguments: [:])
            }

            let reachedWrite = await writeGate.entered.wait(timeout: .seconds(2))
            #expect(reachedWrite)
            #expect(service.pendingRequestCount == 1)

            task.cancel()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while service.pendingRequestCount != 0, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(service.pendingRequestCount == 0)

            writeGate.release()
            await expectCancellation(from: task)

            // A following request is a deterministic transport barrier: once it receives a
            // response, the mock server has observed every message the cancelled task could send.
            #expect(try await service.listTools().isEmpty)
            #expect(harness.recordedMessages(method: "tools/call").isEmpty)
            #expect(harness.recordedMessages(method: "notifications/cancelled").isEmpty)
            #expect(service.pendingRequestCount == 0)
        }

        @Test("Blocked request write does not block MainActor or cancellation", .timeLimit(.minutes(1)))
        func blockedRequestWriteDoesNotBlockMainActorOrCancellation() async throws {
            let harness = try MockMCPServerHarness(mode: .callTimeout)
            defer { harness.cleanup() }

            let writeGate = MCPMessageWriteGate(targetMethod: "tools/call")
            let service = harness.makeService(
                requestTimeoutSeconds: 30.0,
                messageWriteHandler: { handle, data in
                    writeGate.pauseIfTarget(data)
                    try handle.write(contentsOf: data)
                }
            )
            try await service.connect()
            defer { service.disconnect() }
            defer { writeGate.release() }

            let completed = FlightTestSignal()
            let task = Task {
                defer { completed.signal() }
                return try await service.callTool(name: "echo", arguments: [:])
            }

            let mainActorRan = FlightTestSignal()
            let cancellationReturned = FlightTestSignal()
            let startedAt = ContinuousClock.now

            Task { @MainActor in
                await writeGate.entered.wait()
                mainActorRan.signal()
            }
            Task.detached {
                await writeGate.entered.wait()
                task.cancel()
                cancellationReturned.signal()
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                writeGate.release()
            }

            #expect(await writeGate.entered.wait(timeout: .seconds(2)))
            #expect(await mainActorRan.wait(timeout: .milliseconds(250)))
            #expect(await cancellationReturned.wait(timeout: .milliseconds(250)))
            #expect(await completed.wait(timeout: .milliseconds(250)))
            #expect(startedAt.duration(to: .now) < .milliseconds(750))
            #expect(service.pendingRequestCount == 0)

            writeGate.release()
            await expectCancellation(from: task)
        }

        @Test("Blocked written request timeout disconnects and recovers the transport", .timeLimit(.minutes(1)))
        @MainActor
        func blockedWrittenRequestTimeoutDisconnectsAndRecoversTransport() async throws {
            let harness = try MockMCPServerHarness(mode: .callTimeout)
            defer { harness.cleanup() }

            let writeGate = MCPMessageWriteGate(targetMethod: "tools/call")
            let outcome = FlightTestBox<String?>(nil)
            let completed = FlightTestSignal()
            let service = harness.makeService(
                requestTimeoutSeconds: 0.1,
                messageWriteHandler: { handle, data in
                    writeGate.pauseIfTarget(data)
                    try handle.write(contentsOf: data)
                }
            )
            let delegate = MCPServiceDelegateRecorder()
            service.delegate = delegate
            try await service.connect()
            defer { service.disconnect() }
            defer { writeGate.release() }

            let startedAt = ContinuousClock.now
            let task = Task {
                defer { completed.signal() }
                do {
                    _ = try await service.callTool(name: "echo", arguments: [:])
                    outcome.value = "success"
                } catch MCPServiceError.timeout {
                    outcome.value = "timeout"
                } catch {
                    outcome.value = error.localizedDescription
                }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                writeGate.release()
            }

            #expect(await writeGate.entered.wait(timeout: .seconds(2)))
            #expect(await completed.wait(timeout: .milliseconds(500)))
            #expect(startedAt.duration(to: .now) < .milliseconds(750))
            #expect(outcome.value == "timeout")
            #expect(service.pendingRequestCount == 0)

            let disconnectDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while service.isConnected, ContinuousClock.now < disconnectDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(!service.isConnected)
            let delegateDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while delegate.terminationCount == 0, ContinuousClock.now < delegateDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(delegate.terminationCount == 1)

            writeGate.release()
            await task.value
            #expect(harness.recordedMessages(method: "tools/call").isEmpty)
            #expect(harness.recordedMessages(method: "notifications/cancelled").isEmpty)

            try await service.connect()
            #expect(service.isConnected)
            _ = try await service.listTools()
        }

        @Test("Late response after cancellation is ignored without disrupting other requests", .timeLimit(.minutes(1)))
        func lateResponseAfterCancellationIsIgnoredSafely() async throws {
            let harness = try MockMCPServerHarness(mode: .lateResponseAfterCancellation)
            defer { harness.cleanup() }

            let service = harness.makeService(requestTimeoutSeconds: 30.0)
            try await service.connect()
            defer { service.disconnect() }

            let task = Task {
                try await service.callTool(name: "echo", arguments: [:])
            }

            guard await harness.waitForMessage(method: "tools/call") != nil else {
                task.cancel()
                _ = try? await task.value
                Issue.record("Expected the mock server to receive the tool call")
                return
            }

            task.cancel()
            await expectCancellation(from: task)
            #expect(service.pendingRequestCount == 0)

            #expect(await harness.waitForEvent("late-response-sent"))
            #expect(try await service.listTools().isEmpty)
            #expect(service.pendingRequestCount == 0)
            #expect(harness.recordedMessages(method: "notifications/cancelled").count == 1)
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

            guard let toolCall = await harness.waitForMessage(method: "tools/call"),
                  let requestId = toolCall.id,
                  let notification = await harness.waitForMessage(method: "notifications/cancelled")
            else {
                Issue.record("Expected timeout cancellation notification")
                return
            }
            #expect(notification.requestId == requestId)
            #expect(notification.reason == "Client request timed out")
            #expect(harness.recordedMessages(method: "notifications/cancelled").count == 1)
        }

        @Test("Old TERM-resistant process exit cannot disconnect replacement", .timeLimit(.minutes(1)))
        @MainActor
        func oldTermResistantProcessExitCannotDisconnectReplacement() async throws {
            let harness = try MockMCPServerHarness(mode: .termResistant)
            defer { harness.cleanup() }

            let tracker = MCPProcessTrackingRecorder()
            let delegate = MCPServiceDelegateRecorder()
            let service = harness.makeService(
                requestTimeoutSeconds: 2.0,
                terminationGracePeriod: 0.4,
                processRegistrationHandler: { key, pid in tracker.register(key: key, pid: pid) },
                processUnregistrationHandler: { key in tracker.unregister(key: key) }
            )
            service.delegate = delegate
            defer { service.disconnect() }

            try await service.connect()
            #expect(await tracker.waitForRegistrationCount(1))
            #expect(await harness.waitForEvent("term-resistant-ready"))

            service.disconnect()
            try await service.connect()
            #expect(await tracker.waitForRegistrationCount(2))
            #expect(service.isConnected)

            #expect(await tracker.waitForUnregistrationCount(1, timeout: .seconds(2)))
            #expect(tracker.unregistrations.first?.wasRunning == false)
            #expect(service.isConnected)
            #expect(delegate.terminationCount == 0)

            service.disconnect()
            #expect(await tracker.waitForUnregistrationCount(2, timeout: .seconds(2)))
            #expect(tracker.unregistrations.allSatisfy { !$0.wasRunning })
        }

        private func expectCancellation(from task: Task<String, Error>) async {
            do {
                _ = try await task.value
                Issue.record("Expected callTool() to throw cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Unexpected error type: \(error.localizedDescription)")
            }
        }
    }

    private struct MockMCPServerHarness {
        enum Mode: String {
            case initializeTimeout = "initialize-timeout"
            case listTimeout = "list-timeout"
            case callTimeout = "call-timeout"
            case lateResponseAfterCancellation = "late-response-after-cancellation"
            case termResistant = "term-resistant"
        }

        let directory: URL
        let scriptURL: URL
        let logURL: URL
        let mode: Mode

        init(mode: Mode) throws {
            self.mode = mode
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("MCPServiceTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

            scriptURL = directory.appendingPathComponent("mock-mcp-server.sh")
            logURL = directory.appendingPathComponent("messages.log")
            try Data().write(to: logURL)
            try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        }

        func makeService(
            requestTimeoutSeconds: TimeInterval,
            requestWriteHook: (@Sendable (Int, String) -> Void)? = nil,
            messageWriteHandler: @escaping @Sendable (FileHandle, Data) throws -> Void = { handle, data in
                try handle.write(contentsOf: data)
            },
            terminationGracePeriod: TimeInterval = 0.5,
            processRegistrationHandler: @escaping @Sendable (String, pid_t) -> Void = { key, pid in
                MCPProcessTracker.shared.register(serverName: key, pid: pid)
            },
            processUnregistrationHandler: @escaping @Sendable (String) -> Void = { key in
                MCPProcessTracker.shared.unregister(serverName: key)
            }
        ) -> MCPService {
            let config = MCPServerConfig(
                name: "mock-\(UUID().uuidString)",
                command: scriptURL.path,
                env: [
                    "MCP_TEST_LOG": logURL.path,
                    "MCP_TEST_MODE": mode.rawValue
                ]
            )

            return MCPService(
                serverConfig: config,
                requestTimeoutSeconds: requestTimeoutSeconds,
                requestWriteHook: requestWriteHook,
                messageWriteHandler: messageWriteHandler,
                terminationGracePeriod: terminationGracePeriod,
                processRegistrationHandler: processRegistrationHandler,
                processUnregistrationHandler: processUnregistrationHandler
            )
        }

        func waitForMessage(method: String, timeout: Duration = .seconds(2)) async -> RecordedMCPMessage? {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if let message = recordedMessages(method: method).first {
                    return message
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return recordedMessages(method: method).first
        }

        func waitForEvent(_ event: String, timeout: Duration = .seconds(2)) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if recordedContents.contains("SERVER_EVENT \(event)") {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return recordedContents.contains("SERVER_EVENT \(event)")
        }

        func recordedMessages(method: String) -> [RecordedMCPMessage] {
            recordedContents
                .split(separator: "\n")
                .compactMap(RecordedMCPMessage.init)
                .filter { $0.method == method }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        private var scriptContents: String {
            """
            #!/bin/sh
            mode="${MCP_TEST_MODE:-ok}"
            log_file="${MCP_TEST_LOG:?}"

            request_id() {
              printf '%s\n' "$1" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p'
            }

            cancelled_request_id() {
              printf '%s\n' "$1" | sed -n 's/.*"requestId":\\([0-9][0-9]*\\).*/\\1/p'
            }

            while IFS= read -r line; do
              printf '%s\n' "$line" >> "$log_file"
              case "$line" in
                *'"method":"initialize"'*)
                  if [ "$mode" = "initialize-timeout" ]; then
                    :
                  else
                    id=$(request_id "$line")
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{}}}\n' "$id"
                  fi
                  ;;
                *notifications*initialized*)
                  if [ "$mode" = "term-resistant" ]; then
                    trap '' TERM
                    printf 'SERVER_EVENT term-resistant-ready\n' >> "$log_file"
                    while :; do :; done
                  fi
                  ;;
                *notifications*cancelled*)
                  if [ "$mode" = "late-response-after-cancellation" ]; then
                    id=$(cancelled_request_id "$line")
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":"late"}}\n' "$id"
                    printf 'SERVER_EVENT late-response-sent\n' >> "$log_file"
                  fi
                  ;;
                *tools*list*)
                  if [ "$mode" = "list-timeout" ]; then
                    :
                  else
                    id=$(request_id "$line")
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[]}}\n' "$id"
                  fi
                  ;;
                *tools*call*)
                  if [ "$mode" = "call-timeout" ] || [ "$mode" = "late-response-after-cancellation" ]; then
                    :
                  else
                    id=$(request_id "$line")
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":"ok"}}\n' "$id"
                  fi
                  ;;
              esac
            done
            """
        }

        private var recordedContents: String {
            (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        }
    }

    private final class MCPMessageWriteGate: @unchecked Sendable {
        let entered = FlightTestSignal()

        private let targetMethod: String
        private let condition = NSCondition()
        private var isReleased = false

        init(targetMethod: String) {
            self.targetMethod = targetMethod
        }

        func pauseIfTarget(_ data: Data) {
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  message["method"] as? String == targetMethod
            else {
                return
            }

            entered.signal()
            condition.lock()
            while !isReleased {
                condition.wait()
            }
            condition.unlock()
        }

        func release() {
            condition.lock()
            isReleased = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private final class MCPRequestWriteGate: @unchecked Sendable {
        let entered = FlightTestSignal()

        private let targetMethod: String
        private let condition = NSCondition()
        private var isReleased = false

        init(targetMethod: String) {
            self.targetMethod = targetMethod
        }

        func pauseIfTarget(_ method: String) {
            guard method == targetMethod else { return }

            entered.signal()
            condition.lock()
            while !isReleased {
                condition.wait()
            }
            condition.unlock()
        }

        func release() {
            condition.lock()
            isReleased = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private final class MCPProcessTrackingRecorder: @unchecked Sendable {
        struct Unregistration: Sendable {
            let key: String
            let pid: pid_t
            let wasRunning: Bool
        }

        private let lock = NSLock()
        private var registeredPIDs: [String: pid_t] = [:]
        private var registrationOrder: [String] = []
        private var recordedUnregistrations: [Unregistration] = []

        var unregistrations: [Unregistration] {
            lock.lock()
            defer { lock.unlock() }
            return recordedUnregistrations
        }

        func register(key: String, pid: pid_t) {
            lock.lock()
            registeredPIDs[key] = pid
            registrationOrder.append(key)
            lock.unlock()
        }

        func unregister(key: String) {
            lock.lock()
            let pid = registeredPIDs.removeValue(forKey: key) ?? -1
            lock.unlock()

            let wasRunning = pid > 0 && Darwin.kill(pid, 0) == 0
            lock.lock()
            recordedUnregistrations.append(Unregistration(key: key, pid: pid, wasRunning: wasRunning))
            lock.unlock()
        }

        func waitForRegistrationCount(_ count: Int, timeout: Duration = .seconds(2)) async -> Bool {
            await waitForCount(count, timeout: timeout) { self.registrationCount }
        }

        func waitForUnregistrationCount(_ count: Int, timeout: Duration = .seconds(2)) async -> Bool {
            await waitForCount(count, timeout: timeout) { self.unregistrationCount }
        }

        private var registrationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return registrationOrder.count
        }

        private var unregistrationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return recordedUnregistrations.count
        }

        private func waitForCount(
            _ count: Int,
            timeout: Duration,
            currentCount: @escaping @Sendable () -> Int
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while currentCount() < count, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return currentCount() >= count
        }
    }

    @MainActor
    private final class MCPServiceDelegateRecorder: MCPServiceDelegate {
        private(set) var terminationCount = 0

        func mcpService(_: MCPServicing, didTerminateWithError _: String?) {
            terminationCount += 1
        }
    }

    private struct RecordedMCPMessage: Sendable {
        let jsonrpc: String?
        let id: Int?
        let method: String?
        let requestId: Int?
        let reason: String?

        init?(line: Substring) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let message = object as? [String: Any]
            else {
                return nil
            }

            let params = message["params"] as? [String: Any]
            jsonrpc = message["jsonrpc"] as? String
            id = jsonInteger(message["id"])
            method = message["method"] as? String
            requestId = jsonInteger(params?["requestId"])
            reason = params?["reason"] as? String
        }
    }

    private func jsonInteger(_ value: Any?) -> Int? {
        if let integer = value as? Int {
            return integer
        }
        return (value as? NSNumber)?.intValue
    }
#endif
