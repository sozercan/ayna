# ADR-0008: Provider Request Routing

**Date**: 2026-08-10<br>
**Status**: Accepted<br>
**Context**: Replacing the unused universal provider registry with request-path-specific ownership

## Context

[ADR-0001](0001-multi-provider-architecture.md) proposed that every provider
implement `AIProviderProtocol` and register a long-lived adapter with
`AIService`. The production request paths evolved differently:

- OpenAI-compatible requests, including Azure endpoints, use the request
  builder, endpoint resolver, stream parser, retry policy, and image service
  directly from `AIService`.
- Apple Intelligence uses its dedicated on-device service.
- Anthropic owns a sufficiently different request and streaming lifecycle to
  benefit from a request-scoped provider object.

The OpenAI and Azure protocol adapters and the provider factory were therefore
unused parallel implementations. Keeping them made the documented architecture
disagree with production routing and created a second code path that could
drift from the one exercised by the app.

## Decision

Use request-path-specific provider ownership instead of a universal provider
registry.

### 1. Central model routing

`AIService` remains the facade that resolves each model's effective provider,
credentials, endpoint type, and custom endpoint. It dispatches the request to
the provider family's production path; it does not maintain a registry of
provider adapters.

### 2. OpenAI-compatible requests

OpenAI-compatible chat, Responses API, Azure endpoint, and image requests are
coordinated directly by `AIService` through the focused OpenAI request
components. They do not implement `AIProviderProtocol`.

### 3. Anthropic requests

`AIProviderProtocol` is the request-scoped boundary for Anthropic request
ownership, cancellation, callbacks, and test injection. `AIService` creates an
Anthropic provider per request flight rather than registering a shared global
provider.

### 4. Apple Intelligence requests

Apple Intelligence continues through its dedicated service because its local,
platform-gated execution model does not match a network provider adapter.

### 5. Future providers

A new provider should use the path that matches its API and lifecycle. It may
reuse an existing request path, add focused components, or introduce a
request-scoped protocol boundary when that improves ownership or testability.
Implementing `AIProviderProtocol` is not a blanket requirement.

## Consequences

### Positive

1. **One production path per provider family**: Removes unused implementations
   that could diverge from runtime behavior.
2. **Explicit request ownership**: Anthropic cancellation and callbacks remain
   isolated to the request flight that created the provider.
3. **Focused test seams**: Anthropic keeps protocol-based injection while
   OpenAI-compatible paths test the components used in production.
4. **Provider-native behavior**: Each family can retain its endpoint, streaming,
   tool, reasoning, and platform-specific behavior without a lowest-common-
   denominator registry.

### Negative

1. **Routing knowledge in `AIService`**: The facade must explicitly dispatch
   each provider family.
2. **No uniform extension point**: Adding a provider requires an architectural
   choice instead of only implementing one common protocol.
3. **Protocol name is broader than its current scope**: `AIProviderProtocol`
   remains for compatibility with the Anthropic request boundary.

### Neutral

1. [ADR-0005](0005-anthropic-provider.md) remains accepted; its Anthropic
   parser, builder, and provider decisions operate within this routing model.
2. Multi-model requests continue to resolve and dispatch each model through
   `AIService` independently.

## References

- [Sources/Ayna/Services/AIService.swift](../../Sources/Ayna/Services/AIService.swift)
- [Sources/Ayna/Services/Providers/AIProviderProtocol.swift](../../Sources/Ayna/Services/Providers/AIProviderProtocol.swift)
- [Sources/Ayna/Services/Providers/AnthropicProvider.swift](../../Sources/Ayna/Services/Providers/AnthropicProvider.swift)
- [Sources/Ayna/Services/OpenAIRequestBuilder.swift](../../Sources/Ayna/Services/OpenAIRequestBuilder.swift)
- [Sources/Ayna/Services/OpenAIEndpointResolver.swift](../../Sources/Ayna/Services/OpenAIEndpointResolver.swift)
