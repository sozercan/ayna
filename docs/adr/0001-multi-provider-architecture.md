# ADR-0001: Multi-Provider Architecture

**Date**: 2024-12-01  
**Status**: Accepted  
**Context**: Supporting multiple AI providers (OpenAI, Azure, GitHub Models, Apple Intelligence) with a unified interface  

## Context

Ayna needs to support multiple AI providers to give users flexibility in choosing their preferred service. Each provider has different:

- Authentication mechanisms (API keys, OAuth, system integration)
- API endpoints and request formats
- Streaming response formats
- Model availability and capabilities
- Rate limits and error handling

We needed an architecture that allows:
1. Easy addition of new providers
2. Consistent UX across providers
3. Multi-model chat (comparing responses from different models)
4. Platform-specific providers (e.g., AIKit on macOS only)

## Decision

Implement a protocol-based provider architecture:

### 1. AIProviderProtocol

All providers implement a common protocol:

```swift
protocol AIProviderProtocol: Sendable {
    var id: String { get }
    var name: String { get }
    var isAvailable: Bool { get async }
    
    func sendMessage(_ messages: [Message], model: String) async throws -> AsyncThrowingStream<String, Error>
    func cancelCurrentRequest()
}
```

### 2. Provider Registry

`OpenAIService` acts as the coordinator, maintaining a registry of providers:

```swift
@MainActor @Observable
final class OpenAIService {
    private var providers: [String: any AIProviderProtocol] = [:]
    
    func registerProvider(_ provider: any AIProviderProtocol)
    func provider(for id: String) -> (any AIProviderProtocol)?
}
```

### 3. Platform-Specific Providers

Use `#if os()` guards for platform-specific providers:

```swift
#if os(macOS)
import AIKit
// AIKit provider implementation
#endif
```

### 4. Endpoint Resolution

`OpenAIEndpointResolver` handles provider-specific URL construction:

```swift
struct OpenAIEndpointResolver {
    static func resolve(for provider: AIProvider, model: String) -> URL
}
```

## Consequences

### Positive

1. **Extensibility**: Adding a new provider requires only implementing `AIProviderProtocol`
2. **Testability**: Protocols enable easy mocking in tests
3. **Consistency**: Unified interface for all providers
4. **Multi-model chat**: Same message can be sent to multiple providers simultaneously
5. **Platform isolation**: Platform-specific code is cleanly separated

### Negative

1. **Abstraction overhead**: Some provider-specific features may not map cleanly to the protocol
2. **Lowest common denominator**: Protocol must accommodate the least capable provider
3. **Error translation**: Each provider's errors must be translated to `AynaError`

### Neutral

1. **Provider-specific settings**: Handled separately in `AppPreferences`
2. **Model lists**: Each provider maintains its own model list
3. **Streaming formats**: Abstracted behind `AsyncThrowingStream`

## References

- [Core/Services/Providers/AIProviderProtocol.swift](../../Core/Services/Providers/AIProviderProtocol.swift)
- [Core/Services/OpenAIService.swift](../../Core/Services/OpenAIService.swift)
- [Core/Services/OpenAIEndpointResolver.swift](../../Core/Services/OpenAIEndpointResolver.swift)
