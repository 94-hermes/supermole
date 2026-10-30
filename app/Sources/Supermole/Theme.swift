import SwiftUI

/// Colors, shapes and number formats shared by every space of the app.
enum Theme {
    /// The SUPERMOLE banner's purple and green, brightened for glass.
    static let purple = Color(red: 0.58, green: 0.33, blue: 0.86)
    static let indigo = Color(red: 0.36, green: 0.40, blue: 0.95)
    static let green = Color(red: 0.30, green: 0.72, blue: 0.45)
    static let warning = Color.orange
    static let danger = Color.red

    static let accent = LinearGradient(colors: [purple, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let cardRadius: CGFloat = 26
    static let rowRadius: CGFloat = 16
    static let spacing: CGFloat = 20
    static let pagePadding: CGFloat = 28

    /// A 0-100 score's color: green when healthy, orange, then red.
    static func scoreColor(_ score: Int) -> Color {
        switch score {
        case 80...: return green
        case 60..<80: return warning
        default: return danger
        }
    }

    /// A usage share's color: the given tint until the resource is nearly full.
    static let nearlyFullShare = 0.85

    static func usageColor(_ share: Double, tint: Color = purple) -> Color {
        share > nearlyFullShare ? warning : tint
    }
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

/// A soft, slowly shifting mesh of the brand colors that Liquid Glass refracts.
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
        Color(red: 0.86, green: 0.80, blue: 1.00), Color(red: 0.94, green: 0.91, blue: 1.00), Color(red: 0.80, green: 0.94, blue: 0.88),
        Color(red: 0.91, green: 0.87, blue: 1.00), Color(red: 0.98, green: 0.97, blue: 1.00), Color(red: 0.85, green: 0.89, blue: 1.00),
        Color(red: 0.83, green: 0.91, blue: 0.99), Color(red: 0.93, green: 0.89, blue: 1.00), Color(red: 0.90, green: 0.82, blue: 0.99),
    ]

    private static let darkColors: [Color] = [
        Color(red: 0.16, green: 0.10, blue: 0.27), Color(red: 0.10, green: 0.09, blue: 0.18), Color(red: 0.07, green: 0.17, blue: 0.16),
        Color(red: 0.12, green: 0.09, blue: 0.22), Color(red: 0.08, green: 0.08, blue: 0.13), Color(red: 0.10, green: 0.11, blue: 0.24),
        Color(red: 0.07, green: 0.12, blue: 0.20), Color(red: 0.11, green: 0.08, blue: 0.19), Color(red: 0.17, green: 0.09, blue: 0.24),
    ]
}
