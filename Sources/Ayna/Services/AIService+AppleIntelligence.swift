import Foundation

#if !os(watchOS)
    extension AIService {
        func ownsAppleIntelligenceFlight(
            _ flightID: RequestFlightID,
            requestLane: AITextRequestLane,
            isMultiModelRequest: Bool,
            modelName: String
        ) -> Bool {
            if requestLane == .background {
                return backgroundAppleIntelligenceTasks[flightID] != nil
            }
            if isMultiModelRequest {
                return multiModelAppleIntelligenceTasks[modelName]?.owns(flightID) == true
            }
            return currentAppleIntelligenceTask.owns(flightID)
        }

        @discardableResult
        func clearAppleIntelligenceFlight(
            _ flightID: RequestFlightID,
            requestLane: AITextRequestLane,
            isMultiModelRequest: Bool,
            modelName: String
        ) -> Bool {
            if requestLane == .background {
                return backgroundAppleIntelligenceTasks.removeValue(forKey: flightID) != nil
            }
            if isMultiModelRequest {
                guard var flight = multiModelAppleIntelligenceTasks[modelName],
                      flight.clear(ifOwnedBy: flightID)
                else {
                    return false
                }
                multiModelAppleIntelligenceTasks.removeValue(forKey: modelName)
                return true
            }
            return currentAppleIntelligenceTask.clear(ifOwnedBy: flightID)
        }

        @discardableResult
        private func finishAppleIntelligenceFlight(
            _ flightID: RequestFlightID,
            request: AppleIntelligenceRequestContext,
            sessionID: String
        ) -> Bool {
            guard clearAppleIntelligenceFlight(
                flightID,
                requestLane: request.requestLane,
                isMultiModelRequest: request.isMultiModelRequest,
                modelName: request.modelName
            ) else {
                return false
            }
            request.service.clearSession(conversationId: sessionID)
            return true
        }

        private func installAppleIntelligenceHandle(
            _ handle: AppleIntelligenceRequestHandle,
            flightID: RequestFlightID,
            requestLane: AITextRequestLane,
            isMultiModelRequest: Bool,
            modelName: String
        ) -> AppleIntelligenceRequestHandle? {
            if requestLane == .background {
                return backgroundAppleIntelligenceTasks.updateValue(handle, forKey: flightID)
            }
            if isMultiModelRequest {
                var flight = multiModelAppleIntelligenceTasks[modelName] ?? RequestFlight()
                let previous = flight.install(handle, id: flightID)
                multiModelAppleIntelligenceTasks[modelName] = flight
                return previous
            }
            return currentAppleIntelligenceTask.install(handle, id: flightID)
        }

        private func appleSessionID(for request: AppleIntelligenceRequestContext) -> String {
            let conversationScope = request.conversationID?.uuidString ?? "default"
            let requestScope = UUID().uuidString
            if request.requestLane == .background {
                return "background:\(conversationScope):\(request.modelName):\(requestScope)"
            }
            return request.isMultiModelRequest
                ? "multi:\(conversationScope):\(request.modelName):\(requestScope)"
                : "\(conversationScope):\(requestScope)"
        }

        private func appleSystemInstructions(
            messages: [Message],
            conversationID: UUID?
        ) -> String {
            var instructions = messages.first(where: { $0.role == .system })?.content
                ?? "You are a helpful assistant."
            let memoryContext = MemoryContextProvider.shared.buildContext(
                currentConversationId: conversationID
            )
            guard memoryContext.hasContent else { return instructions }

            let memoryParts = [
                memoryContext.sessionMetadata,
                memoryContext.userMemory,
                memoryContext.conversationSummaries,
            ].compactMap(\.self)
            if !memoryParts.isEmpty {
                instructions += "\n\n" + memoryParts.joined(separator: "\n\n")
            }
            return instructions
        }

        private func appleToolMatchPlan(messages: [Message]) -> AppleToolMatchPlan {
            struct PendingCall {
                let messageID: UUID
                let index: Int
                let normalizedID: String
            }

            var plan = AppleToolMatchPlan()
            var pendingByOriginalID: [String: [PendingCall]] = [:]
            var occurrenceByOriginalID: [String: Int] = [:]
            let originalIDs = Set(messages.flatMap { ($0.toolCalls ?? []).map(\.id) })
            var assignedIDs: Set<String> = []
            for message in messages {
                switch message.role {
                case .assistant:
                    for (index, call) in (message.toolCalls ?? []).enumerated() {
                        let occurrence = occurrenceByOriginalID[call.id, default: 0]
                        occurrenceByOriginalID[call.id] = occurrence + 1
                        var normalizedID = call.id
                        if occurrence > 0 || assignedIDs.contains(normalizedID) {
                            var suffix = max(1, occurrence)
                            repeat {
                                normalizedID = "\(call.id)#\(suffix)"
                                suffix += 1
                            } while originalIDs.contains(normalizedID) || assignedIDs.contains(normalizedID)
                        }
                        assignedIDs.insert(normalizedID)
                        pendingByOriginalID[call.id, default: []].append(PendingCall(
                            messageID: message.id,
                            index: index,
                            normalizedID: normalizedID
                        ))
                    }
                case .tool:
                    for (index, call) in (message.toolCalls ?? []).enumerated() {
                        guard var pending = pendingByOriginalID[call.id],
                              let matched = pending.popLast()
                        else {
                            continue
                        }
                        pendingByOriginalID[call.id] = pending
                        plan.assistantCallIDs[matched.messageID, default: [:]][matched.index] = matched.normalizedID
                        plan.toolOutputIDs[message.id, default: [:]][index] = matched.normalizedID
                    }
                case .system, .user:
                    break
                }
            }
            return plan
        }

        private func appleHistoryEntries(
            from message: Message,
            matchPlan: AppleToolMatchPlan
        ) -> [AppleIntelligenceHistoryEntry] {
            let content = message.content
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

            switch message.role {
            case .user:
                guard !trimmedContent.isEmpty else { return [] }
                return [AppleIntelligenceHistoryEntry(role: .user, content: content)]
            case .assistant:
                let toolCalls = (message.toolCalls ?? []).enumerated().compactMap { index, toolCall -> AppleIntelligenceToolCall? in
                    guard let normalizedID = matchPlan.assistantCallIDs[message.id]?[index],
                          let data = try? JSONEncoder().encode(toolCall.arguments),
                          let argumentsJSON = String(data: data, encoding: .utf8)
                    else {
                        return nil
                    }
                    return AppleIntelligenceToolCall(
                        id: normalizedID,
                        name: toolCall.toolName,
                        argumentsJSON: argumentsJSON
                    )
                }
                guard !trimmedContent.isEmpty || !toolCalls.isEmpty else { return [] }
                return [AppleIntelligenceHistoryEntry(
                    role: .assistant,
                    content: content,
                    toolCalls: toolCalls
                )]
            case .tool:
                return (message.toolCalls ?? []).enumerated().compactMap { index, toolCall in
                    guard let normalizedID = matchPlan.toolOutputIDs[message.id]?[index] else { return nil }
                    return AppleIntelligenceHistoryEntry(
                        role: .tool,
                        content: trimmedContent.isEmpty ? "(empty tool output)" : content,
                        toolName: toolCall.toolName,
                        toolCallID: normalizedID
                    )
                }
            case .system:
                return []
            }
        }

        private func appleConversationContext(
            messages: [Message]
        ) -> AppleConversationContext? {
            let messages = messages.filter { $0.isSelectedResponse != false }
            guard let promptIndex = messages.lastIndex(where: { $0.role == .user }) else { return nil }
            let matchPlan = appleToolMatchPlan(messages: messages)

            let tailEntries = messages[messages.index(after: promptIndex)...].flatMap {
                appleHistoryEntries(from: $0, matchPlan: matchPlan)
            }
            if !tailEntries.isEmpty {
                let history = messages.flatMap {
                    appleHistoryEntries(from: $0, matchPlan: matchPlan)
                }
                return AppleConversationContext(
                    history: history,
                    prompt: "Continue the conversation using the completed context above.",
                    requiresHistory: true
                )
            }

            let history = messages[..<promptIndex].flatMap {
                appleHistoryEntries(from: $0, matchPlan: matchPlan)
            }
            return AppleConversationContext(
                history: history,
                prompt: messages[promptIndex].content,
                requiresHistory: false
            )
        }

        private func appleHistoryGroups(
            _ history: [AppleIntelligenceHistoryEntry]
        ) -> [[AppleIntelligenceHistoryEntry]] {
            var groups: [[AppleIntelligenceHistoryEntry]] = []
            for entry in history {
                switch entry.role {
                case .user:
                    groups.append([entry])
                case .assistant:
                    if groups.last?.first?.role == .user {
                        groups[groups.count - 1].append(entry)
                    } else {
                        groups.append([entry])
                    }
                case .tool:
                    if let toolCallID = entry.toolCallID,
                       groups.last?.contains(where: {
                           $0.role == .assistant && $0.toolCalls.contains(where: { $0.id == toolCallID })
                       }) == true
                    {
                        groups[groups.count - 1].append(entry)
                    } else {
                        groups.append([entry])
                    }
                }
            }
            return groups
        }

        private func estimatedAppleHistoryTokens(
            _ entries: [AppleIntelligenceHistoryEntry]
        ) -> Int {
            AppleIntelligenceTranscriptBuilder.entries(from: entries).reduce(0) { total, entry in
                total + 12 + estimatedAppleTokens(entry.content)
            }
        }

        private func estimatedAppleTokens(_ text: String) -> Int {
            let scalarCount = text.unicodeScalars.count
            let asciiCount = text.unicodeScalars.lazy.filter(\.isASCII).count
            let nonASCII = scalarCount - asciiCount
            return ((asciiCount + 1) / 2) + nonASCII
        }

        private func compactAppleHistory(
            _ history: [AppleIntelligenceHistoryEntry],
            contextSize: Int,
            systemInstructions: String,
            prompt: String,
            requireNewestGroup: Bool
        ) -> [AppleIntelligenceHistoryEntry]? {
            let responseReserve = max(64, min(1024, contextSize / 4))
            let fixedCost = responseReserve + estimatedAppleTokens(systemInstructions) +
                estimatedAppleTokens(prompt) + 32
            guard fixedCost <= contextSize else { return nil }
            var remaining = contextSize - fixedCost
            var retainedGroups: [[AppleIntelligenceHistoryEntry]] = []
            for group in appleHistoryGroups(history).reversed() {
                let groupCost = estimatedAppleHistoryTokens(group)
                guard groupCost <= remaining else {
                    return requireNewestGroup && retainedGroups.isEmpty ? nil : retainedGroups.flatMap(\.self)
                }
                retainedGroups.insert(group, at: 0)
                remaining -= groupCost
            }
            return retainedGroups.flatMap(\.self)
        }

        private func fallbackAppleServiceRequest(
            request: AppleIntelligenceRequestContext,
            conversationContext: AppleConversationContext,
            sessionID: String,
            systemInstructions: String,
            temperature: Double
        ) -> AppleIntelligenceRequest? {
            guard let history = compactAppleHistory(
                conversationContext.history,
                contextSize: request.service.contextSize,
                systemInstructions: systemInstructions,
                prompt: conversationContext.prompt,
                requireNewestGroup: conversationContext.requiresHistory
            ) else {
                return nil
            }
            return AppleIntelligenceRequest(
                conversationID: sessionID,
                prompt: conversationContext.prompt,
                history: history,
                systemInstructions: systemInstructions,
                temperature: temperature
            )
        }

        private func validatedAppleServiceRequest(
            request: AppleIntelligenceRequestContext,
            conversationContext: AppleConversationContext,
            sessionID: String,
            systemInstructions: String,
            temperature: Double
        ) async -> AppleIntelligenceRequest? {
            var candidate = AppleIntelligenceRequest(
                conversationID: sessionID,
                prompt: conversationContext.prompt,
                history: conversationContext.history,
                systemInstructions: systemInstructions,
                temperature: temperature
            )
            let maxInputTokens = max(0, request.service.contextSize - max(64, min(1024, request.service.contextSize / 4)))
            if let initialCount = await request.service.tokenCount(for: candidate) {
                guard initialCount > maxInputTokens else { return candidate }

                var groups = appleHistoryGroups(candidate.history)
                while !groups.isEmpty {
                    if conversationContext.requiresHistory, groups.count == 1 {
                        return nil
                    }
                    groups.removeFirst()
                    candidate = AppleIntelligenceRequest(
                        conversationID: sessionID,
                        prompt: conversationContext.prompt,
                        history: groups.flatMap(\.self),
                        systemInstructions: systemInstructions,
                        temperature: temperature
                    )
                    guard let tokenCount = await request.service.tokenCount(for: candidate) else {
                        return fallbackAppleServiceRequest(
                            request: request,
                            conversationContext: conversationContext,
                            sessionID: sessionID,
                            systemInstructions: systemInstructions,
                            temperature: temperature
                        )
                    }
                    if tokenCount <= maxInputTokens {
                        return candidate
                    }
                }
                return nil
            }

            return fallbackAppleServiceRequest(
                request: request,
                conversationContext: conversationContext,
                sessionID: sessionID,
                systemInstructions: systemInstructions,
                temperature: temperature
            )
        }

        private func ownedAppleServiceRequest(
            request: AppleIntelligenceRequestContext,
            conversationContext: AppleConversationContext,
            sessionID: String,
            systemInstructions: String,
            temperature: Double,
            flightID: RequestFlightID
        ) async -> AppleIntelligenceRequest? {
            guard let serviceRequest = await validatedAppleServiceRequest(
                request: request,
                conversationContext: conversationContext,
                sessionID: sessionID,
                systemInstructions: systemInstructions,
                temperature: temperature
            ) else {
                guard finishAppleIntelligenceFlight(
                    flightID,
                    request: request,
                    sessionID: sessionID
                ) else {
                    return nil
                }
                request.onError(AynaError.apiError(message: "Apple Intelligence context is too large to continue safely"))
                return nil
            }
            guard ownsAppleIntelligenceFlight(
                flightID,
                requestLane: request.requestLane,
                isMultiModelRequest: request.isMultiModelRequest,
                modelName: request.modelName
            ) else {
                return nil
            }
            return serviceRequest
        }

        func handleAppleIntelligenceRequest(
            _ request: AppleIntelligenceRequestContext,
            flightID: RequestFlightID = RequestFlightID()
        ) {
            guard request.service.isAvailable else {
                request.onError(AynaError.apiError(message: request.service.availabilityDescription()))
                return
            }
            guard let conversationContext = appleConversationContext(messages: request.messages) else {
                request.onError(AynaError.apiError(message: "No user message found"))
                return
            }

            let systemInstructions = appleSystemInstructions(
                messages: request.messages,
                conversationID: request.conversationID
            )
            let sessionID = appleSessionID(for: request)
            let requestTemperature = request.temperature ?? 0.7
            let task = Task { @MainActor [weak self] in
                guard let self,
                      self.ownsAppleIntelligenceFlight(
                          flightID,
                          requestLane: request.requestLane,
                          isMultiModelRequest: request.isMultiModelRequest,
                          modelName: request.modelName
                      )
                else {
                    return
                }
                guard let serviceRequest = await self.ownedAppleServiceRequest(
                    request: request,
                    conversationContext: conversationContext,
                    sessionID: sessionID,
                    systemInstructions: systemInstructions,
                    temperature: requestTemperature,
                    flightID: flightID
                ) else {
                    return
                }

                await self.executeAppleIntelligenceRequest(
                    request: request,
                    serviceRequest: serviceRequest,
                    sessionID: sessionID,
                    flightID: flightID
                )

                guard !Task.isCancelled,
                      self.finishAppleIntelligenceFlight(
                          flightID,
                          request: request,
                          sessionID: sessionID
                      )
                else {
                    return
                }
                request.onError(AynaError.apiError(message: "Apple Intelligence request ended without a terminal callback"))
            }
            let handle = AppleIntelligenceRequestHandle(
                task: task,
                service: request.service,
                sessionID: sessionID
            )
            installAppleIntelligenceHandle(
                handle,
                flightID: flightID,
                requestLane: request.requestLane,
                isMultiModelRequest: request.isMultiModelRequest,
                modelName: request.modelName
            )?.cancel()
        }

        private func executeAppleIntelligenceRequest(
            request: AppleIntelligenceRequestContext,
            serviceRequest: AppleIntelligenceRequest,
            sessionID: String,
            flightID: RequestFlightID
        ) async {
            if request.stream {
                await request.service.streamResponse(
                    request: serviceRequest,
                    onChunk: { [weak self] chunk in
                        guard let self,
                              self.ownsAppleIntelligenceFlight(
                                  flightID,
                                  requestLane: request.requestLane,
                                  isMultiModelRequest: request.isMultiModelRequest,
                                  modelName: request.modelName
                              )
                        else {
                            return
                        }
                        request.onChunk(chunk)
                    },
                    onComplete: { [weak self] in
                        guard let self,
                              self.finishAppleIntelligenceFlight(
                                  flightID,
                                  request: request,
                                  sessionID: sessionID
                              )
                        else {
                            return
                        }
                        request.onComplete()
                    },
                    onError: { [weak self] error in
                        guard let self,
                              self.finishAppleIntelligenceFlight(
                                  flightID,
                                  request: request,
                                  sessionID: sessionID
                              )
                        else {
                            return
                        }
                        request.onError(error)
                    }
                )
            } else {
                await request.service.generateResponse(
                    request: serviceRequest,
                    onComplete: { [weak self] response in
                        guard let self,
                              self.ownsAppleIntelligenceFlight(
                                  flightID,
                                  requestLane: request.requestLane,
                                  isMultiModelRequest: request.isMultiModelRequest,
                                  modelName: request.modelName
                              )
                        else {
                            return
                        }
                        request.onChunk(response)
                        guard self.finishAppleIntelligenceFlight(
                            flightID,
                            request: request,
                            sessionID: sessionID
                        ) else {
                            return
                        }
                        request.onComplete()
                    },
                    onError: { [weak self] error in
                        guard let self,
                              self.finishAppleIntelligenceFlight(
                                  flightID,
                                  request: request,
                                  sessionID: sessionID
                              )
                        else {
                            return
                        }
                        request.onError(error)
                    }
                )
            }
        }
    }
#endif
