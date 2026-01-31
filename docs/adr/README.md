# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the Ayna project.

## What is an ADR?

An ADR is a document that captures an important architectural decision made along with its context and consequences. ADRs help:

- **Preserve context** for why decisions were made
- **Onboard new team members** (including AI agents) faster
- **Avoid repeating discussions** about past decisions
- **Document trade-offs** considered during design

## Format

Each ADR follows this format:

```markdown
# ADR-NNNN: Title

**Date**: YYYY-MM-DD  
**Status**: Proposed | Accepted | Deprecated | Superseded by ADR-XXXX  
**Context**: Brief description of what prompted this decision  

## Context

What is the issue that we're seeing that is motivating this decision?

## Decision

What is the change that we're proposing and/or doing?

## Consequences

### Positive
What becomes easier because of this change?

### Negative
What becomes more difficult because of this change?

### Neutral
What trade-offs are we accepting?
```

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-multi-provider-architecture.md) | Multi-Provider Architecture | Accepted |
| [0002](0002-encrypted-conversation-storage.md) | Encrypted Conversation Storage | Accepted |
| [0003](0003-cross-platform-core.md) | Cross-Platform Core Module | Accepted |
| [0004](0004-sparkle-auto-updates.md) | Sparkle Auto-Updates | Accepted |
| [0005](0005-anthropic-provider.md) | Anthropic Provider Architecture | Accepted |

## When to Create an ADR

Create an ADR when making decisions about:

- **New provider integrations** (e.g., adding a new AI provider)
- **Data storage changes** (encryption, persistence strategy)
- **Cross-platform architecture** (what goes in Core vs. platform-specific)
- **Concurrency patterns** (actor isolation, MainActor usage)
- **Security decisions** (Keychain storage, data protection)
- **Major refactors** (service protocols, dependency injection)

## Naming Convention

- Use sequential numbers: `0001`, `0002`, etc.
- Use lowercase with hyphens: `0001-descriptive-title.md`
- Keep titles concise but descriptive
