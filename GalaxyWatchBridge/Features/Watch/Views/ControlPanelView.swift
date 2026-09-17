import SwiftUI

/// Outbound command controls. Every action is disabled until the peripheral reaches
/// `.ready` — sending before discovery completes has no characteristic handle to write to.
struct ControlPanelView: View {
    /// `@Bindable` projects bindings from an `@Observable` model without the manual
    /// `Binding(get:set:)` dance — whose closures are not main-actor isolated and so
    /// cannot touch a `@MainActor` model under strict concurrency checking.
    @Bindable var viewModel: WatchViewModel

    private var isEnabled: Bool { viewModel.phase == .ready }

    var body: some View {
        Group {
            Picker("Stream rate", selection: $viewModel.streamRate) {
                ForEach(WatchViewModel.StreamRate.allCases) { rate in
                    Text(rate.rawValue).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            // Changing cadence mid-stream would need a fresh startStream; keep it locked
            // rather than silently diverging from what the watch is actually doing.
            .disabled(!isEnabled || viewModel.isStreaming)

            Button {
                viewModel.toggleStream()
            } label: {
                Label(
                    viewModel.isStreaming ? "Stop Stream" : "Start Stream",
                    systemImage: viewModel.isStreaming ? "stop.fill" : "play.fill"
                )
            }
            .disabled(!isEnabled)

            Button {
                viewModel.requestSingleSample()
            } label: {
                Label("Request Single Sample", systemImage: "arrow.down.circle")
            }
            .disabled(!isEnabled)

            Button {
                viewModel.buzzWatch()
            } label: {
                Label("Buzz Watch", systemImage: "waveform")
            }
            .disabled(!isEnabled)

            if viewModel.latestTelemetry != nil {
                Button(role: .destructive) {
                    viewModel.clearTelemetry()
                } label: {
                    Label("Clear Telemetry", systemImage: "trash")
                }
            }
        }
    }
}
