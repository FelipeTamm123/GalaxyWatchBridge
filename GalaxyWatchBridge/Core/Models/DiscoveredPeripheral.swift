import Foundation

/// A peripheral seen during a scan.
///
/// A snapshot value, not a live handle — the `CBPeripheral` object stays owned by
/// `BLEManager` and is never handed above it. The UI addresses peripherals by `id`,
/// which is CoreBluetooth's per-install stable identifier for the device.
struct DiscoveredPeripheral: Identifiable, Sendable, Equatable {
    let id: UUID
    /// Advertised local name, falling back to the GAP device name. `nil` for devices that
    /// advertise no name at all — common, and not an error.
    let name: String?
    /// Last known RSSI in dBm. Negative; closer to zero is stronger.
    let rssi: Int
    /// Whether the advertisement's connectable flag was set. Beacons are not connectable.
    let isConnectable: Bool
    /// Service UUIDs from the advertisement packet, as uppercase strings.
    let advertisedServices: [String]
    let firstSeen: Date
    var lastSeen: Date

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return "Unnamed device"
    }

    /// Whether this device advertises the bridge service, meaning the Wear OS GATT server
    /// is up. Devices without it are shown greyed out during an unfiltered scan.
    var advertisesBridgeService: Bool {
        advertisedServices.contains(BLEConstants.bridgeService.uuidString.uppercased())
    }

    /// Coarse signal bucket, for a bars-style indicator. RSSI is noisy; do not show the
    /// raw number as though it were precise.
    var signal: SignalStrength {
        switch rssi {
        case (-55)...: .excellent
        case (-70)..<(-55): .good
        case (-85)..<(-70): .fair
        default: .poor
        }
    }

    enum SignalStrength: Sendable {
        case excellent, good, fair, poor

        var bars: Int {
            switch self {
            case .excellent: 4
            case .good: 3
            case .fair: 2
            case .poor: 1
            }
        }

        var symbolName: String {
            switch self {
            case .excellent, .good: "wifi"
            case .fair: "wifi.exclamationmark"
            case .poor: "wifi.slash"
            }
        }
    }

    func isStale(asOf now: Date = .now) -> Bool {
        now.timeIntervalSince(lastSeen) > BLEConstants.staleDeviceInterval
    }
}
