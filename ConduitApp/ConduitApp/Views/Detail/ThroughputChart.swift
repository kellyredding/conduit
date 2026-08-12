import Charts
import SwiftUI

/// Recent throughput for one tunnel: the two current rates spelled out, and the
/// history behind them.
///
/// **One axis.** Both series are bytes per second, so they share a scale and can
/// be compared by eye. A second axis would let a trickle of one look like a flood
/// of the other.
///
/// **Identity is never carried by colour alone.** Each direction is named, given
/// its own arrow, and shows its own number, so the pairing survives a colourblind
/// reader, a greyscale screenshot, and a screen reader. The colours only make the
/// two easier to follow across the plot.
///
/// **The line breaks where measurement stopped.** A gap in the samples is drawn
/// as a gap rather than bridged, because a straight line between two points an
/// unmeasured minute apart asserts traffic nobody observed.
struct ThroughputChart: View {
    let series: ThroughputSeries

    /// Below this, the y-axis stops shrinking. Scaled purely to its own contents,
    /// a tunnel carrying keepalives renders that chatter as a mountain range and
    /// reads identically to one saturating a link — so the floor is what keeps
    /// "almost nothing" looking like almost nothing.
    ///
    /// Lowered from 64 KB/s after watching it: on a split tunnel the honest
    /// answer is a flat line most of the time, and a floor high enough to flatten
    /// keepalive also flattens the first genuinely interesting burst. The number
    /// beside the plot is what answers "is anything moving"; this only has to
    /// stop the shape lying about scale.
    private static let scaleFloor: Double = 8 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readout

            if series.isEmpty {
                measuring
            } else {
                plot
                span
            }
        }
    }

    /// The legend and the current values in one row: a mark, a direction, a
    /// number. Selective labelling by construction — the only numbers on screen
    /// are the two that describe now, rather than one per point.
    private var readout: some View {
        HStack(spacing: 18) {
            value(
                symbol: "arrow.down",
                label: "In",
                rate: series.latest?.inPerSecond,
                color: ThroughputPalette.inbound
            )
            value(
                symbol: "arrow.up",
                label: "Out",
                rate: series.latest?.outPerSecond,
                color: ThroughputPalette.outbound
            )
        }
    }

    private func value(
        symbol: String,
        label: String,
        rate: Double?,
        color: Color
    ) -> some View {
        HStack(spacing: 5) {
            // The legend swatch. Rounded rather than square so it reads as a
            // sample of the line it labels.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 12, height: 3)
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Text wears text colours, never the series colour: the swatch
            // beside it already carries the identity, and a coloured number is
            // harder to read for no gain.
            Text(rate.map(ThroughputFormat.rate) ?? "—")
                .font(.caption)
                .monospacedDigit()
        }
    }

    private var plot: some View {
        Chart(points) { point in
            // The run index is part of the series identity, which is what
            // breaks the line across a gap: two runs are two lines rather than
            // one line with a long straight segment through unmeasured time.
            // Done this way rather than with nil or NaN y-values because
            // whether those produce a gap is undocumented, and a rendering
            // detail that silently changes would put the false line back.
            LineMark(
                x: .value("Time", point.at),
                y: .value("Bytes per second", point.inPerSecond),
                series: .value("Direction", "In-\(point.run)")
            )
            .foregroundStyle(ThroughputPalette.inbound)
            // Samples are point measurements. A smoothed curve would draw
            // traffic between them that was never measured, and the peaks are
            // the part worth reading.
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))

            LineMark(
                x: .value("Time", point.at),
                y: .value("Bytes per second", point.outPerSecond),
                series: .value("Direction", "Out-\(point.run)")
            )
            .foregroundStyle(ThroughputPalette.outbound)
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .chartYScale(domain: 0...ceiling)
        // Time is the x axis, but its labels would be a row of clock times
        // nobody reads on a plot this small. The span is stated underneath
        // instead, in the units a person actually wants: how far back this goes.
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                mark in
                // Recessive: the data is the subject, the grid is scaffolding.
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let bytes = mark.as(Double.self) {
                        Text(ThroughputFormat.rate(bytes))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // Supplied above rather than drawn by the chart, so the legend and the
        // current values are one thing instead of two saying the same in
        // different corners.
        .chartLegend(.hidden)
        .frame(height: 68)
        .accessibilityLabel(accessibilityDescription)
    }

    private var measuring: some View {
        Text("Measuring — a rate needs two samples.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(height: 68, alignment: .center)
    }

    private var span: some View {
        Text(spanDescription)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Derived values

    /// Headroom above the tallest point so the line is not welded to the top
    /// edge, and never below the floor.
    private var ceiling: Double {
        max(series.peak * 1.15, Self.scaleFloor)
    }

    /// The rates, each tagged with which continuously-measured run it belongs to.
    ///
    /// A run ends wherever the series could not measure an interval, and the tag
    /// is what keeps the plot from drawing across it. The first rate carries
    /// `startsRun` too, so the counter only advances on a later one.
    private var points: [ThroughputPoint] {
        var run = 0
        return series.rates.enumerated().map { index, rate in
            if rate.startsRun, index > 0 { run += 1 }
            return ThroughputPoint(
                at: rate.at,
                inPerSecond: rate.inPerSecond,
                outPerSecond: rate.outPerSecond,
                run: run
            )
        }
    }

    private var spanDescription: String {
        guard
            let first = series.rates.first?.at,
            let last = series.rates.last?.at,
            last > first
        else {
            return "One sample so far."
        }
        let seconds = Int(last.timeIntervalSince(first).rounded())
        let count = series.rates.count
        if seconds < 60 {
            return "Last \(seconds)s · \(count) samples"
        }
        return "Last \(seconds / 60)m \(seconds % 60)s · \(count) samples"
    }

    private var accessibilityDescription: String {
        guard let latest = series.latest else {
            return "Throughput history, not yet measured"
        }
        return """
            Throughput history. In \(ThroughputFormat.rate(latest.inPerSecond)), \
            out \(ThroughputFormat.rate(latest.outPerSecond)).
            """
    }
}

/// A plottable point, belonging to one continuously-measured run.
private struct ThroughputPoint: Identifiable {
    let at: Date
    let inPerSecond: Double
    let outPerSecond: Double
    let run: Int

    var id: Date { at }
}

/// The two series colours, in light and dark.
///
/// Chosen by running the pair through a contrast and colour-vision validator
/// rather than by eye, in both modes and against each mode's own surface: the
/// worst adjacent separation is ΔE 34 in light and ΔE 24 in dark under
/// protanopia, both far above the ΔE 8 floor, and every step sits inside its
/// mode's lightness band with at least 3:1 against the background it is drawn on.
///
/// The dark pair is its own selection, not the light one lightened. A palette
/// flipped automatically lands outside the band that makes it legible — the
/// system's own blue and orange were measured doing exactly that — and the point
/// of choosing them deliberately is that both modes get a pair that passes.
///
/// Resolved through a dynamic provider so the colours follow the *window's*
/// appearance rather than the system's, which matters because the theme setting
/// can force one window light while the desktop is dark.
enum ThroughputPalette {
    static let inbound = Color(
        nsColor: .themed(
            light: NSColor(srgbRed: 0.000, green: 0.443, blue: 0.890, alpha: 1),
            dark: NSColor(srgbRed: 0.290, green: 0.565, blue: 0.851, alpha: 1)
        )
    )

    static let outbound = Color(
        nsColor: .themed(
            light: NSColor(srgbRed: 0.761, green: 0.384, blue: 0.039, alpha: 1),
            dark: NSColor(srgbRed: 0.788, green: 0.482, blue: 0.122, alpha: 1)
        )
    )
}

extension NSColor {
    fileprivate static func themed(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? dark
                : light
        }
    }
}

/// Byte rates, formatted the same way everywhere they appear.
enum ThroughputFormat {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        // Binary, matching the cumulative totals in the panel. The two readouts
        // describe the same counters and would otherwise disagree about what a
        // megabyte is.
        formatter.countStyle = .binary
        // Bytes included deliberately. Without it every rate under a kilobyte
        // rounds to "Zero KB/s", and an idle split tunnel carrying a couple of
        // hundred bytes a second of keepalive then reads as carrying nothing at
        // all — measured at ~200 B/s while the readout said Zero.
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        // "Zero KB" is the formatter's own wording for nothing, and it reads as
        // a state rather than a measurement. A number is what the rest of the
        // row is made of.
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func rate(_ bytesPerSecond: Double) -> String {
        let bytes = Int64(bytesPerSecond.rounded())
        return "\(formatter.string(fromByteCount: bytes))/s"
    }

    static func total(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}
