import SwiftUI

/// Colors, shapes, motion and number formats shared by every space.
///
/// Three complementary hues on a near-neutral background: indigo leads,
/// teal answers it, and amber is kept for what needs attention.
enum Theme {
    static let indigo = Color(red: 0.36, green: 0.36, blue: 0.84)
    static let teal = Color(red: 0.15, green: 0.60, blue: 0.62)
    static let amber = Color(red: 0.91, green: 0.60, blue: 0.30)
    static let rose = Color(red: 0.84, green: 0.33, blue: 0.40)

    /// The signature gradient: indigo into teal.
    static let accent = LinearGradient(colors: [indigo, teal], startPoint: .leading, endPoint: .trailing)

    static let cardRadius: CGFloat = 26
    static let rowRadius: CGFloat = 16
    static let spacing: CGFloat = 20
    static let pagePadding: CGFloat = 28

    /// A 0-100 score's colors, for its gauge: calm when healthy, warm when not.
    static func scoreColors(_ score: Int) -> [Color] {
        switch score {
        case 80...: return [teal, indigo]
        case 60..<80: return [amber, amber.opacity(0.7)]
        default: return [rose, amber]
        }
    }

    static func scoreColor(_ score: Int) -> Color {
        scoreColors(score)[0]
    }

    /// A usage share's color: the given tint until the resource is nearly full.
    static let nearlyFullShare = 0.85

    static func usageColor(_ share: Double, tint: Color = indigo) -> Color {
        share > nearlyFullShare ? amber : tint
    }
}

/// Motion, kept to entrances and value changes: nothing loops, so an idle
/// window costs no frames. The rolling-digits transition blurs on the CPU,
/// so only the large figures use it.
enum Motion {
    static let entrance = Animation.spring(response: 0.55, dampingFraction: 0.86)
    static let value = Animation.smooth(duration: 0.9)
    /// A periodic reading: short, so live figures cost few frames.
    static let update = Animation.smooth(duration: 0.35)
    static let hover = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let space = Animation.smooth(duration: 0.35)
    /// Delay between two cards of one cascade.
    static let stagger = 0.06
}

enum Formatting {
    static func bytes<Number: BinaryInteger>(_ value: Number) -> String {
        Int64(value).formatted(.byteCount(style: .file))
    }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// "5 j 3 h" in French, "5d 3h" in English.
    static func duration(seconds: UInt64) -> String {
        Duration.seconds(Int64(seconds)).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }
}

/// A quiet, nearly neutral mesh with a breath of the three hues, for the
/// glass to refract. Static: it is drawn once.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: colorScheme == .dark ? Self.darkColors : Self.lightColors
        )
        .ignoresSafeArea()
    }

    private static let lightColors: [Color] = [
        Color(red: 0.91, green: 0.91, blue: 0.97), Color(red: 0.96, green: 0.96, blue: 0.98), Color(red: 0.89, green: 0.95, blue: 0.95),
        Color(red: 0.95, green: 0.95, blue: 0.97), Color(red: 0.98, green: 0.98, blue: 0.99), Color(red: 0.93, green: 0.95, blue: 0.97),
        Color(red: 0.92, green: 0.95, blue: 0.96), Color(red: 0.96, green: 0.95, blue: 0.96), Color(red: 0.97, green: 0.93, blue: 0.90),
    ]

    private static let darkColors: [Color] = [
        Color(red: 0.11, green: 0.11, blue: 0.20), Color(red: 0.08, green: 0.08, blue: 0.11), Color(red: 0.06, green: 0.14, blue: 0.15),
        Color(red: 0.09, green: 0.09, blue: 0.14), Color(red: 0.07, green: 0.07, blue: 0.09), Color(red: 0.08, green: 0.10, blue: 0.15),
        Color(red: 0.06, green: 0.11, blue: 0.12), Color(red: 0.09, green: 0.08, blue: 0.11), Color(red: 0.15, green: 0.10, blue: 0.08),
    ]
}
