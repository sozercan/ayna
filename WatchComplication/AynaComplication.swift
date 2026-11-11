//
//  AynaComplication.swift
//  Ayna Watch Complication
//
//  A launcher complication: it shows the Ayna glyph and opens the app when tapped. It reads no
//  app data, so it needs no App Group.
//

import SwiftUI
import WidgetKit

struct LauncherEntry: TimelineEntry {
    let date: Date
}

struct LauncherProvider: TimelineProvider {
    func placeholder(in _: Context) -> LauncherEntry {
        LauncherEntry(date: .now)
    }

    func getSnapshot(in _: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        // Static content: nothing to refresh.
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

struct LauncherView: View {
    @Environment(\.widgetFamily) private var family

    private let symbol = "bubble.left.and.text.bubble.right.fill"

    var body: some View {
        content
            .containerBackground(for: .widget) {}
            .accessibilityLabel("Open Ayna")
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3)
                VStack(alignment: .leading) {
                    Text("Ayna")
                        .font(.headline)
                    Text("New chat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            Label("Ayna", systemImage: symbol)
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title3)
                .widgetLabel("Ayna")
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol)
                    .font(.title3)
            }
        }
    }
}

@main
struct AynaLauncherComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AynaLauncher", provider: LauncherProvider()) { _ in
            LauncherView()
        }
        .configurationDisplayName("Ayna")
        .description("Opens Ayna.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}
