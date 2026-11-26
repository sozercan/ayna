// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

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
                Circle()
                    .fill(Color.white.opacity(0.15))
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
                    .stroke(Color.white.opacity(isHovered ? 0.4 : 0.2), lineWidth: Spacing.Border.standard)
            )
            .scaleEffect(isHovered ? 1.1 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(Motion.easeQuick) {
                isHovered = hovering
            }
        }
        .help(citation.title)
        .accessibilityLabel("Source \(citation.number): \(citation.title)")
    }

    private var fallbackNumberView: some View {
        Text("\(citation.number)")
            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
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

struct CitationSourcesFooter: View {
    let citations: [CitationReference]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button(action: {
                withAnimation(Motion.springSnappy) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: Spacing.sm) {
                    if !isExpanded {
                        HStack(spacing: Spacing.xs) {
                            ForEach(citations.prefix(5), id: \.number) { citation in
                                CitationBadgeView(citation: citation, size: 20)
                            }
                            if citations.count > 5 {
                                Text("+\(citations.count - 5)")
                                    .font(Typography.micro)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .padding(.leading, Spacing.xxxs)
                            }
                        }
                    }

                    Text("Sources")
                        .font(Typography.buttonSmall)
                        .foregroundStyle(.white.opacity(0.8))

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: Typography.Size.xs, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Color.white.opacity(0.08))
                .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(citations, id: \.number) { citation in
                        CitationSourceRow(citation: citation)
                    }
                }
                .padding(.horizontal, Spacing.xxs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct CitationSourceRow: View {
    let citation: CitationReference
    @State private var isHovered = false

    var body: some View {
        Button(action: openURL) {
            HStack(spacing: Spacing.lg) {
                CitationBadgeView(citation: citation, size: 22)

                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(citation.title)
                        .font(Typography.buttonSmall)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if let domain = extractDomain(from: citation.url) {
                        Text(domain)
                            .font(Typography.micro)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: Typography.Size.xs, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.xs)
            .background(Color.white.opacity(isHovered ? 0.12 : 0.05))
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.sm))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: Motion.Duration.instant)) {
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
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct InlineCitationBadgesView: View {
    let citations: [CitationReference]

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(citations, id: \.number) { citation in
                CitationBadgeView(citation: citation, size: 20)
            }
        }
    }
}

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
            HStack {
                ForEach(sampleCitations, id: \.number) { citation in
                    CitationBadgeView(citation: citation)
                }
            }

            InlineCitationBadgesView(citations: sampleCitations)

            CitationSourcesFooter(citations: sampleCitations)
        }
        .padding()
        .background(Color.gray.opacity(0.3))
        .preferredColorScheme(.dark)
    }
}
#endif
#endif
