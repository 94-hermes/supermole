import SwiftUI

/// A Liquid Glass panel holding one block of content. It lifts a little
/// under the pointer.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 22
    /// Off for a card holding a long list: scaling it on hover redraws all
    /// of its glass for nothing.
    var liftsOnHover = true
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        content
            .padding(padding)
            // Fills its row's height, so cards side by side end on one line.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardRadius))
            .scaleEffect(isHovered ? 1.008 : 1)
            .onHover { hovering in
                guard liftsOnHover else { return }
                withAnimation(Motion.hover) { isHovered = hovering }
            }
    }
}

/// Fades and rises into place once, `order` steps after the first card of
/// its cascade. Where `playsEntrance` is off (a space seen before) the card
/// is simply there.
struct EntranceEffect: ViewModifier {
    let order: Int
    @Environment(\.playsEntrance) private var playsEntrance
    @State private var isVisible = false

    func body(content: Content) -> some View {
        let shown = isVisible || !playsEntrance
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .scaleEffect(shown ? 1 : 0.97, anchor: .top)
            .onAppear {
                guard playsEntrance else { return }
                withAnimation(Motion.entrance.delay(Double(order) * Motion.stagger)) {
                    isVisible = true
                }
            }
    }
}

extension EnvironmentValues {
    @Entry var playsEntrance = true
}

extension View {
    func entrance(_ order: Int = 0) -> some View {
        modifier(EntranceEffect(order: order))
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
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card's small caption: an icon and a word.
struct CardLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color = Theme.indigo

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
            .glassEffect(.regular.tint(color.opacity(0.22)), in: .capsule)
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
        .foregroundStyle(Theme.rose)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Theme.rose.opacity(0.12)), in: .rect(cornerRadius: Theme.rowRadius))
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

/// "Updated 12 minutes ago", while a space shows a result kept from earlier,
/// with a spinner while a fresh one is read.
struct UpdatedLabel: View {
    let savedAt: Date
    let isRefreshing: Bool

    private static let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        HStack(spacing: 6) {
            if isRefreshing {
                ProgressView().controlSize(.mini)
            }
            Text("Updated \(Self.age.localizedString(for: savedAt, relativeTo: .now))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
