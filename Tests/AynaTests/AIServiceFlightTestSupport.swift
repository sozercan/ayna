@testable import Ayna
import Foundation

final class FlightTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }

    func signal() {
        lock.lock()
        guard !signaled else {
            lock.unlock()
            return
        }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func wait(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isSignaled, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return isSignaled
    }
}

final class FlightTestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storedValue)
        lock.unlock()
    }
}

final class FlightTestURLProtocolServer: @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [FlightTestURLProtocolExchange] = []
    private var waiters: [Int: [CheckedContinuation<FlightTestURLProtocolExchange, Never>]] = [:]

    fileprivate func record(_ exchange: FlightTestURLProtocolExchange) {
        lock.lock()
        exchanges.append(exchange)
        let index = exchanges.count - 1
        let pending = waiters.removeValue(forKey: index) ?? []
        lock.unlock()
        pending.forEach { $0.resume(returning: exchange) }
    }

    func exchange(at index: Int) async -> FlightTestURLProtocolExchange {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exchanges.indices.contains(index) {
                let exchange = exchanges[index]
                lock.unlock()
                continuation.resume(returning: exchange)
            } else {
                waiters[index, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return exchanges.count
    }
}

final class FlightTestURLProtocolExchange: @unchecked Sendable {
    private struct State {
        var sentResponse = false
        var finished = false
        var stopped = false
    }

    let request: URLRequest

    private weak var protocolInstance: FlightTestURLProtocol?
    private let lock = NSLock()
    private var state = State()

    fileprivate init(request: URLRequest, protocolInstance: FlightTestURLProtocol) {
        self.request = request
        self.protocolInstance = protocolInstance
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.stopped
    }

    func sendResponse(statusCode: Int, headers: [String: String] = [:]) {
        lock.lock()
        guard !state.stopped, !state.finished, !state.sentResponse else {
            lock.unlock()
            return
        }
        state.sentResponse = true
        lock.unlock()

        guard let protocolInstance,
              let response = HTTPURLResponse(
                  url: request.url!,
                  statusCode: statusCode,
                  httpVersion: nil,
                  headerFields: headers
              )
        else {
            return
        }
        protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func send(_ data: Data) {
        lock.lock()
        let canSend = state.sentResponse && !state.stopped && !state.finished
        lock.unlock()
        guard canSend, let protocolInstance else { return }
        protocolInstance.client?.urlProtocol(protocolInstance, didLoad: data)
    }

    func finish() {
        lock.lock()
        guard state.sentResponse, !state.stopped, !state.finished else {
            lock.unlock()
            return
        }
        state.finished = true
        lock.unlock()
        guard let protocolInstance else { return }
        protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !state.stopped, !state.finished else {
            lock.unlock()
            return
        }
        state.finished = true
        lock.unlock()
        guard let protocolInstance else { return }
        protocolInstance.client?.urlProtocol(protocolInstance, didFailWithError: error)
    }

    func waitUntilStopped(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isStopped, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return isStopped
    }

    fileprivate func markStopped() {
        lock.lock()
        state.stopped = true
        lock.unlock()
    }
}

final class FlightTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let serverLock = NSLock()
    private nonisolated(unsafe) static var server: FlightTestURLProtocolServer?

    private let exchangeLock = NSLock()
    private var exchange: FlightTestURLProtocolExchange?

    static func install(server: FlightTestURLProtocolServer) {
        serverLock.lock()
        self.server = server
        serverLock.unlock()
    }

    static func reset() {
        serverLock.lock()
        server = nil
        serverLock.unlock()
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.serverLock.lock()
        let server = Self.server
        Self.serverLock.unlock()
        guard let server else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "FlightTestURLProtocol",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Server not installed"]
                )
            )
            return
        }

        let recordedExchange = FlightTestURLProtocolExchange(request: request, protocolInstance: self)
        exchangeLock.lock()
        exchange = recordedExchange
        exchangeLock.unlock()
        server.record(recordedExchange)
    }

    override func stopLoading() {
        exchangeLock.lock()
        let exchange = exchange
        exchangeLock.unlock()
        exchange?.markStopped()
    }
}

@MainActor
final class FlightTestAnthropicProvider: AIProviderProtocol, @unchecked Sendable {
    let providerType: AIProvider = .anthropic
    let requiresAPIKey = true

    private var callbacks: AIProviderStreamCallbacks?
    private(set) var isCancelled = false

    func sendMessage(
        messages _: [Message],
        config _: AIProviderRequestConfig,
        stream _: Bool,
        tools _: [[String: Any]]?,
        callbacks: AIProviderStreamCallbacks
    ) {
        self.callbacks = callbacks
    }

    func cancelRequest() {
        isCancelled = true
    }

    func emitChunk(_ chunk: String) {
        callbacks?.onChunk(chunk)
    }

    func emitReasoning(_ reasoning: String) {
        callbacks?.onReasoning?(reasoning)
    }

    func emitToolRequest(name: String) {
        callbacks?.onToolCallRequested?("tool-id", name, [:])
    }

    func complete() {
        callbacks?.onComplete()
    }

    func fail(_ error: Error) {
        callbacks?.onError(error)
    }
}

@MainActor
final class FlightTestAnthropicProviderFactory {
    private(set) var providers: [FlightTestAnthropicProvider] = []

    func makeProvider() -> FlightTestAnthropicProvider {
        let provider = FlightTestAnthropicProvider()
        providers.append(provider)
        return provider
    }
}
