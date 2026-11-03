import AppKit
import AVFoundation
import Combine
import Foundation

// Explicit, short diagnostic mode. It never requests permission, records audio,
// uploads samples, or logs pitch. Normal app launches do not run this check.
@MainActor
final class MicrophoneDiagnostic {
    private let tuner = GuitarTunerModel()
    private let output: URL
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var updates = 0
    private var listeningSamples = 0
    private var stoppedSamples = 0
    private var elapsed = 0
    private var finished = false

    init(output: URL) { self.output = output }

    func run() {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard auth == .authorized else {
            finish(permission: auth.rawValue)
            return
        }
        tuner.$inputLevel.dropFirst().sink { [weak self] _ in self?.updates += 1 }.store(in: &subscriptions)
        tuner.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed += 1
                if self.tuner.isListening { self.listeningSamples += 1 }
                else { self.stoppedSamples += 1 }
                if self.elapsed >= 10 { self.finish(permission: auth.rawValue) }
            }
        }
    }

    private func finish(permission: Int) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        var result: [String: Any] = [
            "permission": permission,
            "permissionAuthorized": permission == AVAuthorizationStatus.authorized.rawValue,
            "isListeningAtEnd": tuner.isListening,
            "analysisUpdates": updates,
            "listeningSamples": listeningSamples,
            "stoppedSamples": stoppedSamples,
            "input": tuner.inputName,
            "status": tuner.status,
            "hasError": tuner.hasError,
            "audioSaved": false
        ]
        tuner.stop()
        let updatesAtStop = updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [self] in
            result["lateAnalysisUpdatesAfterStop"] = updates - updatesAtStop
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(to: output)
            NSApp.terminate(nil)
        }
    }
}
