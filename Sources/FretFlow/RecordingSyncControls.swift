import AppKit
import SwiftUI

private typealias SyncState<Value> = SwiftUI.State<Value>

struct RecordingSyncProgress: View {
    @ObservedObject var autoSync: RecordingAutoSync
    var body: some View {
        if autoSync.isAnalyzing {
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                Text(autoSync.status).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Stop") { autoSync.cancel() }.controlSize(.small)
            }
        } else if let error = autoSync.error {
            Text(error).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RecordingSyncControls: View {
    @ObservedObject var session: PracticeSession
    @ObservedObject var score: ScoreController
    @ObservedObject var player: YouTubeController
    @ObservedObject var autoSync: RecordingAutoSync
    @SyncState private var fineAdjustment = false
    @SyncState private var adjustmentText = "0.00"

    private var available: Bool { session.selectedSong?.kind == "gp" && score.isLoaded && session.hasLinkedVideo }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Recording sync", systemImage: "waveform.path").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("Auto-match new videos", isOn: $autoSync.enabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help("Match each new recording automatically when playback starts.")
            }
            if available {
                Text(autoSync.status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let source = session.syncSource {
                    Text(String(format: "%@ · %+.2f s", source == "automatic" ? "Matched" : "Adjusted", session.syncAdjustment))
                        .font(.system(.caption, design: .monospaced))
                }
                HStack {
                    if autoSync.isAnalyzing {
                        ProgressView().controlSize(.small)
                        Button("Stop matching") { autoSync.cancel() }
                    } else {
                        Button("Match start") { autoSync.retry() }
                            .disabled(!autoSync.enabled || !player.isReady || score.referenceAttacks.isEmpty)
                    }
                    Spacer()
                    Button("Reset") { session.resetSyncAdjustment() }
                        .disabled(session.syncSource == nil || autoSync.isAnalyzing)
                }.controlSize(.small)
                if let error = autoSync.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("The first play listens to the opening and saves a confident match. The click waits while matching. Uses only FretFlow’s playback audio, processed locally.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Fine adjustment", isExpanded: $fineAdjustment) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("−0.05 s") { session.setSyncAdjustment(max(-30, session.syncAdjustment - 0.05)) }
                            TextField("Seconds", text: $adjustmentText)
                                .textFieldStyle(.roundedBorder).frame(width: 65)
                                .onSubmit(applyAdjustment)
                                .accessibilityLabel("Recording sync adjustment in seconds")
                            Button("Apply", action: applyAdjustment)
                            Button("+0.05 s") { session.setSyncAdjustment(min(120, session.syncAdjustment + 0.05)) }
                        }.controlSize(.small)
                        Text("Positive moves tabs and clicks later; negative moves them earlier. Saved for this song and video.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 6).disabled(autoSync.isAnalyzing)
                }.font(.caption)
            } else {
                Text("Link a video to a Guitar Pro score to match its start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { updateAdjustmentText() }
        .onChange(of: session.syncAdjustment) { _, _ in updateAdjustmentText() }
        .onChange(of: session.selectedID) { _, _ in updateAdjustmentText() }
    }

    private func applyAdjustment() {
        if let value = Double(adjustmentText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            session.setSyncAdjustment(value)
        }
        updateAdjustmentText()
    }

    private func updateAdjustmentText() { adjustmentText = String(format: "%.3f", session.syncAdjustment) }
}
