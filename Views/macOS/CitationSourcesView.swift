//
//  CitationSourcesView.swift
//  Ayna
//
//  Displays inline citation sources with favicons for web search results.
//

import SwiftUI

// MARK: - Citation Badge View

/// A small favicon badge that represents a single citation source
struct CitationBadgeView: View {
    let citation: CitationReference
    let size: CGFloat

    @State private var isHovered = false

    init(citation: CitationReference, size: CGFloat = 20) {
        self.citation = citation
        self.size = size
    }

    var body: some View {
        Button(action: openURL) {
            ZStack {
                // Background circle
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: size, height: size)

                // Favicon or fallback number
                if let faviconURL = citation.favicon, let url = URL(string: faviconURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: size - 4, height: size - 4)
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
                    .stroke(Color.white.opacity(isHovered ? 0.4 : 0.2), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.1 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(citation.title)
        .accessibilityLabel("Source \(citation.number): \(citation.title)")
    }

    private var fallbackNumberView: some View {
        Text("\(citation.number)")
            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
    }

    private func openURL() {
        guard let url = URL(string: citation.url) else { return }
        #if os(macOS)
            NSWorkspace.shared.open(url)
        #elseif os(iOS)
            UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Citation Sources Footer

/// A collapsible footer that shows all citation sources for a message
struct CitationSourcesFooter: View {
    let citations: [CitationReference]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header button
            Button(action: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    // Favicon row (collapsed state) - no overlap
                    if !isExpanded {
                        HStack(spacing: 6) {
                            ForEach(citations.prefix(5), id: \.number) { citation in
                                CitationBadgeView(citation: citation, size: 20)
                            }
                            if citations.count > 5 {
                                Text("+\(citations.count - 5)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding(.leading, 2)
                            }
                        }
                    }

                    Text("Sources")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())

            // Expanded source list
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(citations, id: \.number) { citation in
                        CitationSourceRow(citation: citation)
                    }
                }
                .padding(.horizontal, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Citation Source Row

/// A single row in the expanded sources list
struct CitationSourceRow: View {
    let citation: CitationReference
    @State private var isHovered = false

    var body: some View {
        Button(action: openURL) {
            HStack(spacing: 10) {
                // Favicon
                CitationBadgeView(citation: citation, size: 22)

                // Title and domain
                VStack(alignment: .leading, spacing: 2) {
                    Text(citation.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let domain = extractDomain(from: citation.url) {
                        Text(domain)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                Spacer()

                // External link icon
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(isHovered ? 0.12 : 0.05))
            .cornerRadius(6)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("Open \(citation.title)")
    }

    private func openURL() {
        guard let url = URL(string: citation.url) else { return }
        #if os(macOS)
            NSWorkspace.shared.open(url)
        #elseif os(iOS)
            UIApplication.shared.open(url)
        #endif
    }

    private func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host
        else { return nil }
        // Remove www. prefix if present
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Inline Citation Badges Row

/// A horizontal row of citation badges to display inline after message content
struct InlineCitationBadgesView: View {
    let citations: [CitationReference]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(citations, id: \.number) { citation in
                CitationBadgeView(citation: citation, size: 20)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
    struct CitationSourcesView_Previews: PreviewProvider {
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
                        CitationBadgeView(citation: citation)
                    }
                }

                // Inline badges row
                InlineCitationBadgesView(citations: sampleCitations)

                // Full footer
                CitationSourcesFooter(citations: sampleCitations)
            }
            .padding()
            .background(Color.gray.opacity(0.3))
            .preferredColorScheme(.dark)
        }
    }
#endif
