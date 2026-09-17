import SwiftUI

/// Latest sample plus a heart-rate trend line.
struct TelemetryCardView: View {
    let packet: TelemetryPacket
    let series: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Adaptive grid rather than a fixed HStack so the metrics reflow on narrower
            // devices and at larger Dynamic Type sizes instead of truncating.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                MetricTile(
                    title: "Heart Rate",
                    value: packet.heartRateText,
                    unit: "BPM",
                    symbol: "heart.fill",
                    tint: .pink,
                    isStale: packet.heartRate == nil
                )
                MetricTile(
                    title: "Steps",
                    value: packet.stepsText,
                    unit: "today",
                    symbol: "figure.walk",
                    tint: .blue
                )
                MetricTile(
                    title: "Battery",
                    value: packet.batteryText,
                    unit: packet.isCharging ? "charging" : "remaining",
                    symbol: packet.isCharging ? "battery.100.bolt" : batterySymbol,
                    tint: batteryTint
                )
            }

            if series.count > 1 {
                Sparkline(values: series)
                    .frame(height: 44)
                    .accessibilityLabel("Heart rate trend over the last \(series.count) samples")
            }

            HStack(spacing: 10) {
                if !packet.isOnWrist {
                    Badge(text: "Off wrist", tint: .orange)
                }
                if !packet.hasSensorContact {
                    Badge(text: "No sensor contact", tint: .orange)
                }
                Spacer(minLength: 0)
                Text(packet.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    private var batterySymbol: String {
        switch packet.batteryPercent {
        case 75...: "battery.100"
        case 40..<75: "battery.75"
        case 15..<40: "battery.25"
        default: "battery.0"
        }
    }

    private var batteryTint: Color {
        switch packet.batteryPercent {
        case 40...: .green
        case 15..<40: .orange
        default: .red
        }
    }
}

// MARK: - Pieces

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let symbol: String
    let tint: Color
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
                .labelStyle(.titleAndIcon)

            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isStale ? .secondary : .primary)
                .contentTransition(.numericText())

            Text(unit)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Minimal line chart.
///
/// Hand-drawn with `Path` rather than pulled from Swift Charts: this renders on every
/// telemetry packet, and a full chart view is far more layout work than a polyline needs.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let lower = values.min() ?? 0
            let upper = values.max() ?? 1
            // Guard a flat series: a zero range would divide by zero and collapse the line.
            let range = max(upper - lower, 1)

            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: size.width * (values.count == 1 ? 0.5 : CGFloat(index) / CGFloat(values.count - 1)),
                    y: size.height * (1 - CGFloat((value - lower) / range))
                )
            }

            ZStack {
                // Fill under the curve.
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: size.height))
                    path.addLine(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [.pink.opacity(0.25), .pink.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(.pink, style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .drawingGroup()
    }
}

#Preview {
    List {
        TelemetryCardView(
            packet: .preview,
            series: (0..<40).map { 68 + 10 * sin(Double($0) / 5) }
        )
    }
}
