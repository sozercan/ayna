//
//  AynaComplication.swift
//  Ayna Watch App
//
//  Watch complication providing quick access to Ayna chat.
//

#if os(watchOS)

    import SwiftUI
    import WidgetKit

    // MARK: - Timeline Entry

    /// Entry representing the complication's data at a point in time
    struct AynaComplicationEntry: TimelineEntry {
        let date: Date
        let conversationCount: Int
        let lastConversationTitle: String?
    }

    // MARK: - Timeline Provider

    /// Provides timeline entries for the complication
    struct AynaComplicationProvider: TimelineProvider {
        func placeholder(in _: Context) -> AynaComplicationEntry {
            AynaComplicationEntry(
                date: Date(),
                conversationCount: 0,
                lastConversationTitle: nil
            )
        }

        func getSnapshot(in _: Context, completion: @escaping (AynaComplicationEntry) -> Void) {
            // For snapshot, provide sample data
            let entry = AynaComplicationEntry(
                date: Date(),
                conversationCount: 3,
                lastConversationTitle: "Planning meeting"
            )
            completion(entry)
        }

        func getTimeline(in _: Context, completion: @escaping (Timeline<AynaComplicationEntry>) -> Void) {
            // Load conversation data from UserDefaults (shared with main app)
            let conversationData = loadConversationData()

            let entry = AynaComplicationEntry(
                date: Date(),
                conversationCount: conversationData.count,
                lastConversationTitle: conversationData.lastTitle
            )

            // Refresh every 15 minutes
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
            let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
            completion(timeline)
        }

        private func loadConversationData() -> (count: Int, lastTitle: String?) {
            let persistenceKey = "com.sertacozercan.ayna.watch.conversations"
            guard let data = UserDefaults.standard.data(forKey: persistenceKey) else {
                return (0, nil)
            }

            do {
                let conversations = try JSONDecoder().decode([ComplicationConversation].self, from: data)
                let lastTitle = conversations.first?.title
                return (conversations.count, lastTitle)
            } catch {
                return (0, nil)
            }
        }
    }

    // MARK: - Minimal Data Model for Complication

    /// Minimal conversation model for decoding in complication (avoids Core dependencies)
    private struct ComplicationConversation: Codable {
        let id: UUID
        let title: String
    }

    // MARK: - Complication Views

    /// Circular complication view - shows app icon
    struct AynaCircularComplicationView: View {
        var entry: AynaComplicationEntry

        var body: some View {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .widgetAccentable()
        }
    }

    /// Corner complication view - shows icon with optional count
    struct AynaCornerComplicationView: View {
        var entry: AynaComplicationEntry

        var body: some View {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 20, weight: .medium))
                .widgetAccentable()
                .widgetLabel {
                    if entry.conversationCount > 0 {
                        Text("\(entry.conversationCount) chats")
                    } else {
                        Text("Ayna")
                    }
                }
        }
    }

    /// Rectangular complication view - shows last conversation or prompt to start
    struct AynaRectangularComplicationView: View {
        var entry: AynaComplicationEntry

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.cyan)
                    .widgetAccentable()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Ayna")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if let lastTitle = entry.lastConversationTitle {
                        Text(lastTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Start a new chat")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    /// Inline complication view - shows text only
    struct AynaInlineComplicationView: View {
        var entry: AynaComplicationEntry

        var body: some View {
            if entry.conversationCount > 0 {
                Label("\(entry.conversationCount) chats", systemImage: "bubble.left.and.bubble.right.fill")
            } else {
                Label("Ayna", systemImage: "bubble.left.and.bubble.right.fill")
            }
        }
    }

    // MARK: - Widget Configuration

    /// Main widget/complication configuration
    struct AynaComplication: Widget {
        let kind: String = "AynaComplication"

        var body: some WidgetConfiguration {
            StaticConfiguration(kind: kind, provider: AynaComplicationProvider()) { entry in
                AynaComplicationEntryView(entry: entry)
            }
            .configurationDisplayName("Ayna")
            .description("Quick access to Ayna chat.")
            .supportedFamilies([
                .accessoryCircular,
                .accessoryCorner,
                .accessoryRectangular,
                .accessoryInline
            ])
        }
    }

    /// Entry view that renders appropriate complication based on family
    struct AynaComplicationEntryView: View {
        @Environment(\.widgetFamily) var widgetFamily
        var entry: AynaComplicationEntry

        var body: some View {
            switch widgetFamily {
            case .accessoryCircular:
                AynaCircularComplicationView(entry: entry)
            case .accessoryCorner:
                AynaCornerComplicationView(entry: entry)
            case .accessoryRectangular:
                AynaRectangularComplicationView(entry: entry)
            case .accessoryInline:
                AynaInlineComplicationView(entry: entry)
            @unknown default:
                AynaCircularComplicationView(entry: entry)
            }
        }
    }

    // MARK: - Preview

    #if DEBUG
        #Preview("Circular", as: .accessoryCircular) {
            AynaComplication()
        } timeline: {
            AynaComplicationEntry(date: Date(), conversationCount: 3, lastConversationTitle: "Planning meeting")
        }

        #Preview("Corner", as: .accessoryCorner) {
            AynaComplication()
        } timeline: {
            AynaComplicationEntry(date: Date(), conversationCount: 5, lastConversationTitle: nil)
        }

        #Preview("Rectangular", as: .accessoryRectangular) {
            AynaComplication()
        } timeline: {
            AynaComplicationEntry(date: Date(), conversationCount: 2, lastConversationTitle: "Help with Swift")
        }

        #Preview("Inline", as: .accessoryInline) {
            AynaComplication()
        } timeline: {
            AynaComplicationEntry(date: Date(), conversationCount: 0, lastConversationTitle: nil)
        }
    #endif

#endif
