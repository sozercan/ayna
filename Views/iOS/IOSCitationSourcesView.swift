//
//  IOSCitationSourcesView.swift
//  Ayna
//
//  iOS-specific views for displaying inline citation sources with favicons.
//

import SwiftUI

// MARK: - iOS Citation Badge View

/// A small favicon badge that represents a single citation source (iOS version)
struct IOSCitationBadgeView: View {
    let citation: CitationReference
    let size: CGFloat

    init(citation: CitationReference, size: CGFloat = 22) {
        self.citation = citation
        self.size = size
    }

    var body: some View {
        Button(action: openURL) {
            ZStack {
                // Background circle
                Circle()
                    .fill(Theme.textPrimary.opacity(0.1))
                    .frame(width: size, height: size)

                // Favicon or fallback number
                if let faviconURL = citation.favicon, let url = URL(string: faviconURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: size - Spacing.xxs, height: size - Spacing.xxs)
                                .clipShape(Circle())
                        case .failure, .empty:
                            fallbackNumberView
                        @unknown default:
                            fallbackNumberView
                        }
                    }
                } else {
                    fallbackNumberView
                }
            }
            .overlay(
                Circle()
                    .stroke(Theme.textPrimary.opacity(0.2), lineWidth: Spacing.Border.standard)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Source \(citation.number): \(citation.title)")
    }

    private var fallbackNumberView: some View {
        Text("\(citation.number)")
            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            .foregroundColor(Theme.textPrimary)
    }

    private func openURL() {
        guard let url = URL(string: citation.url) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - iOS Citation Sources Footer

/// A collapsible footer that shows all citation sources for a message (iOS version)
struct IOSCitationSourcesFooter: View {
    let citations: [CitationReference]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header button
            Button(action: {
                // Haptic feedback
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()

                withAnimation(Motion.springSnappy) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: Spacing.sm) {
                    // Favicon row (collapsed state) - no overlap
                    if !isExpanded {
                        HStack(spacing: Spacing.xs) {
                            ForEach(citations.prefix(4), id: \.number) { citation in
                                IOSCitationBadgeView(citation: citation, size: 22)
                            }
                            if citations.count > 4 {
                                Text("+\(citations.count - 4)")
                                    .font(Typography.footnote)
                                    .foregroundColor(Theme.textSecondary)
                                    .padding(.leading, Spacing.xxxs)
                            }
                        }
                    }

                    Text("Sources")
                        .font(Typography.captionBold)
                        .foregroundColor(Theme.textSecondary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: Typography.Size.sm, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Theme.textPrimary.opacity(0.05))
                .cornerRadius(Spacing.CornerRadius.md)
            }
            .buttonStyle(PlainButtonStyle())

            // Expanded source list
            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(citations, id: \.number) { citation in
                        IOSCitationSourceRow(citation: citation)
                    }
                }
                .padding(.horizontal, Spacing.xxxs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - iOS Citation Source Row

/// A single row in the expanded sources list (iOS version)
struct IOSCitationSourceRow: View {
    let citation: CitationReference

    var body: some View {
        Button(action: openURL) {
            HStack(spacing: Spacing.lg) {
                // Favicon
                IOSCitationBadgeView(citation: citation, size: 24)

                // Title and domain
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(citation.title)
                        .font(Typography.captionBold)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)

                    if let domain = extractDomain(from: citation.url) {
                        Text(domain)
                            .font(Typography.footnote)
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                Spacer()

                // External link icon
                Image(systemName: "arrow.up.right")
                    .font(.system(size: Typography.Size.sm, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(Theme.textPrimary.opacity(0.03))
            .cornerRadius(Spacing.CornerRadius.md)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Open \(citation.title)")
    }

    private func openURL() {
        guard let url = URL(string: citation.url) else { return }
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        UIApplication.shared.open(url)
    }

    private func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host
        else { return nil }
        // Remove www. prefix if present
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Inline Citation Badges Row (iOS)

/// A horizontal row of citation badges to display inline after message content
struct IOSInlineCitationBadgesView: View {
    let citations: [CitationReference]

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(citations, id: \.number) { citation in
                IOSCitationBadgeView(citation: citation, size: 22)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
    struct IOSCitationSourcesView_Previews: PreviewProvider {
        static var sampleCitations: [CitationReference] = [
            CitationReference(
                number: 1,
                title: "Apple Developer Documentation",
                url: "https://developer.apple.com/documentation",
                favicon: "https://www.apple.com/favicon.ico"
            ),
            CitationReference(
                number: 2,
                title: "Swift.org - The Swift Programming Language",
                url: "https://swift.org",
                favicon: "https://swift.org/favicon.ico"
            ),
            CitationReference(
                number: 3,
                title: "GitHub - SwiftUI Examples",
                url: "https://github.com/swiftui-examples",
                favicon: nil
            )
        ]

        static var previews: some View {
            VStack(spacing: 20) {
                // Individual badges
                HStack {
                    ForEach(sampleCitations, id: \.number) { citation in
                        IOSCitationBadgeView(citation: citation)
                    }
                }

                // Inline badges row
                IOSInlineCitationBadgesView(citations: sampleCitations)

                // Full footer
                IOSCitationSourcesFooter(citations: sampleCitations)
            }
            .padding()
        }
    }
#endif
