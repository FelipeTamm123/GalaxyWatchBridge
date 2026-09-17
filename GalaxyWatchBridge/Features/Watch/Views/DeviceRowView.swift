import SwiftUI

/// One row in the discovered-devices list.
struct DeviceRowView: View {
    let device: DiscoveredPeripheral
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                signalBars

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(device.displayName)
                            .font(.body)
                            .fontWeight(device.advertisesBridgeService ? .semibold : .regular)
                            .lineLimit(1)

                        if device.advertisesBridgeService {
                            Text("BRIDGE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.2), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(device.isConnectable ? 1 : 0.45)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(device.isConnectable ? "Double tap to connect" : "Not connectable")
    }

    private var signalBars: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= device.signal.bars ? barColor : Color.secondary.opacity(0.22))
                    .frame(width: 3, height: 4 + CGFloat(bar) * 3.5)
            }
        }
        .frame(width: 22, height: 20, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private var barColor: Color {
        switch device.signal {
        case .excellent, .good: .green
        case .fair: .orange
        case .poor: .red
        }
    }

    private var subtitle: String {
        var parts = ["\(device.rssi) dBm"]
        if !device.isConnectable { parts.append("not connectable") }
        // Show a service count rather than raw UUIDs — a full 128-bit UUID overflows the
        // row, and the console already carries the exact values.
        if !device.advertisedServices.isEmpty {
            parts.append("\(device.advertisedServices.count) service\(device.advertisedServices.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        "\(device.displayName), signal \(device.signal.bars) of 4"
            + (device.advertisesBridgeService ? ", bridge service available" : "")
    }
}

#Preview {
    List {
        DeviceRowView(
            device: .init(
                id: UUID(), name: "Galaxy Watch7", rssi: -52, isConnectable: true,
                advertisedServices: [BLEConstants.bridgeService.uuidString.uppercased()],
                firstSeen: .now, lastSeen: .now
            ),
            onTap: {}
        )
        DeviceRowView(
            device: .init(
                id: UUID(), name: nil, rssi: -88, isConnectable: false,
                advertisedServices: [], firstSeen: .now, lastSeen: .now
            ),
            onTap: {}
        )
    }
}
