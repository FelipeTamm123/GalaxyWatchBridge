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
                    tint: .blue,
                    isStale: packet.steps == nil
                )
                MetricTile(
                    title: "Distance",
                    value: packet.distanceText,
                    unit: packet.distanceUnit,
                    symbol: "point.topleft.down.curvedto.point.bottomright.up",
                    tint: .teal,
                    isStale: packet.distanceMeters == nil
                )
                MetricTile(
                    title: "Calories",
                    value: packet.caloriesText,
                    unit: "kcal",
                    symbol: "flame.fill",
                    tint: .orange,
                    isStale: packet.calories == nil
                )
                MetricTile(
                    title: "Battery",
                    value: packet.batteryText,
                    unit: batteryUnit,
                    symbol: batterySymbol,
                    tint: batteryTint,
                    isStale: packet.batteryPercent == nil
                )
            }

            if series.count > 1 {
                Sparkline(values: series)
                    .frame(height: 44)
                    .accessibilityLabel("Heart rate trend over the last \(series.count) samples")
            }

            HStack(spacing: 10) {
                // `isOnWrist == false` specifically, not `!isOnWrist`: nil means the watch
                // has no off-body sensor, which is not the same claim as "off wrist".
                if packet.isOnWrist == false {
                    Badge(text: "Off wrist", tint: .orange)
                }
                if !packet.hasHeartRateSensor {
                    Badge(text: "No HR sensor", tint: .orange)
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

    private var batteryUnit: String {
        guard packet.batteryPercent != nil else { return "unknown" }
        return packet.isCharging ? "charging" : "remaining"
    }

    private var batterySymbol: String {
        guard let percent = packet.batteryPercent else { return "battery.0" }
        if packet.isCharging { return "battery.100.bolt" }
        switch percent {
        case 75...: return "battery.100"
        case 40..<75: return "battery.75"
        case 15..<40: return "battery.25"
        default: return "battery.0"
        }
    }

    private var batteryTint: Color {
        guard let percent = packet.batteryPercent else { return .secondary }
        switch percent {
        case 40...: return .green
        case 15..<40: return .orange
        default: return .red
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
                .lineLimit(1)

            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isStale ? .secondary : .primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(unit)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
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
                    guard let first = points.first, let last = points.last else { return }
                    path.move(to: CGPoint(x: first.x, y: size.height))
                    path.addLine(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: last.x, y: size.height))
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
