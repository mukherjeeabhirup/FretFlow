import SwiftUI

struct ClickTrackControls: View {
    @ObservedObject var clickTrack: ClickTrackController
    @ObservedObject var score: ScoreController
    @ObservedObject var player: YouTubeController
    let isGuitarPro: Bool

    private var available: Bool { isGuitarPro && score.isLoaded && !score.clicks.isEmpty && score.clickTrackError == nil }
    private var displayedClick: ScoreClick? { clickTrack.currentClick ?? score.clicks.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Click track", systemImage: "metronome").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("Click track", isOn: $clickTrack.enabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!available)
            }
            if available, let beat = displayedClick {
                HStack {
                    Text("\(beat.numerator)/\(beat.denominator)").font(.system(.title3, design: .rounded).weight(.semibold))
                    if clickTrack.enabled && clickTrack.isRunning {
                        Text(beat.isSubdivision == true ? "Accent · beat \(beat.beatIndex + 1)" : "Beat \(beat.beatIndex + 1) of \(beat.numerator)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(beat.effectiveAccentLevel > 0 ? Color.accentColor : Color.secondary)
                    }
                    Spacer()
                    Text(String(format: "♩ %.0f BPM", beat.bpm * player.rate / score.alignmentScale))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                if let grouping = beat.grouping, !grouping.isEmpty {
                    Text("Grouping \(grouping)")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
                    Slider(value: $clickTrack.volume, in: 0...1).accessibilityLabel("Click volume")
                        .disabled(!clickTrack.enabled)
                }
                Text("\(beatUnit(beat.denominator)) pulse with bar, group and written accents from this part. Starts and stops with playback.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(!isGuitarPro ? "Add a Guitar Pro score for an automatic click track."
                     : (score.clickTrackError ?? (score.isLoaded ? "No playable beats in this score." : "Waiting for the score…")))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = clickTrack.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func beatUnit(_ denominator: Int) -> String {
        switch denominator {
        case 1: return "Whole-note"
        case 2: return "Half-note"
        case 4: return "Quarter-note"
        case 8: return "Eighth-note"
        case 16: return "Sixteenth-note"
        case 32: return "Thirty-second-note"
        default: return "1/\(denominator)-note"
        }
    }
}
