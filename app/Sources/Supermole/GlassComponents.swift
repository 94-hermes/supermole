import SwiftUI

/// A Liquid Glass panel holding one block of content.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            // Fills its row's height, so cards side by side end on one line.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

/// A space's title, with an optional line under it.
struct PageHeader: View {
    let title: LocalizedStringKey
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card's small caption: an icon and a word.
struct CardLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color = Theme.purple

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.headline)
        .foregroundStyle(.secondary)
    }
}

/// A short colored word, such as an AI verdict.
struct Pill: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .glassEffect(.regular.tint(color.opacity(0.25)), in: .capsule)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(verbatim: message).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(Theme.danger)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Theme.danger.opacity(0.12)), in: .rect(cornerRadius: Theme.rowRadius))
    }
}

/// Shown while a space waits for `mo`.
struct LoadingCard: View {
    let message: LocalizedStringKey

    var body: some View {
        GlassCard {
            HStack(spacing: 14) {
                ProgressView().controlSize(.regular)
                Text(message).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }
}
