# Memory Integration Plan for Ayna

> **Status**: Draft (Revised)  
> **Created**: December 25, 2025  
> **Revised**: December 25, 2025  
> **Based on**: [Reverse engineering of ChatGPT's memory system](https://manthanguptaa.in/posts/chatgpt_memory/)

---

## Executive Summary

This plan outlines how to integrate a ChatGPT-like memory system into Ayna. The goal is to provide users with a personalized, context-aware chat experience across sessions without the complexity and latency of traditional RAG systems.

ChatGPT's memory architecture uses **four distinct layers**:
1. **Session Metadata** — Ephemeral context about the current environment
2. **User Memory** — Long-term facts explicitly stored about the user
3. **Recent Conversations Summary** — Lightweight digests of recent chats
4. **Current Session Messages** — Sliding window of the active conversation

This approach is **simpler and more efficient than RAG**, trading detailed historical context for speed and token efficiency.

---

## Key Design Decisions

### Session vs. Conversation Semantics

In ChatGPT, a "session" maps to a single chat thread. In Ayna, users frequently switch between persistent conversations. We define:

- **Current Session** = The currently active `Conversation` (full message history loaded)
- **Recent Conversations** = All *other* recently modified conversations (candidates for summarization)
- **Session boundary** = When the user switches to a different conversation or closes the app

This means if you open an old conversation, it becomes the "Current Session" and its messages are sent in full, while your *other* recent conversations appear in the summary layer.

### Hybrid Trigger Approach (Regex + Optional Tool)

For detecting memory commands ("Remember that..."), we use a **hybrid approach**:

1. **Primary: Regex matching** — Fast, works offline, no extra API calls
2. **Optional enhancement: `manage_memory` tool** — For models that support function calling

**Why not tool-only?**
- Apple Intelligence and some local models don't support tools
- Regex for explicit phrases like "remember that" is highly reliable (users are intentional)
- Tool calls add latency and cost for a simple CRUD operation
- We can always upgrade to tool-first later without breaking changes

---

## Architecture Overview

### Proposed Layer Structure for Ayna

```
┌─────────────────────────────────────────────────────────┐
│                    CONTEXT INJECTION                    │
├─────────────────────────────────────────────────────────┤
│ [0] System Instructions (existing: systemPromptMode)    │
│ [1] Session Metadata (NEW - ephemeral)                  │
│ [2] User Memory Facts (NEW - persistent)                │
│ [3] Recent Conversations Summary (NEW - computed)       │
│ [4] Current Session Messages (existing: conversation)   │
│ [5] Latest User Message                                 │
└─────────────────────────────────────────────────────────┘
```

---

## Phase 1: User Memory (Long-term Facts)

### 1.1 Data Model

Create a new model for storing user memory facts:

```swift
// Core/Models/UserMemory.swift

struct UserMemoryFact: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var content: String           // The actual fact
    var category: MemoryCategory  // Categorization for organization
    var source: MemorySource      // How this fact was added
    var createdAt: Date
    var updatedAt: Date
    var isActive: Bool            // Soft delete support
    
    enum MemoryCategory: String, Codable, CaseIterable, Sendable {
        case personal       // Name, age, location
        case professional   // Job, company, skills
        case preferences    // Likes, dislikes, communication style
        case projects       // Current work, side projects
        case interests      // Hobbies, learning goals
        case other
    }
    
    enum MemorySource: String, Codable, Sendable {
        case explicit       // User said "remember this"
        case inferred       // Model detected stable fact
        case imported       // Bulk import
    }
}

struct UserMemoryStore: Codable, Sendable {
    var facts: [UserMemoryFact]
    var lastUpdated: Date
    var version: Int  // For migration
}
```

### 1.2 Memory Service

Create a service to manage memory operations:

```swift
// Core/Services/UserMemoryService.swift

@MainActor
@Observable
final class UserMemoryService {
    private(set) var facts: [UserMemoryFact] = []
    private let store: EncryptedMemoryStore
    
    // CRUD Operations
    func addFact(_ content: String, category: MemoryCategory, source: MemorySource)
    func updateFact(_ id: UUID, content: String)
    func deleteFact(_ id: UUID)
    func toggleFact(_ id: UUID, active: Bool)
    
    // Query
    func activeFacts() -> [UserMemoryFact]
    func facts(in category: MemoryCategory) -> [UserMemoryFact]
    
    // Format for injection
    func formattedForContext() -> String
    
    // AI-assisted operations
    func extractFacts(from message: String) async -> [String]
    func shouldStoreFact(_ content: String) async -> Bool
}
```

### 1.3 Storage

Extend the encrypted storage pattern for memory:

```swift
// Core/Services/EncryptedMemoryStore.swift

final class EncryptedMemoryStore: Sendable {
    static let shared = EncryptedMemoryStore()
    
    // Same encryption pattern as EncryptedConversationStore
    // Store at: Application Support/Ayna/UserMemory/memory.enc
    
    func load() async throws -> UserMemoryStore
    func save(_ store: UserMemoryStore) async throws
    func clear() throws
}
```

### 1.4 Trigger Commands

Detect explicit memory commands in user messages:

| Command Pattern | Action |
|-----------------|--------|
| "Remember that..." | Store the following as a fact |
| "Store in memory..." | Store the following as a fact |
| "Forget that..." | Remove matching fact |
| "Delete from memory..." | Remove matching fact |
| "What do you remember about me?" | List stored facts |
| "Clear my memory" | Clear all facts (with confirmation) |

### 1.5 Automatic Fact Extraction (Optional, Async)

For inferred facts, use the model to detect stable information. **This runs asynchronously to avoid blocking the user.**

#### Extraction Strategy

- **Trigger**: After conversation idle for 2+ minutes, OR when app goes to background
- **Batch processing**: Queue messages, process in batch (not per-message)
- **User consent**: Opt-in feature, disabled by default
- **No blocking**: Never delay the user's next message

```swift
// Core/Services/FactExtractionQueue.swift

actor FactExtractionQueue {
    private var pendingMessages: [(conversationId: UUID, content: String)] = []
    private var extractionTask: Task<Void, Never>?
    private let idleThreshold: Duration = .seconds(120)
    
    func enqueue(conversationId: UUID, message: String) {
        pendingMessages.append((conversationId, message))
        scheduleExtraction()
    }
    
    private func scheduleExtraction() {
        extractionTask?.cancel()
        extractionTask = Task {
            try? await Task.sleep(for: idleThreshold)
            guard !Task.isCancelled else { return }
            await processPendingMessages()
        }
    }
    
    private func processPendingMessages() async {
        let batch = pendingMessages
        pendingMessages.removeAll()
        // Process batch with LLM...
    }
}
```

#### Extraction Prompt

```swift
let extractionPrompt = """
Analyze this message for stable, long-term facts about the user.
Only extract facts that are:
1. Personal identifiers (name, location, job title)
2. Stated preferences (coding style, communication preferences)
3. Ongoing projects or goals
4. Background information (education, experience)

Do NOT extract:
- Temporary states or moods
- Opinions about specific topics
- Questions or requests

Return JSON array of facts or empty array if none found.
"""
```

---

## Phase 2: Recent Conversations Summary

### 2.1 Summary Model

```swift
// Core/Models/ConversationSummary.swift

struct ConversationSummary: Identifiable, Codable, Sendable {
    let id: UUID                    // Matches conversation ID
    var title: String
    var timestamp: Date
    var userMessageSnippets: [String]  // Key user messages (not assistant)
    var topics: [String]            // Extracted topics/keywords
}

struct RecentConversationsDigest: Codable, Sendable {
    var summaries: [ConversationSummary]
    var lastComputed: Date
    var maxSummaries: Int = 15      // Match ChatGPT's ~15 summary limit
}
```

### 2.2 Summary Service

```swift
// Core/Services/ConversationSummaryService.swift

@MainActor
@Observable
final class ConversationSummaryService {
    private(set) var digest: RecentConversationsDigest
    
    // Generate summary for a conversation
    func generateSummary(for conversation: Conversation) async -> ConversationSummary
    
    // Update digest when conversations change
    func updateDigest(conversations: [Conversation]) async
    
    // Format for context injection
    func formattedForContext() -> String
    
    // Prune old summaries
    func pruneOldSummaries(keeping: Int)
}
```

### 2.3 Summary Format

Following ChatGPT's format:

```
Recent Conversations:
1. Dec 24, 2025: SwiftUI Animation Help
   |||| How do I animate a view transition? ||||
   |||| Can you make it spring-based? ||||

2. Dec 23, 2025: API Integration Questions
   |||| Need help with async/await patterns ||||
```

### 2.4 Summary Generation Strategy

- **When**: After conversation idle for 5+ minutes, OR when switching away from conversation
- **What to summarize**: Only user messages (not assistant responses)
- **Length**: 2-3 key snippets per conversation
- **Storage**: Computed and cached, regenerated on demand
- **Async**: Never block the active conversation; use background queue

#### Async Summarization Queue

```swift
// Core/Services/SummarizationQueue.swift

actor SummarizationQueue {
    private var pendingConversations: Set<UUID> = []
    private var debounceTask: Task<Void, Never>?
    private let debounceDuration: Duration = .seconds(300)  // 5 minutes
    
    func markNeedsSummary(_ conversationId: UUID) {
        pendingConversations.insert(conversationId)
        scheduleProcessing()
    }
    
    private func scheduleProcessing() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: debounceDuration)
            guard !Task.isCancelled else { return }
            await processPending()
        }
    }
    
    private func processPending() async {
        let batch = pendingConversations
        pendingConversations.removeAll()
        for id in batch {
            await generateSummary(for: id)
        }
    }
}
```

### 2.5 Bootstrap / Backfill

When a user first enables memory, they have 0 summaries. To provide immediate value:

```swift
// Run once when memory is first enabled
func backfillSummaries(from conversations: [Conversation], limit: Int = 10) async {
    let recent = conversations
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(limit)
    
    for conversation in recent {
        await summaryService.generateSummary(for: conversation)
    }
}
```

This ensures the feature feels "alive" immediately rather than requiring weeks of usage.

---

## Phase 3: Session Metadata (Ephemeral)

### 3.1 Metadata Model

```swift
// Core/Models/SessionMetadata.swift

struct SessionMetadata: Codable, Sendable {
    let deviceType: DeviceType
    let platform: Platform
    let appVersion: String
    let localTime: Date
    let timezone: TimeZone
    let isDarkMode: Bool
    let conversationPatterns: ConversationPatterns?
    
    enum DeviceType: String, Codable, Sendable {
        case desktop, tablet, phone, watch
    }
    
    enum Platform: String, Codable, Sendable {
        case macOS, iOS, watchOS
    }
    
    struct ConversationPatterns: Codable, Sendable {
        var averageMessageLength: Int?
        var averageConversationDepth: Int?
        var recentActivityDays: Int?
        var preferredModels: [String: Double]?  // Model -> usage percentage
    }
}
```

### 3.2 Metadata Collector

```swift
// Core/Services/SessionMetadataService.swift

@MainActor
final class SessionMetadataService {
    func collectMetadata() -> SessionMetadata
    func formattedForContext() -> String
    
    // Privacy: Allow users to opt-out of metadata collection
    var isEnabled: Bool { get set }
}
```

### 3.3 Privacy Considerations

- **No personal data** — Only device/environment info
- **User control** — Toggle in Settings to disable
- **Not persisted** — Generated fresh each session
- **Minimal footprint** — Small token overhead (~100-200 tokens)

---

## Phase 4: Context Injection Pipeline

### 4.1 Context Builder

Modify `OpenAIRequestBuilder` to inject memory context:

```swift
// Core/Services/OpenAIRequestBuilder.swift (modification)

extension OpenAIRequestBuilder {
    func buildMessagesWithMemory(
        systemPrompt: String?,
        sessionMetadata: SessionMetadata?,
        userMemory: String?,
        conversationsSummary: String?,
        conversationHistory: [Message],
        userMessage: Message
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        
        // [0] System prompt (existing)
        if let system = systemPrompt {
            messages.append(["role": "system", "content": system])
        }
        
        // [1] Session metadata (if enabled)
        if let metadata = sessionMetadata {
            let metadataContent = formatSessionMetadata(metadata)
            messages.append(["role": "system", "content": metadataContent])
        }
        
        // [2] User memory facts (if any)
        if let memory = userMemory, !memory.isEmpty {
            let memoryContent = "User Memory:\n\(memory)"
            messages.append(["role": "system", "content": memoryContent])
        }
        
        // [3] Recent conversations summary (if any)
        if let summary = conversationsSummary, !summary.isEmpty {
            let summaryContent = "Recent Conversations:\n\(summary)"
            messages.append(["role": "system", "content": summaryContent])
        }
        
        // [4] Current conversation history (existing)
        messages.append(contentsOf: formatConversationHistory(conversationHistory))
        
        // [5] Latest user message (existing)
        messages.append(formatMessage(userMessage))
        
        return messages
    }
}
```

### 4.2 Dynamic Token Budget Management

Token budgets should adapt to the model's context window. For smaller models, we progressively drop layers.

```swift
struct ContextTokenBudget {
    let modelContextWindow: Int
    
    // Fixed allocations
    static let reservedForResponse = 4000
    static let sessionMetadataMax = 200
    static let userMemoryMax = 1000
    static let conversationSummaryMax = 500
    
    /// Calculate available budget for each layer based on model context
    func allocate() -> ContextAllocation {
        let available = modelContextWindow - Self.reservedForResponse
        
        // For small context models (< 8K), drop summaries entirely
        if available < 8000 {
            return ContextAllocation(
                sessionMetadata: min(100, available / 20),
                userMemory: min(500, available / 8),
                conversationSummary: 0,  // Dropped
                conversationHistory: available - 600
            )
        }
        
        // For medium context (8K-32K), reduce allocations
        if available < 32000 {
            return ContextAllocation(
                sessionMetadata: 150,
                userMemory: 750,
                conversationSummary: 300,
                conversationHistory: available - 1200
            )
        }
        
        // Large context models get full allocations
        return ContextAllocation(
            sessionMetadata: Self.sessionMetadataMax,
            userMemory: Self.userMemoryMax,
            conversationSummary: Self.conversationSummaryMax,
            conversationHistory: available - 1700
        )
    }
}

struct ContextAllocation {
    let sessionMetadata: Int
    let userMemory: Int
    let conversationSummary: Int
    let conversationHistory: Int
}
```

This ensures memory doesn't crowd out conversation history on smaller models.

---

## Phase 5: User Interface

### 5.1 Memory Settings View

```
Settings > Memory
├── Enable Memory [Toggle]
├── Session Metadata [Toggle]
│   └── "Allows personalized responses based on your environment"
├── Stored Facts [Count: 33]
│   └── [View & Manage Facts]
├── Conversation Summaries [Count: 15]
│   └── [View Summaries]
└── Clear All Memory [Button - Destructive]
```

### 5.2 Memory Management View

```swift
// Views/macOS/Settings/MemorySettingsView.swift
// Views/iOS/Settings/MemorySettingsView.swift

struct MemorySettingsView: View {
    @Environment(UserMemoryService.self) var memoryService
    
    var body: some View {
        List {
            Section("Stored Facts") {
                ForEach(memoryService.facts) { fact in
                    MemoryFactRow(fact: fact)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                memoryService.deleteFact(fact.id)
                            }
                        }
                }
            }
        }
    }
}
```

### 5.3 In-Chat Memory Indicator

Show when memory is being used:

```swift
// Small indicator in chat header
HStack {
    Image(systemName: "brain")
    Text("\(memoryService.facts.count) facts")
}
.font(.caption2)
.foregroundStyle(.secondary)
```

### 5.4 Debug Context View (Developer Mode)

For debugging and transparency, add a "View Injected Context" option:

```swift
// Available in message context menu (long-press) when developer mode enabled
struct DebugContextView: View {
    let injectedContext: InjectedContextSnapshot
    
    var body: some View {
        List {
            Section("Session Metadata") {
                Text(injectedContext.sessionMetadata ?? "None")
                    .font(.caption)
            }
            Section("User Memory (\(injectedContext.factCount) facts)") {
                Text(injectedContext.userMemory ?? "None")
                    .font(.caption)
            }
            Section("Conversation Summaries") {
                Text(injectedContext.summaries ?? "None")
                    .font(.caption)
            }
            Section("Token Usage") {
                LabeledContent("Memory overhead", value: "\(injectedContext.memoryTokens)")
                LabeledContent("Conversation", value: "\(injectedContext.conversationTokens)")
                LabeledContent("Total", value: "\(injectedContext.totalTokens)")
            }
        }
    }
}
```

This helps users understand *why* the model responded a certain way and aids debugging during development.

---

## Phase 6: Cross-Platform Considerations

| Feature | macOS | iOS | watchOS |
|---------|:-----:|:---:|:-------:|
| User Memory Storage | ✅ | ✅ | ✅ (synced) |
| Memory Management UI | ✅ | ✅ | ❌ (manage on phone) |
| Session Metadata | ✅ | ✅ | ✅ (minimal) |
| Conversation Summaries | ✅ | ✅ | ✅ (synced) |
| Explicit Commands | ✅ | ✅ | ✅ |
| Automatic Extraction | ✅ | ✅ | ❌ (battery) |

### watchOS Sync Strategy

- Memory synced via `WatchConnectivityService`
- Read-only on watch; management on iPhone
- Summaries computed on phone, synced to watch

### Conflict Resolution Strategy

Since `UserMemoryFact`s may be modified on multiple devices, we need a conflict strategy:

**Last Write Wins (LWW)** — Based on `updatedAt` timestamp

```swift
func reconcile(local: UserMemoryFact, remote: UserMemoryFact) -> UserMemoryFact {
    // Same fact (by ID), different content
    return local.updatedAt > remote.updatedAt ? local : remote
}

func mergeStores(local: UserMemoryStore, remote: UserMemoryStore) -> UserMemoryStore {
    var merged: [UUID: UserMemoryFact] = [:]
    
    // Add all local facts
    for fact in local.facts {
        merged[fact.id] = fact
    }
    
    // Merge remote facts (LWW)
    for fact in remote.facts {
        if let existing = merged[fact.id] {
            merged[fact.id] = reconcile(local: existing, remote: fact)
        } else {
            merged[fact.id] = fact
        }
    }
    
    return UserMemoryStore(
        facts: Array(merged.values),
        lastUpdated: max(local.lastUpdated, remote.lastUpdated),
        version: max(local.version, remote.version)
    )
}
```

**Why LWW?**
- Facts are individual records with UUIDs, so conflicts are rare
- The last edit is almost always the "correct" one (user updating info)
- Simple to implement and reason about
- Alternative (CRDT) is overkill for ~50-100 text facts

---

## Implementation Phases

> **Note**: Phase 1 and Phase 2 are tightly coupled—memory is only useful once it can be injected into context. These should be treated as a single deliverable milestone.

### Phase 1: Foundation (Week 1)
- [ ] Create `UserMemoryFact` and `UserMemoryStore` models
- [ ] Implement `EncryptedMemoryStore` for persistence
- [ ] Create `UserMemoryService` with CRUD operations
- [ ] Add explicit command detection ("remember this", "forget that")
- [ ] Unit tests for memory service

### Phase 2: Context Injection (Week 1-2)
- [ ] Modify `OpenAIRequestBuilder` to accept memory context
- [ ] Create `MemoryContextFormatter` utility
- [ ] Integrate with `OpenAIService.sendMessage`
- [ ] Add dynamic token budget management
- [ ] Integration tests
- [ ] **Milestone: End-to-end "remember this" working**

### Phase 3: Conversation Summaries (Week 2-3)
- [ ] Create `ConversationSummary` model
- [ ] Implement `ConversationSummaryService`
- [ ] Add `SummarizationQueue` for async processing
- [ ] Add summary generation (AI-assisted or rule-based)
- [ ] Implement backfill for existing conversations
- [ ] Integrate summaries into context pipeline

### Phase 4: UI & Settings (Week 3)
- [ ] Create `MemorySettingsView` for macOS
- [ ] Create `MemorySettingsView` for iOS
- [ ] Add memory indicator to chat views
- [ ] Implement memory management (view, edit, delete facts)
- [ ] Add debug context view (developer mode)
- [ ] UI tests

### Phase 5: Session Metadata (Week 4)
- [ ] Create `SessionMetadata` model
- [ ] Implement `SessionMetadataService`
- [ ] Add opt-out toggle in settings
- [ ] Platform-specific collectors
- [ ] Privacy review

### Phase 6: Polish & Cross-Platform (Week 4-5)
- [ ] watchOS sync via `WatchConnectivityService`
- [ ] Conflict resolution (LWW merge)
- [ ] `FactExtractionQueue` for automatic extraction (opt-in)
- [ ] Performance optimization
- [ ] Documentation
- [ ] Full test coverage

---

## Token Budget Analysis

Based on ChatGPT's approach and typical context windows. With dynamic budgeting, memory overhead adapts to model capabilities.

| Model | Context | Memory Budget | Conversation Budget | Notes |
|-------|---------|---------------|---------------------|-------|
| GPT-4o | 128K | ~1,700 tokens | ~120K tokens | Full allocation |
| GPT-4o-mini | 128K | ~1,700 tokens | ~120K tokens | Full allocation |
| Claude 3.5 | 200K | ~1,700 tokens | ~195K tokens | Full allocation |
| GPT-3.5 | 16K | ~1,200 tokens | ~10K tokens | Reduced summaries |
| Local/Small | 4-8K | ~600 tokens | ~3-6K tokens | No summaries |

Memory overhead is minimal compared to available context, and scales down gracefully.

---

## Privacy & Security

1. **Encryption**: All memory stored using existing AES-GCM encryption (same as conversations)
2. **Local-first**: No memory data sent to servers except within API requests
3. **User control**: 
   - Toggle memory on/off
   - View all stored facts
   - Delete individual facts or clear all
   - Export memory data
4. **No automatic PII extraction** without explicit consent
5. **Session metadata** contains no personal data

---

## Alternatives Considered

### 1. Full RAG with Vector Database
**Rejected because:**
- High complexity (embedding generation, vector storage, similarity search)
- Additional latency for retrieval
- Overkill for most use cases
- Hard to run locally on all platforms (especially watchOS)

### 2. Full Conversation History Injection
**Rejected because:**
- Quickly exceeds token limits
- High API costs
- Most historical context is not relevant

### 3. No Memory (Current State)
**Rejected because:**
- Users want personalization
- Repeated context-setting is frustrating
- Competitive disadvantage vs ChatGPT

---

## Success Metrics

1. **User Adoption**: % of users with memory enabled after 30 days
2. **Fact Retention**: Average facts stored per active user
3. **Token Efficiency**: Memory overhead as % of total context
4. **User Satisfaction**: Qualitative feedback on personalization

---

## Open Questions

1. ~~**Sync**: Should memory sync via CloudKit like conversations?~~ **Resolved**: Yes, use existing CloudKit infrastructure
2. ~~**Multi-device**: How to handle conflicting facts across devices?~~ **Resolved**: Last Write Wins based on `updatedAt`
3. **Model-specific memory**: Should different models see different facts? *(Recommendation: No, keep it simple. Same facts for all models.)*
4. **Memory limits**: Cap on number of facts? *(Recommendation: Soft limit of 100 facts, warn user when approaching)*
5. ~~**Automatic extraction**: Enable by default or opt-in?~~ **Resolved**: Opt-in, disabled by default
6. **Memory export/import**: Should users be able to export their memory as JSON for backup/portability?

---

## References

- [ChatGPT Memory System Analysis](https://manthanguptaa.in/posts/chatgpt_memory/)
- [Claude Memory System Analysis](https://manthanguptaa.in/posts/claude_memory/)
- [OpenAI Memory Documentation](https://help.openai.com/en/articles/8590148-what-is-chatgpt-s-memory-feature)
- [Ayna Architecture](./architecture.md)

---

## Appendix: Example Context Structure

```
[System Prompt]
You are a helpful assistant...

[Session Metadata]
Session Info:
- Platform: macOS (desktop)
- Local time: 2:30 PM PST
- App version: 1.5.0
- Average message length: ~200 chars

[User Memory]
User Facts:
- User's name is Alex
- Works as a Senior iOS Developer at TechCorp
- Prefers Swift over Objective-C
- Currently learning SwiftUI
- Uses VS Code for non-iOS projects
- Timezone: PST (UTC-8)

[Recent Conversations]
1. Dec 24: SwiftUI Animation
   |||| How to animate view transitions ||||
2. Dec 23: Core Data Migration
   |||| Best practices for lightweight migration ||||

[Current Conversation]
User: How do I implement a custom TabView?
Assistant: Here's how to create a custom TabView...
User: Can you add animation to the tab switching?
```
