// swiftformat:options --ifdef no-indent
#if os(iOS)

import SwiftUI

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
                Circle()
                    .fill(Theme.textPrimary.opacity(0.1))
                    .frame(width: size, height: size)

                if let faviconURL = citation.favicon, let url = URL(string: faviconURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
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
            .foregroundStyle(Theme.textPrimary)
    }

    private func openURL() {
        guard let url = URL(string: citation.url) else { return }
        UIApplication.shared.open(url)
    }
}

struct IOSCitationSourcesFooter: View {
    let citations: [CitationReference]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button(action: {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()

                withAnimation(Motion.springSnappy) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: Spacing.sm) {
                    if !isExpanded {
                        HStack(spacing: Spacing.xs) {
                            ForEach(citations.prefix(4), id: \.number) { citation in
                                IOSCitationBadgeView(citation: citation, size: 22)
                            }
                            if citations.count > 4 {
                                Text("+\(citations.count - 4)")
                                    .font(Typography.footnote)
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.leading, Spacing.xxxs)
                            }
                        }
                    }

                    Text("Sources")
                        .font(Typography.captionBold)
                        .foregroundStyle(Theme.textSecondary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: Typography.Size.sm, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Theme.textPrimary.opacity(0.05))
                .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(isExpanded ? "Collapse sources" : "Expand sources, \(citations.count) available")
            .accessibilityIdentifier("message.citations.expandButton")

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

struct IOSCitationSourceRow: View {
    let citation: CitationReference

    var body: some View {
        Button(action: openURL) {
            HStack(spacing: Spacing.lg) {
                IOSCitationBadgeView(citation: citation, size: 24)

                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(citation.title)
                        .font(Typography.captionBold)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    if let domain = extractDomain(from: citation.url) {
                        Text(domain)
                            .font(Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: Typography.Size.sm, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(Theme.textPrimary.opacity(0.03))
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Open \(citation.title)")
    }

    private func openURL() {
        guard let url = URL(string: citation.url) else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        UIApplication.shared.open(url)
    }

    private func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

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
            HStack {
                ForEach(sampleCitations, id: \.number) { citation in
                    IOSCitationBadgeView(citation: citation)
                }
            }

            IOSInlineCitationBadgesView(citations: sampleCitations)

            IOSCitationSourcesFooter(citations: sampleCitations)
        }
        .padding()
    }
}
#endif
#endif
