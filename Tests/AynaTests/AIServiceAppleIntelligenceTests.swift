@testable import Ayna
import Foundation
import Testing

#if !os(watchOS)
    extension AIServiceTests {
        @Test("Apple foreground replacement suppresses stale callbacks", .timeLimit(.minutes(1)))
        func appleForegroundReplacementSuppressesStaleCallbacks() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let models = ["apple-first", "apple-second"]
            configureAppleModels(models, on: service)
            let firstChunks = FlightTestBox<[String]>([])
            let firstCompletions = FlightTestBox(0)
            let secondChunks = FlightTestBox<[String]>([])
            let secondCompleted = FlightTestSignal()

            service.sendMessage(
                messages: [Message(role: .user, content: "First")],
                model: models[0],
                onChunk: { chunk in firstChunks.update { $0.append(chunk) } },
                onComplete: { firstCompletions.update { $0 += 1 } },
                onError: { _ in }
            )
            let first = try #require(await appleService.request(at: 0))

            service.sendMessage(
                messages: [Message(role: .user, content: "Second")],
                model: models[1],
                onChunk: { chunk in secondChunks.update { $0.append(chunk) } },
                onComplete: { secondCompleted.signal() },
                onError: { error in Issue.record("Unexpected error: \(error)") }
            )
            let second = try #require(await appleService.request(at: 1))
            #expect(await first.cancelled.wait(timeout: .seconds(1)))

            first.emitChunk("stale")
            first.complete()
            second.emitChunk("fresh")
            second.complete()

            #expect(await secondCompleted.wait(timeout: .seconds(1)))
            #expect(firstChunks.value.isEmpty)
            #expect(firstCompletions.value == 0)
            #expect(secondChunks.value == ["fresh"])
        }

        @Test("Stale Apple cleanup preserves the replacement cancellation handle", .timeLimit(.minutes(1)))
        func staleAppleCleanupPreservesReplacementCancellationHandle() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let models = ["apple-first", "apple-second"]
            configureAppleModels(models, on: service)
            let replacementChunks = FlightTestBox<[String]>([])
            let replacementCompletions = FlightTestBox(0)

            service.sendMessage(
                messages: [Message(role: .user, content: "First")],
                model: models[0],
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let first = try #require(await appleService.request(at: 0))

            service.sendMessage(
                messages: [Message(role: .user, content: "Second")],
                model: models[1],
                onChunk: { chunk in replacementChunks.update { $0.append(chunk) } },
                onComplete: { replacementCompletions.update { $0 += 1 } },
                onError: { _ in }
            )
            let second = try #require(await appleService.request(at: 1))
            #expect(await first.cancelled.wait(timeout: .seconds(1)))

            await Task.yield()
            service.cancelCurrentRequest(includeImageRequests: false)
            #expect(await second.cancelled.wait(timeout: .seconds(1)))
            second.emitChunk("late")
            second.complete()
            #expect(appleService.clearedSessionIDs.filter { $0.hasPrefix("default:") }.count == 2)
            #expect(replacementChunks.value.isEmpty)
            #expect(replacementCompletions.value == 0)
        }

        @Test("Apple non-stream chunk reentrancy cannot complete a replaced request", .timeLimit(.minutes(1)))
        func appleNonStreamChunkReentrancyCannotCompleteReplacedRequest() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let models = ["apple-first", "apple-second"]
            configureAppleModels(models, on: service)
            let firstCompletions = FlightTestBox(0)
            let secondCompletions = FlightTestSignal()

            service.sendMessage(
                messages: [Message(role: .user, content: "First")],
                model: models[0],
                stream: false,
                onChunk: { _ in
                    MainActor.assumeIsolated {
                        service.sendMessage(
                            messages: [Message(role: .user, content: "Second")],
                            model: models[1],
                            stream: false,
                            onChunk: { _ in },
                            onComplete: { secondCompletions.signal() },
                            onError: { error in Issue.record("Unexpected error: \(error)") }
                        )
                    }
                },
                onComplete: { firstCompletions.update { $0 += 1 } },
                onError: { error in Issue.record("Unexpected error: \(error)") }
            )
            let first = try #require(await appleService.request(at: 0))
            first.complete(response: "first response")

            let second = try #require(await appleService.request(at: 1))
            #expect(await first.cancelled.wait(timeout: .seconds(1)))
            second.complete(response: "second response")

            #expect(await secondCompletions.wait(timeout: .seconds(1)))
            #expect(firstCompletions.value == 0)
        }

        @Test("Apple foreground and per-model flights remain independent", .timeLimit(.minutes(1)))
        func appleForegroundAndPerModelFlightsRemainIndependent() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let foregroundModel = "apple-foreground"
            let batchModel = "apple-batch"
            configureAppleModels([foregroundModel, batchModel], on: service)
            let batchComplete = FlightTestSignal()

            service.sendMessage(
                messages: [Message(role: .user, content: "Foreground")],
                model: foregroundModel,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let foreground = try #require(await appleService.request(sessionIDPrefix: "default:"))

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "Batch")],
                models: [batchModel],
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: { batchComplete.signal() },
                onError: { _, error in Issue.record("Unexpected error: \(error)") }
            )
            let batch = try #require(await appleService.request(sessionIDPrefix: "multi:default:\(batchModel):"))
            batch.complete()

            #expect(await batchComplete.wait(timeout: .seconds(2)))
            #expect(!foreground.cancelled.isSignaled)

            service.cancelCurrentRequest(includeImageRequests: false)
            #expect(await foreground.cancelled.wait(timeout: .seconds(1)))
        }

        @Test("Apple foreground requests rebuild the full conversation transcript", .timeLimit(.minutes(1)))
        func appleForegroundRequestsRebuildFullConversationTranscript() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-context"
            configureAppleModels([model], on: service)
            let toolCall = MCPToolCall(
                id: "call-1",
                toolName: "lookup",
                arguments: ["query": AnyCodable("weather")]
            )
            var assistantToolCall = Message(role: .assistant, content: "")
            assistantToolCall.toolCalls = [toolCall]
            var toolOutput = Message(role: .tool, content: "Sunny")
            toolOutput.toolCalls = [toolCall]
            let messages = [
                Message(role: .user, content: "    Earlier question\n"),
                Message(role: .assistant, content: "Earlier answer"),
                assistantToolCall,
                toolOutput,
                Message(role: .user, content: "Latest question"),
            ]
            let expectedHistory = [
                AppleIntelligenceHistoryEntry(role: .user, content: "    Earlier question\n"),
                AppleIntelligenceHistoryEntry(role: .assistant, content: "Earlier answer"),
                AppleIntelligenceHistoryEntry(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        AppleIntelligenceToolCall(
                            id: "call-1",
                            name: "lookup",
                            argumentsJSON: #"{"query":"weather"}"#
                        ),
                    ]
                ),
                AppleIntelligenceHistoryEntry(
                    role: .tool,
                    content: "Sunny",
                    toolName: "lookup",
                    toolCallID: "call-1"
                ),
            ]

            service.sendMessage(
                messages: messages,
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let first = try #require(await appleService.request(at: 0))
            #expect(first.prompt == "Latest question")
            #expect(first.history == expectedHistory)
            service.cancelCurrentRequest(includeImageRequests: false)
            #expect(await first.cancelled.wait(timeout: .seconds(1)))

            service.sendMessage(
                messages: messages,
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let second = try #require(await appleService.request(at: 1))
            #expect(second.prompt == "Latest question")
            #expect(second.history == expectedHistory)
            #expect(second.conversationID != first.conversationID)
            second.complete()
        }

        @Test("Apple tool continuation preserves matched calls and drops orphaned calls", .timeLimit(.minutes(1)))
        func appleToolContinuationPreservesMatchedCallsAndDropsOrphans() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-tool-context"
            configureAppleModels([model], on: service)

            let matchedCall = MCPToolCall(
                id: "matched",
                toolName: "lookup",
                arguments: ["query": AnyCodable("weather")]
            )
            let orphanedCall = MCPToolCall(
                id: "orphaned",
                toolName: "unused",
                arguments: [:]
            )
            let emptyOutputCall = MCPToolCall(
                id: "empty-output",
                toolName: "noop",
                arguments: [:]
            )
            var assistantCall = Message(role: .assistant, content: "")
            assistantCall.toolCalls = [matchedCall]
            var toolOutput = Message(role: .tool, content: "Sunny")
            toolOutput.toolCalls = [matchedCall]
            var orphanedAssistantCall = Message(role: .assistant, content: "")
            orphanedAssistantCall.toolCalls = [orphanedCall]
            var emptyOutputAssistantCall = Message(role: .assistant, content: "")
            emptyOutputAssistantCall.toolCalls = [emptyOutputCall]
            var emptyToolOutput = Message(role: .tool, content: "")
            emptyToolOutput.toolCalls = [emptyOutputCall]

            service.sendMessage(
                messages: [
                    Message(role: .user, content: "What is the weather?"),
                    assistantCall,
                    toolOutput,
                    emptyOutputAssistantCall,
                    emptyToolOutput,
                    orphanedAssistantCall,
                ],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let request = try #require(await appleService.request(at: 0))

            #expect(request.prompt == "Continue the conversation using the completed context above.")
            #expect(request.history == [
                AppleIntelligenceHistoryEntry(role: .user, content: "What is the weather?"),
                AppleIntelligenceHistoryEntry(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        AppleIntelligenceToolCall(
                            id: "matched",
                            name: "lookup",
                            argumentsJSON: #"{"query":"weather"}"#
                        ),
                    ]
                ),
                AppleIntelligenceHistoryEntry(
                    role: .tool,
                    content: "Sunny",
                    toolName: "lookup",
                    toolCallID: "matched"
                ),
                AppleIntelligenceHistoryEntry(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        AppleIntelligenceToolCall(
                            id: "empty-output",
                            name: "noop",
                            argumentsJSON: "{}"
                        ),
                    ]
                ),
                AppleIntelligenceHistoryEntry(
                    role: .tool,
                    content: "(empty tool output)",
                    toolName: "noop",
                    toolCallID: "empty-output"
                ),
            ])
            request.complete()
        }

        @Test("Apple tool matching pairs reused IDs with the nearest preceding call")
        func appleToolMatchingPairsReusedIDsWithNearestPrecedingCall() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-reused-tool-id"
            configureAppleModels([model], on: service)

            let firstCall = MCPToolCall(id: "reused", toolName: "first", arguments: [:])
            let secondCall = MCPToolCall(id: "reused", toolName: "second", arguments: [:])
            var orphanedAssistant = Message(role: .assistant, content: "")
            orphanedAssistant.toolCalls = [firstCall]
            var matchedAssistant = Message(role: .assistant, content: "")
            matchedAssistant.toolCalls = [secondCall]
            var matchedOutput = Message(role: .tool, content: "second result")
            matchedOutput.toolCalls = [secondCall]

            service.sendMessage(
                messages: [
                    Message(role: .user, content: "First question"),
                    orphanedAssistant,
                    Message(role: .user, content: "Second question"),
                    matchedAssistant,
                    matchedOutput,
                    Message(role: .user, content: "Latest"),
                ],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let request = try #require(await appleService.request(at: 0))

            #expect(request.history == [
                AppleIntelligenceHistoryEntry(role: .user, content: "First question"),
                AppleIntelligenceHistoryEntry(role: .user, content: "Second question"),
                AppleIntelligenceHistoryEntry(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        AppleIntelligenceToolCall(
                            id: "reused#1",
                            name: "second",
                            argumentsJSON: "{}"
                        ),
                    ]
                ),
                AppleIntelligenceHistoryEntry(
                    role: .tool,
                    content: "second result",
                    toolName: "second",
                    toolCallID: "reused#1"
                ),
            ])
            request.complete()
        }

        @Test("Apple context budgeting keeps the newest complete history")
        func appleContextBudgetingKeepsNewestCompleteHistory() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            appleService.contextSize = 200
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-budget"
            configureAppleModels([model], on: service)
            let oldContent = String(repeating: "o", count: 100)
            let recentUser = String(repeating: "u", count: 20)
            let recentAssistant = String(repeating: "a", count: 20)

            service.sendMessage(
                messages: [
                    Message(role: .user, content: oldContent),
                    Message(role: .assistant, content: oldContent),
                    Message(role: .user, content: recentUser),
                    Message(role: .assistant, content: recentAssistant),
                    Message(role: .user, content: "Latest"),
                ],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let request = try #require(await appleService.request(at: 0))

            #expect(request.prompt == "Latest")
            #expect(request.history == [
                AppleIntelligenceHistoryEntry(role: .user, content: recentUser),
                AppleIntelligenceHistoryEntry(role: .assistant, content: recentAssistant),
            ])
            request.complete()
        }

        @Test("Apple context budgeting accounts for many small transcript entries")
        func appleContextBudgetingAccountsForManySmallTranscriptEntries() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            appleService.contextSize = 200
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-small-turns"
            configureAppleModels([model], on: service)
            var messages: [Message] = []
            for index in 0 ..< 20 {
                messages.append(Message(role: .user, content: "u\(index)"))
                messages.append(Message(role: .assistant, content: "a\(index)"))
            }
            messages.append(Message(role: .user, content: "Latest"))

            service.sendMessage(
                messages: messages,
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let request = try #require(await appleService.request(at: 0))

            #expect(request.history.count == 6)
            #expect(request.history.first?.content == "u17")
            #expect(request.history.last?.content == "a19")
            request.complete()
        }

        @Test("Apple exact token counting trims additional oldest turns")
        func appleExactTokenCountingTrimsAdditionalOldestTurns() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            appleService.contextSize = 200
            appleService.tokenCountHandler = { request in
                20 + request.history.count * 50
            }
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-exact-budget"
            configureAppleModels([model], on: service)

            service.sendMessage(
                messages: [
                    Message(role: .user, content: "Old question"),
                    Message(role: .assistant, content: "Old answer"),
                    Message(role: .user, content: "Recent question"),
                    Message(role: .assistant, content: "Recent answer"),
                    Message(role: .user, content: "Latest"),
                ],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let request = try #require(await appleService.request(at: 0))

            #expect(request.history == [
                AppleIntelligenceHistoryEntry(role: .user, content: "Recent question"),
                AppleIntelligenceHistoryEntry(role: .assistant, content: "Recent answer"),
            ])
            request.complete()
        }

        @Test("Apple exact token counting can admit content rejected by fallback estimate")
        func appleExactTokenCountingCanAdmitFallbackRejectedContent() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            appleService.contextSize = 100
            appleService.tokenCountHandler = { _ in 20 }
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-exact-admission"
            configureAppleModels([model], on: service)
            let errors = FlightTestBox<[String]>([])

            service.sendMessage(
                messages: [Message(role: .user, content: String(repeating: "x", count: 200))],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { error in errors.update { $0.append(error.localizedDescription) } }
            )
            let request = try #require(await appleService.request(at: 0))

            #expect(request.prompt.count == 200)
            #expect(errors.value.isEmpty)
            request.complete()
        }

        @Test("Apple context budgeting never splits parallel tool outputs")
        func appleContextBudgetingNeverSplitsParallelToolOutputs() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            appleService.contextSize = 220
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-parallel-tools"
            configureAppleModels([model], on: service)

            let firstCall = MCPToolCall(id: "first", toolName: "first", arguments: [:])
            let secondCall = MCPToolCall(id: "second", toolName: "second", arguments: [:])
            var assistantCalls = Message(role: .assistant, content: "")
            assistantCalls.toolCalls = [firstCall, secondCall]
            var firstOutput = Message(role: .tool, content: String(repeating: "a", count: 20))
            firstOutput.toolCalls = [firstCall]
            var secondOutput = Message(role: .tool, content: String(repeating: "b", count: 20))
            secondOutput.toolCalls = [secondCall]

            let errorReceived = FlightTestBox<[String]>([])
            service.sendMessage(
                messages: [
                    Message(role: .user, content: "Run both tools"),
                    assistantCalls,
                    firstOutput,
                    secondOutput,
                ],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { error in errorReceived.update { $0.append(error.localizedDescription) } }
            )

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while errorReceived.value.isEmpty, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(errorReceived.value == ["Apple Intelligence context is too large to continue safely"])
            #expect(appleService.requests.isEmpty)
        }

        @Test("Apple context budgeting rejects oversized fixed prompt content")
        func appleContextBudgetingRejectsOversizedFixedPromptContent() async {
            let appleService = FlightTestAppleIntelligenceService()
            appleService.contextSize = 100
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-oversized-prompt"
            configureAppleModels([model], on: service)
            let errors = FlightTestBox<[String]>([])

            service.sendMessage(
                messages: [Message(role: .user, content: String(repeating: "x", count: 200))],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { error in errors.update { $0.append(error.localizedDescription) } }
            )

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while errors.value.isEmpty, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(errors.value == ["Apple Intelligence context is too large to continue safely"])
            #expect(appleService.requests.isEmpty)
        }

        @Test("Oversized Apple replacement cancels the previous foreground request")
        func oversizedAppleReplacementCancelsPreviousForegroundRequest() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-oversized-replacement"
            configureAppleModels([model], on: service)

            service.sendMessage(
                messages: [Message(role: .user, content: "First")],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let first = try #require(await appleService.request(at: 0))

            appleService.contextSize = 100
            let errors = FlightTestBox<[String]>([])
            service.sendMessage(
                messages: [Message(role: .user, content: String(repeating: "x", count: 200))],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { error in errors.update { $0.append(error.localizedDescription) } }
            )

            #expect(await first.cancelled.wait(timeout: .seconds(1)))
            #expect(errors.value == ["Apple Intelligence context is too large to continue safely"])
            #expect(appleService.requests.count == 1)
            #expect(appleService.clearedSessionIDs.contains(first.conversationID))
        }

        @Test("Apple history excludes explicitly unselected response alternatives")
        func appleHistoryExcludesExplicitlyUnselectedResponseAlternatives() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-selected-history"
            configureAppleModels([model], on: service)
            let groupID = UUID()

            service.sendMessage(
                messages: [
                    Message(role: .user, content: "Earlier"),
                    Message(
                        role: .assistant,
                        content: "Chosen answer",
                        responseGroupId: groupID,
                        isSelectedResponse: true
                    ),
                    Message(
                        role: .assistant,
                        content: "Rejected answer",
                        responseGroupId: groupID,
                        isSelectedResponse: false
                    ),
                    Message(role: .user, content: "Latest"),
                ],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let request = try #require(await appleService.request(at: 0))

            #expect(request.history == [
                AppleIntelligenceHistoryEntry(role: .user, content: "Earlier"),
                AppleIntelligenceHistoryEntry(role: .assistant, content: "Chosen answer"),
            ])
            request.complete()
        }

        @Test("Two Apple model aliases complete independently", .timeLimit(.minutes(1)))
        func twoAppleModelAliasesCompleteIndependently() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let models = ["apple-a", "apple-b"]
            configureAppleModels(models, on: service)
            let modelCompletions = FlightTestBox<Set<String>>([])
            let errors = FlightTestBox<[String]>([])
            let allComplete = FlightTestSignal()

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "Compare")],
                models: models,
                onChunk: { _, _ in },
                onModelComplete: { model in modelCompletions.update { $0.insert(model) } },
                onAllComplete: { allComplete.signal() },
                onError: { model, error in errors.update { $0.append("\(model):\(error.localizedDescription)") } }
            )

            let first = try #require(await appleService.request(sessionIDPrefix: "multi:default:\(models[0]):"))
            let second = try #require(await appleService.request(sessionIDPrefix: "multi:default:\(models[1]):"))
            #expect(!first.cancelled.isSignaled)
            #expect(!second.cancelled.isSignaled)

            first.complete()
            #expect(!second.cancelled.isSignaled)
            second.complete()

            #expect(await allComplete.wait(timeout: .seconds(2)))
            #expect(modelCompletions.value == Set(models))
            #expect(errors.value.isEmpty)
            #expect(Set(appleService.clearedSessionIDs) == Set([
                first.conversationID,
                second.conversationID,
            ]))
        }

        @Test("Replacing an Apple batch cancels its old child", .timeLimit(.minutes(1)))
        func replacingAppleBatchCancelsOldChild() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let oldModel = "apple-old"
            let newModel = "apple-new"
            configureAppleModels([oldModel, newModel], on: service)
            let oldChunks = FlightTestBox<[String]>([])
            let oldCompletions = FlightTestBox(0)
            let oldAllComplete = FlightTestBox(false)
            let newAllComplete = FlightTestSignal()

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "Old")],
                models: [oldModel],
                onChunk: { _, chunk in oldChunks.update { $0.append(chunk) } },
                onModelComplete: { _ in oldCompletions.update { $0 += 1 } },
                onAllComplete: { oldAllComplete.value = true },
                onError: { _, _ in }
            )
            let oldRequest = try #require(await appleService.request(sessionIDPrefix: "multi:default:\(oldModel):"))

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "New")],
                models: [newModel],
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: { newAllComplete.signal() },
                onError: { _, error in Issue.record("Unexpected error: \(error)") }
            )
            let newRequest = try #require(await appleService.request(sessionIDPrefix: "multi:default:\(newModel):"))
            #expect(await oldRequest.cancelled.wait(timeout: .seconds(1)))

            oldRequest.emitChunk("stale")
            oldRequest.complete()
            newRequest.complete()

            #expect(await newAllComplete.wait(timeout: .seconds(2)))
            #expect(oldChunks.value.isEmpty)
            #expect(oldCompletions.value == 0)
            #expect(!oldAllComplete.value)
        }

        @Test("Global cancellation stops foreground and all Apple batch children", .timeLimit(.minutes(1)))
        func globalCancellationStopsForegroundAndAllAppleBatchChildren() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let models = ["apple-foreground", "apple-a", "apple-b"]
            configureAppleModels(models, on: service)

            service.sendMessage(
                messages: [Message(role: .user, content: "Foreground")],
                model: models[0],
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let foreground = try #require(await appleService.request(sessionIDPrefix: "default:"))

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "Batch")],
                models: Array(models.dropFirst()),
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: {},
                onError: { _, _ in }
            )
            let firstBatch = try #require(await appleService.request(sessionIDPrefix: "multi:default:\(models[1]):"))
            let secondBatch = try #require(await appleService.request(sessionIDPrefix: "multi:default:\(models[2]):"))

            service.cancelCurrentRequest(includeImageRequests: false)

            #expect(await foreground.cancelled.wait(timeout: .seconds(1)))
            #expect(await firstBatch.cancelled.wait(timeout: .seconds(1)))
            #expect(await secondBatch.cancelled.wait(timeout: .seconds(1)))
            #expect(Set(appleService.clearedSessionIDs) == Set([
                foreground.conversationID,
                firstBatch.conversationID,
                secondBatch.conversationID,
            ]))
        }

        @Test("Apple request return without callback terminates the batch", .timeLimit(.minutes(1)))
        func appleRequestReturnWithoutCallbackTerminatesBatch() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-no-terminal"
            configureAppleModels([model], on: service)
            let errors = FlightTestBox<[String]>([])
            let allComplete = FlightTestSignal()

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "Return")],
                models: [model],
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: { allComplete.signal() },
                onError: { _, error in errors.update { $0.append(error.localizedDescription) } }
            )
            let request = try #require(await appleService.request(at: 0))
            request.returnWithoutTerminal()

            #expect(await allComplete.wait(timeout: .seconds(2)))
            #expect(errors.value == ["Apple Intelligence request ended without a terminal callback"])
        }

        @Test("Injected unavailable Apple service terminates a batch", .timeLimit(.minutes(1)))
        func injectedUnavailableAppleServiceTerminatesBatch() async {
            let appleService = FlightTestAppleIntelligenceService()
            appleService.isAvailable = false
            let service = AIService(appleIntelligenceService: appleService)
            let model = "apple-unavailable"
            configureAppleModels([model], on: service)
            let errors = FlightTestBox<[String]>([])
            let allComplete = FlightTestSignal()

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "Unavailable")],
                models: [model],
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: { allComplete.signal() },
                onError: { _, error in errors.update { $0.append(error.localizedDescription) } }
            )

            #expect(await allComplete.wait(timeout: .seconds(2)))
            #expect(errors.value == [appleService.unavailableDescription])
            #expect(appleService.requests.isEmpty)
        }

        private func configureAppleModels(_ models: [String], on service: AIService) {
            service.customModels = models
            service.selectedModel = models[0]
            for model in models {
                service.modelProviders[model] = .appleIntelligence
            }
        }
    }
#endif

#if !os(watchOS)
    @Suite("Apple Intelligence Retry Gate Tests", .tags(.async))
    @MainActor
    struct AppleIntelligenceRetryGateTests {
        @Test("Cancellation during retry delay prevents another attempt")
        func cancellationDuringRetryDelayPreventsAnotherAttempt() async {
            let delayStarted = FlightTestSignal()
            let releaseDelay = FlightTestSignal()
            let result = FlightTestBox(true)
            var clearCount = 0

            let task = Task { @MainActor in
                result.value = await AppleIntelligenceRetryGate.prepare(
                    clearSession: { clearCount += 1 },
                    delay: {
                        delayStarted.signal()
                        await releaseDelay.wait()
                    }
                )
            }
            await delayStarted.wait()
            task.cancel()
            releaseDelay.signal()
            await task.value

            #expect(!result.value)
            #expect(clearCount == 1)
        }

        @Test("Pre-cancelled retry does not clear the session or start delay")
        func preCancelledRetryDoesNotClearSessionOrStartDelay() async {
            let delayStarted = FlightTestSignal()
            var clearCount = 0

            let result = await Task { @MainActor in
                withUnsafeCurrentTask { currentTask in
                    currentTask?.cancel()
                }
                return await AppleIntelligenceRetryGate.prepare(
                    clearSession: { clearCount += 1 },
                    delay: { delayStarted.signal() }
                )
            }.value

            #expect(!result)
            #expect(clearCount == 0)
            #expect(!delayStarted.isSignaled)
        }
    }
#endif
