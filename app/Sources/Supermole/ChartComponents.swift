import Charts
import SwiftUI

/// A round gauge filled to `fraction`, drawn with a gradient stroke.
struct RingGauge<Center: View>: View {
    let fraction: Double
    var colors: [Color] = [Theme.purple, Theme.indigo]
    var lineWidth: CGFloat = 16
    @ViewBuilder let center: Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(
                    AngularGradient(colors: colors + [colors.first ?? Theme.purple], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: (colors.last ?? Theme.purple).opacity(0.35), radius: 8)
            center
        }
        .animation(.smooth(duration: 0.8), value: fraction)
    }
}

/// One reading of a value over time, for the sparklines.
struct Sample: Identifiable, Equatable {
    let id: Int
    let value: Double
}

/// A soft area chart of the last minutes of a percentage.
struct Sparkline: View {
    let samples: [Sample]
    var color: Color = Theme.purple

    var body: some View {
        Chart(samples) { sample in
            AreaMark(x: .value("Time", sample.id), y: .value("Value", sample.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", sample.id), y: .value("Value", sample.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .animation(.smooth, value: samples)
    }
}

/// One slice of the storage donut.
struct StorageSlice: Identifiable {
    let id: String
    let label: LocalizedStringKey
    let bytes: UInt64
    let color: Color
}

/// The startup disk as a donut: used, space macOS can purge, and free.
struct StorageDonut<Center: View>: View {
    let slices: [StorageSlice]
    @ViewBuilder let center: Center

    var body: some View {
        Chart(slices) { slice in
            SectorMark(angle: .value("Bytes", Double(slice.bytes)), innerRadius: .ratio(0.68), angularInset: 1.5)
                .cornerRadius(6)
                .foregroundStyle(slice.color)
        }
        .chartLegend(.hidden)
        .chartBackground { _ in center }
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
