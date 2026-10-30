import Charts
import SwiftUI

/// A round gauge that fills up to `fraction` when it appears and glides to
/// each new value.
struct RingGauge<Center: View>: View {
    let fraction: Double
    var colors: [Color] = [Theme.indigo, Theme.teal]
    var lineWidth: CGFloat = 16
    @ViewBuilder let center: Center

    @State private var shown = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
                .padding(lineWidth / 2)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(
                    AngularGradient(colors: colors + [colors.first ?? Theme.indigo], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                // Inside the frame: drawingGroup clips whatever crosses it.
                .padding(lineWidth / 2)
                // Metal draws the conic gradient; CoreGraphics did it on the CPU
                // for every frame of an animation.
                .drawingGroup()
            center
        }
        .onAppear { withAnimation(Motion.value) { shown = clamped } }
        .onChange(of: fraction) { withAnimation(Motion.value) { shown = clamped } }
    }

    private var clamped: Double { min(max(fraction, 0), 1) }
}

/// One reading of a value over time, for the sparklines.
struct Sample: Identifiable, Equatable {
    let id: Int
    let value: Double
}

/// A soft area chart of the last minutes of a percentage.
struct Sparkline: View {
    let samples: [Sample]
    var color: Color = Theme.indigo

    var body: some View {
        Chart(samples) { sample in
            AreaMark(x: .value("Time", sample.id), y: .value("Value", sample.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", sample.id), y: .value("Value", sample.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

/// One slice of the storage donut.
struct StorageSlice: Identifiable {
    let id: String
    let label: LocalizedStringKey
    let bytes: UInt64
    let color: Color
}

/// The gap between two donut slices, as a share of the circle.
private let donutSliceGap = 0.012

/// The startup disk as a donut drawn with plain shapes (lighter than a
/// chart), its slices sweeping in when it appears.
struct StorageDonut<Center: View>: View {
    let slices: [StorageSlice]
    var lineWidth: CGFloat = 20
    @ViewBuilder let center: Center

    @State private var progress = 0.0

    var body: some View {
        let total = Double(slices.reduce(0) { $0 + $1.bytes })
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            ForEach(Array(segments(total: total).enumerated()), id: \.offset) { _, segment in
                Circle()
                    .trim(from: segment.start * progress, to: max(segment.start, segment.end - donutSliceGap) * progress)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .onAppear { withAnimation(Motion.value) { progress = 1 } }
    }

    private func segments(total: Double) -> [(start: Double, end: Double, color: Color)] {
        guard total > 0 else { return [] }
        var start = 0.0
        return slices.compactMap { slice in
            let share = Double(slice.bytes) / total
            defer { start += share }
            return share > 0 ? (start, start + share, slice.color) : nil
        }
    }
}

struct LegendRow: View {
    let color: Color
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 12)
            Text(verbatim: value).monospacedDigit().fontWeight(.semibold)
        }
    }
}
