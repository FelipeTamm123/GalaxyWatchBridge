import SwiftUI

struct ContentView: View {
    /// `@State` is the correct ownership for an `@Observable` model created by the view.
    /// `@StateObject` belongs to the older `ObservableObject` protocol and does not apply.
    @State private var viewModel = WatchViewModel()
    @State private var isLogExpanded = false

    var body: some View {
        NavigationStack {
            List {
                statusSection

                if viewModel.phase.isLinked {
                    telemetrySection
                    controlSection
                } else {
                    scanSection
                    deviceSection
                }

                logSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Watch Bridge")
            .animation(.default, value: viewModel.phase)
            .animation(.default, value: viewModel.devices.count)
        }
        // Ties the event stream's lifetime to the screen: cancelled automatically on
        // disappear, restarted on reappear.
        .task {
            viewModel.activate()
        }
        .onDisappear {
            viewModel.deactivate()
        }
        .alert(
            "Bluetooth Error",
            isPresented: $viewModel.isShowingError,
            presenting: viewModel.lastError
        ) { _ in
            Button("OK", role: .cancel) { viewModel.dismissError() }
        } message: { error in
            Text([error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: "\n\n"))
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                StatusIndicator(phase: viewModel.phase, state: viewModel.bluetoothState)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.statusText)
                        .font(.headline)
                        .lineLimit(1)

                    if let mtu = viewModel.negotiatedMTU {
                        Text("MTU \(mtu) B · \(viewModel.receivedPacketCount) packets")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if let suggestion = viewModel.bluetoothState.recoverySuggestion {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                if viewModel.phase.isLinked {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnect()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Scanning

    private var scanSection: some View {
        Section {
            Button {
                viewModel.toggleScan()
            } label: {
                HStack {
                    Label(
                        viewModel.phase == .scanning ? "Stop Scanning" : "Scan for Devices",
                        systemImage: viewModel.phase == .scanning ? "stop.circle" : "antenna.radiowaves.left.and.right"
                    )
                    Spacer()
                    if viewModel.phase == .scanning {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!viewModel.canScan && viewModel.phase != .scanning)

            Toggle("Show all nearby devices", isOn: $viewModel.scanUnfiltered)
                .disabled(viewModel.phase == .scanning)
        } footer: {
            Text(viewModel.scanUnfiltered
                 ? "Unfiltered scanning lists every BLE device in range. Foreground only, and heavier on battery."
                 : "Filtered to the bridge service. Only a watch running the companion GATT server will appear.")
        }
    }

    private var deviceSection: some View {
        Section("Discovered") {
            if viewModel.devices.isEmpty {
                ContentUnavailableView {
                    Label("No devices", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text(viewModel.phase == .scanning
                         ? "Scanning… make sure the watch app is in the foreground."
                         : "Start a scan to look for nearby devices.")
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.devices) { device in
                    DeviceRowView(device: device) {
                        viewModel.connect(to: device)
                    }
                    .disabled(!device.isConnectable || viewModel.phase.isBusy)
                }
            }
        }
    }

    // MARK: - Telemetry & controls

    private var telemetrySection: some View {
        Section("Telemetry") {
            if let packet = viewModel.latestTelemetry {
                TelemetryCardView(packet: packet, series: viewModel.heartRateSeries)
            } else {
                ContentUnavailableView {
                    Label("Awaiting data", systemImage: "waveform.path.ecg")
                } description: {
                    Text("Start the stream or request a single sample.")
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
        }
    }

    private var controlSection: some View {
        Section("Controls") {
            ControlPanelView(viewModel: viewModel)
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section {
            // DisclosureGroup rather than `Section(isExpanded:)`, which only renders its
            // disclosure control in sidebar-style lists.
            DisclosureGroup(isExpanded: $isLogExpanded) {
                LogConsoleView(entries: viewModel.logs)
            } label: {
                HStack {
                    Label("Console", systemImage: "terminal")
                    Spacer()
                    Text("\(viewModel.logs.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if isLogExpanded, !viewModel.logs.isEmpty {
                Button("Clear Console", role: .destructive) {
                    viewModel.clearLogs()
                }
            }
        } footer: {
            Text("BLE failures are usually silent — a wrong service UUID or a peripheral that never advertises produces no error. The event trace is how you tell them apart.")
        }
    }
}

// MARK: - Status dot

private struct StatusIndicator: View {
    let phase: WatchViewModel.Phase
    let state: BluetoothState

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 36, height: 36)

            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: phase.isBusy || phase == .scanning)
        }
        .accessibilityLabel(Text(accessibilityText))
    }

    private var color: Color {
        switch phase {
        case .ready: .green
        case .connected, .connecting: .orange
        case .scanning: .blue
        case .idle: state.isReady ? .secondary : .red
        }
    }

    private var symbol: String {
        switch phase {
        case .ready: "checkmark.circle.fill"
        case .connected, .connecting: "arrow.triangle.2.circlepath"
        case .scanning: "antenna.radiowaves.left.and.right"
        case .idle: state.isReady ? "circle.dashed" : "exclamationmark.triangle.fill"
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .ready: "Connected and ready"
        case .connected: "Connected, discovering services"
        case .connecting: "Connecting"
        case .scanning: "Scanning"
        case .idle: state.displayName
        }
    }
}

#Preview {
    ContentView()
}
