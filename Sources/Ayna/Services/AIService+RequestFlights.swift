import Foundation

extension AIService {
    func cancelTextRequest(_ flightID: RequestFlightID) {
        let dataTask = currentTask.take(ifOwnedBy: flightID)
        let backgroundDataTask = backgroundDataTasks.removeValue(forKey: flightID)
        let requestBuildTask = currentRequestBuildTask.take(ifOwnedBy: flightID)
        let backgroundRequestBuildTask = backgroundRequestBuildTasks.removeValue(forKey: flightID)
        let streamTask = currentStreamTask.take(ifOwnedBy: flightID)
        let backgroundStreamTask = backgroundStreamTasks.removeValue(forKey: flightID)
        let simulatedRequest = currentSimulatedTextRequest.take(ifOwnedBy: flightID)
        let backgroundSimulatedRequest = backgroundSimulatedTextRequests.removeValue(forKey: flightID)
        let anthropicProvider = currentAnthropicProvider.take(ifOwnedBy: flightID)
        let backgroundAnthropicProvider = backgroundAnthropicProviders.removeValue(forKey: flightID)

        let multiDataTasks = takeOwnedMultiModelFlights(from: &multiModelDataTasks, flightID: flightID)
        let multiRequestBuildTasks = takeOwnedMultiModelFlights(from: &multiModelRequestBuildTasks, flightID: flightID)
        let multiStreamTasks = takeOwnedMultiModelFlights(from: &multiModelStreamTasks, flightID: flightID)
        let multiSimulatedRequests = takeOwnedMultiModelFlights(from: &multiModelSimulatedTextRequests, flightID: flightID)
        let multiAnthropicProviders = takeOwnedMultiModelFlights(from: &multiModelAnthropicProviders, flightID: flightID)

        #if !os(watchOS)
            let appleTask = currentAppleIntelligenceTask.take(ifOwnedBy: flightID)
            let backgroundAppleTask = backgroundAppleIntelligenceTasks.removeValue(forKey: flightID)
            let multiAppleTasks = takeOwnedMultiModelFlights(from: &multiModelAppleIntelligenceTasks, flightID: flightID)
        #endif

        dataTask?.cancel()
        backgroundDataTask?.cancel()
        multiDataTasks.forEach { $0.cancel() }
        requestBuildTask?.cancel()
        backgroundRequestBuildTask?.cancel()
        multiRequestBuildTasks.forEach { $0.cancel() }
        streamTask?.cancel()
        backgroundStreamTask?.cancel()
        multiStreamTasks.forEach { $0.cancel() }
        simulatedRequest?.cancel()
        backgroundSimulatedRequest?.cancel()
        multiSimulatedRequests.forEach { $0.cancel() }
        anthropicProvider?.cancelRequest()
        backgroundAnthropicProvider?.cancelRequest()
        multiAnthropicProviders.forEach { $0.cancelRequest() }
        #if !os(watchOS)
            appleTask?.cancel()
            backgroundAppleTask?.cancel()
            multiAppleTasks.forEach { $0.cancel() }
        #endif
    }

    func cancelTextBatchRequest(_ flightID: RequestFlightID) {
        guard let batchTask = multiModelTask.take(ifOwnedBy: flightID) else { return }

        batchTask.cancel()
        cancelTextRequest(flightID)
    }

    func cancelCurrentRequest(includeImageRequests: Bool = true) {
        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "Canceling current request"
        )

        let dataTask = currentTask.take()
        let multiModelBatchTask = multiModelTask.take()
        let multiDataTasks = takeAllMultiModelFlights(from: &multiModelDataTasks)
        let requestBuildTask = currentRequestBuildTask.take()
        let multiRequestBuildTasks = takeAllMultiModelFlights(from: &multiModelRequestBuildTasks)
        let streamTask = currentStreamTask.take()
        let simulatedRequest = currentSimulatedTextRequest.take()
        let multiSimulatedRequests = takeAllMultiModelFlights(from: &multiModelSimulatedTextRequests)
        let multiStreamTasks = takeAllMultiModelFlights(from: &multiModelStreamTasks)
        let anthropicProvider = currentAnthropicProvider.take()
        let multiAnthropicProviders = takeAllMultiModelFlights(from: &multiModelAnthropicProviders)
        #if !os(watchOS)
            let appleTask = currentAppleIntelligenceTask.take()
            let multiAppleTasks = takeAllMultiModelFlights(from: &multiModelAppleIntelligenceTasks)
            let imageRequestHandles: [OpenAIImageService.RequestHandle]
            if includeImageRequests {
                imageRequestHandles = Array(imageRequests.values)
                imageRequests.removeAll()
            } else {
                imageRequestHandles = []
            }
        #endif

        multiModelBatchTask?.cancel()
        dataTask?.cancel()
        for (model, task) in multiDataTasks {
            task.cancel()
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "Cancelled multi-model data task",
                metadata: ["model": model]
            )
        }
        requestBuildTask?.cancel()
        for (model, task) in multiRequestBuildTasks {
            task.cancel()
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "Cancelled multi-model request build task",
                metadata: ["model": model]
            )
        }
        streamTask?.cancel()
        simulatedRequest?.cancel()
        multiSimulatedRequests.forEach { $0.value.cancel() }
        for (model, task) in multiStreamTasks {
            task.cancel()
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "Cancelled multi-model stream task",
                metadata: ["model": model]
            )
        }
        anthropicProvider?.cancelRequest()
        multiAnthropicProviders.forEach { $0.value.cancelRequest() }
        #if !os(watchOS)
            appleTask?.cancel()
            multiAppleTasks.forEach { $0.value.cancel() }
            imageRequestHandles.forEach { $0.cancel() }
        #endif
        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "Request cancellation initiated"
        )
    }

    func cancelAllMultiModelFlights() {
        let previousBatchTask = multiModelTask.take()
        let previousDataTasks = takeAllMultiModelFlights(from: &multiModelDataTasks)
        let previousRequestBuildTasks = takeAllMultiModelFlights(from: &multiModelRequestBuildTasks)
        let previousStreamTasks = takeAllMultiModelFlights(from: &multiModelStreamTasks)
        let previousSimulatedRequests = takeAllMultiModelFlights(from: &multiModelSimulatedTextRequests)
        let previousAnthropicProviders = takeAllMultiModelFlights(from: &multiModelAnthropicProviders)
        #if !os(watchOS)
            let previousAppleTasks = takeAllMultiModelFlights(from: &multiModelAppleIntelligenceTasks)
        #endif

        previousBatchTask?.cancel()
        previousDataTasks.forEach { $0.value.cancel() }
        previousRequestBuildTasks.forEach { $0.value.cancel() }
        previousStreamTasks.forEach { $0.value.cancel() }
        previousSimulatedRequests.forEach { $0.value.cancel() }
        previousAnthropicProviders.forEach { $0.value.cancelRequest() }
        #if !os(watchOS)
            previousAppleTasks.forEach { $0.value.cancel() }
        #endif
    }

    private func takeOwnedMultiModelFlights<Handle>(
        from dictionary: inout [String: RequestFlight<Handle>],
        flightID: RequestFlightID
    ) -> [Handle] {
        let ownedModels = dictionary.compactMap { model, flight in
            flight.owns(flightID) ? model : nil
        }
        return ownedModels.compactMap { model -> Handle? in
            var ownedFlight = dictionary.removeValue(forKey: model)
            return ownedFlight?.take(ifOwnedBy: flightID)
        }
    }

    private func takeAllMultiModelFlights<Handle>(
        from dictionary: inout [String: RequestFlight<Handle>]
    ) -> [(model: String, value: Handle)] {
        let items = dictionary.compactMap { model, flight -> (model: String, value: Handle)? in
            var flight = flight
            return flight.take().map { (model, $0) }
        }
        dictionary.removeAll()
        return items
    }

    @discardableResult
    func clearRequestBuildFlight(
        _ flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Bool {
        if requestLane == .background {
            return backgroundRequestBuildTasks.removeValue(forKey: flightID) != nil
        }
        if isMultiModelRequest {
            guard var flight = multiModelRequestBuildTasks[modelName],
                  flight.clear(ifOwnedBy: flightID)
            else {
                return false
            }
            multiModelRequestBuildTasks.removeValue(forKey: modelName)
            return true
        }
        return currentRequestBuildTask.clear(ifOwnedBy: flightID)
    }

    @discardableResult
    func installRequestBuildTask(
        _ task: Task<Void, Never>,
        flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Task<Void, Never>? {
        if requestLane == .background {
            return backgroundRequestBuildTasks.updateValue(task, forKey: flightID)
        }
        if isMultiModelRequest {
            var flight = multiModelRequestBuildTasks[modelName] ?? RequestFlight()
            let previousTask = flight.install(task, id: flightID)
            multiModelRequestBuildTasks[modelName] = flight
            return previousTask
        }
        return currentRequestBuildTask.install(task, id: flightID)
    }

    func ownsDataFlight(
        _ flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Bool {
        if requestLane == .background {
            return backgroundDataTasks[flightID] != nil
        }
        if isMultiModelRequest {
            return multiModelDataTasks[modelName]?.owns(flightID) == true
        }
        return currentTask.owns(flightID)
    }

    @discardableResult
    func clearDataFlight(
        _ flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Bool {
        if requestLane == .background {
            return backgroundDataTasks.removeValue(forKey: flightID) != nil
        }
        if isMultiModelRequest {
            guard var flight = multiModelDataTasks[modelName],
                  flight.clear(ifOwnedBy: flightID)
            else {
                return false
            }
            multiModelDataTasks.removeValue(forKey: modelName)
            return true
        }
        return currentTask.clear(ifOwnedBy: flightID)
    }

    func takeDataTask(
        flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> URLSessionDataTask? {
        if requestLane == .background {
            return backgroundDataTasks.removeValue(forKey: flightID)
        }
        if isMultiModelRequest {
            var flight = multiModelDataTasks.removeValue(forKey: modelName)
            return flight?.take()
        }
        return currentTask.take()
    }

    @discardableResult
    func installDataTask(
        _ task: URLSessionDataTask,
        flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String,
        requiresExistingOwner: Bool
    ) -> Bool {
        if requestLane == .background {
            guard !requiresExistingOwner || backgroundDataTasks[flightID] != nil else { return false }
            backgroundDataTasks[flightID] = task
            return true
        }
        if isMultiModelRequest {
            var flight = multiModelDataTasks[modelName] ?? RequestFlight()
            guard !requiresExistingOwner || flight.owns(flightID) else { return false }
            flight.install(task, id: flightID)
            multiModelDataTasks[modelName] = flight
            return true
        }

        guard !requiresExistingOwner || currentTask.owns(flightID) else { return false }
        currentTask.install(task, id: flightID)
        return true
    }

    func ownsSimulatedTextRequest(
        _ flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Bool {
        if requestLane == .background {
            return backgroundSimulatedTextRequests[flightID] != nil
        }
        if isMultiModelRequest {
            return multiModelSimulatedTextRequests[modelName]?.owns(flightID) == true
        }
        return currentSimulatedTextRequest.owns(flightID)
    }

    func beginSimulatedTextRequest(
        flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> SimulatedTextRequestHandle {
        let requestHandle = SimulatedTextRequestHandle()
        let previousHandle: SimulatedTextRequestHandle?
        if requestLane == .background {
            previousHandle = backgroundSimulatedTextRequests.updateValue(requestHandle, forKey: flightID)
        } else if isMultiModelRequest {
            var flight = multiModelSimulatedTextRequests[modelName] ?? RequestFlight()
            previousHandle = flight.install(requestHandle, id: flightID)
            multiModelSimulatedTextRequests[modelName] = flight
        } else {
            previousHandle = currentSimulatedTextRequest.install(requestHandle, id: flightID)
        }
        previousHandle?.cancel()
        return requestHandle
    }

    @discardableResult
    func finishSimulatedTextRequest(
        _ flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String,
        requestHandle: SimulatedTextRequestHandle
    ) -> Bool {
        let ownedHandle: SimulatedTextRequestHandle?
        if requestLane == .background {
            ownedHandle = backgroundSimulatedTextRequests.removeValue(forKey: flightID)
        } else if isMultiModelRequest {
            guard var flight = multiModelSimulatedTextRequests[modelName],
                  let handle = flight.take(ifOwnedBy: flightID)
            else {
                return false
            }
            multiModelSimulatedTextRequests.removeValue(forKey: modelName)
            ownedHandle = handle
        } else {
            ownedHandle = currentSimulatedTextRequest.take(ifOwnedBy: flightID)
        }
        guard let ownedHandle, ownedHandle === requestHandle else {
            ownedHandle?.cancel()
            return false
        }
        requestHandle.finish()
        return true
    }

    func ownsStreamFlight(
        _ flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String?
    ) -> Bool {
        if requestLane == .background {
            return backgroundStreamTasks[flightID] != nil
        }
        if isMultiModelRequest {
            guard let modelName else { return false }
            return multiModelStreamTasks[modelName]?.owns(flightID) == true
        }
        return currentStreamTask.owns(flightID)
    }

    @discardableResult
    func clearStreamFlight(
        _ flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String?
    ) -> Bool {
        if requestLane == .background {
            return backgroundStreamTasks.removeValue(forKey: flightID) != nil
        }
        if isMultiModelRequest {
            guard let modelName,
                  var flight = multiModelStreamTasks[modelName],
                  flight.clear(ifOwnedBy: flightID)
            else {
                return false
            }
            multiModelStreamTasks.removeValue(forKey: modelName)
            return true
        }
        return currentStreamTask.clear(ifOwnedBy: flightID)
    }

    func takeStreamTask(
        flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String?
    ) -> Task<Void, Never>? {
        if requestLane == .background {
            return backgroundStreamTasks.removeValue(forKey: flightID)
        }
        if isMultiModelRequest {
            guard let modelName else { return nil }
            var flight = multiModelStreamTasks.removeValue(forKey: modelName)
            return flight?.take()
        }
        return currentStreamTask.take()
    }

    @discardableResult
    func installStreamTask(
        _ task: Task<Void, Never>,
        flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String?,
        requiresExistingOwner: Bool
    ) -> Bool {
        if requestLane == .background {
            guard !requiresExistingOwner || backgroundStreamTasks[flightID] != nil else { return false }
            backgroundStreamTasks[flightID] = task
            return true
        }
        if isMultiModelRequest {
            guard let modelName else { return false }
            var flight = multiModelStreamTasks[modelName] ?? RequestFlight()
            guard !requiresExistingOwner || flight.owns(flightID) else { return false }
            flight.install(task, id: flightID)
            multiModelStreamTasks[modelName] = flight
            return true
        }

        guard !requiresExistingOwner || currentStreamTask.owns(flightID) else { return false }
        currentStreamTask.install(task, id: flightID)
        return true
    }
}
