import SwiftUI

/// Scrolling event trace for the BLE layer.
struct LogConsoleView: View {
    let entries: [LogEntry]

    /// Rows rendered inline. Entries are shown newest-first and capped so the newest line
    /// is always visible without scrolling — which also avoids nesting a vertical
    /// ScrollView inside the enclosing List, where the two scroll gestures fight.
    private static let visibleLimit = 60

    private var visible: [LogEntry] {
        entries.suffix(Self.visibleLimit).reversed()
    }

    var body: some View {
        if entries.isEmpty {
            Text("No events yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(visible) { entry in
                LogRow(entry: entry)
            }

            if entries.count > Self.visibleLimit {
                Text("\(entries.count - Self.visibleLimit) earlier entries not shown")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.level.symbolName)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let hex = entry.payloadHex {
                    Text(hex)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 0)

            Text(entry.timeText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .listRowSeparator(.hidden)
    }

    private var tint: Color {
        switch entry.level {
        case .debug: .secondary
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

#Preview {
    List {
        LogConsoleView(entries: [
            LogEntry(level: .success, message: "Bluetooth ready"),
            LogEntry(level: .info, message: "Scanning for bridge service…"),
            LogEntry(level: .debug, message: "Found Galaxy Watch7 @ -54 dBm"),
            LogEntry(level: .warning, message: "Bridge service not present. Is the Wear OS GATT server running?"),
            LogEntry(level: .info, message: "→ Start stream (1000 ms)",
                     payload: Data([0x10, 0x01, 0x02, 0x00, 0xE8, 0x03])),
            LogEntry(level: .error, message: "Write failed: peripheral disconnected"),
        ])
    }
}
