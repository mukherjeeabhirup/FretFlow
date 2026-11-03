import Foundation

struct PitchEstimate: Sendable {
    let frequency: Double?
    let confidence: Double
    let rms: Double
}

/// Gain-normalized YIN: compare waveform shape, including quiet decaying notes,
/// instead of requiring an amplified guitar's input level. Periodicity, rather
/// than gain, separates a musical tone from broadband microphone noise.
enum GuitarPitchDetector {
    static let minimumRMS = 0.00006

    static func estimate(samples: [Float], sampleRate: Double) -> PitchEstimate {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate), samples.count >= 1_024 else {
            return PitchEstimate(frequency: nil, confidence: 0, rms: 0)
        }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let energy = samples.reduce(0.0) { result, sample in
            let centered = Double(sample) - mean
            return result + centered * centered
        }
        let rms = sqrt(energy / Double(samples.count))
        guard rms.isFinite, rms > minimumRMS else {
            return PitchEstimate(frequency: nil, confidence: 0, rms: rms.isFinite ? rms : 0)
        }

        // A box filter before decimation reduces high-frequency noise and keeps
        // the difference calculation small enough for frequent UI updates.
        let stride = max(1, Int(sampleRate / 12_000))
        let rate = sampleRate / Double(stride)
        var signal = [Double]()
        signal.reserveCapacity(samples.count / stride)
        for start in Swift.stride(from: 0, through: samples.count - stride, by: stride) {
            var sum = 0.0
            for offset in 0..<stride { sum += Double(samples[start + offset]) - mean }
            signal.append(sum / Double(stride))
        }
        let minimumLag = max(2, Int(rate / 1_400))
        let maximumLag = min(Int(rate / 40), signal.count / 3)
        guard maximumLag > minimumLag + 2 else {
            return PitchEstimate(frequency: nil, confidence: 0, rms: rms)
        }
        let window = signal.count - maximumLag
        var energyPrefix = [Double](repeating: 0, count: signal.count + 1)
        for index in signal.indices { energyPrefix[index + 1] = energyPrefix[index] + signal[index] * signal[index] }
        let firstEnergy = energyPrefix[window]
        var normalized = [Double](repeating: 1, count: maximumLag + 1)
        var differences = [Double](repeating: 0, count: maximumLag + 1)
        var runningSum = 0.0
        for lag in 1...maximumLag {
            var correlation = 0.0
            for index in 0..<window {
                correlation += signal[index] * signal[index + lag]
            }
            // A string loses amplitude between periods, especially on an
            // unplugged electric. Remove that gain difference before YIN's
            // cumulative normalization; otherwise the longer, correct period
            // is penalized relative to its louder second/third harmonic.
            let delayedEnergy = energyPrefix[window + lag] - energyPrefix[lag]
            let normalizer = sqrt(firstEnergy * delayedEnergy)
            let difference = normalizer > 0 ? max(0, 1 - correlation / normalizer) : 1
            runningSum += difference
            differences[lag] = difference
            normalized[lag] = runningSum > 0 ? difference * Double(lag) / runningSum : 1
        }
        var candidate: Int?
        var lag = minimumLag
        while lag < maximumLag {
            if normalized[lag] < 0.20 {
                while lag + 1 <= maximumLag && normalized[lag + 1] < normalized[lag] { lag += 1 }
                candidate = lag
                break
            }
            lag += 1
        }
        guard var selected = candidate, selected > 0, selected < maximumLag else {
            return PitchEstimate(frequency: nil, confidence: 0, rms: rms)
        }
        func valleyDepth(_ lag: Int) -> Double {
            let left = normalized[lag - 1], middle = normalized[lag], right = normalized[lag + 1]
            let curvature = left - 2 * middle + right
            guard curvature > 1e-12 else { return middle }
            let correction = max(-1, min(1, 0.5 * (left - right) / curvature))
            return max(0, middle - 0.25 * (left - right) * correction)
        }
        // Require evidence for an actual fundamental: a longer period must
        // improve both absolute and relative periodicity. The previous 78%
        // improvement rule failed as soon as microphone noise lifted all the
        // valleys. Comparable valleys still keep the shortest period, so a
        // pure high note is never blindly folded into a guitar tuning.
        let firstCandidate = selected
        for multiple in 2...4 {
            let center = firstCandidate * multiple
            let lower = max(minimumLag, center - multiple)
            let upper = min(maximumLag - 1, center + multiple)
            guard lower <= upper else { continue }
            if let deeper = (lower...upper).min(by: { normalized[$0] < normalized[$1] }),
               valleyDepth(selected) - valleyDepth(deeper) > max(0.014, valleyDepth(selected) * 0.28) {
                selected = deeper
            }
        }
        let confidence = max(0, min(1, 1 - valleyDepth(selected)))
        // Interpolate the unnormalized valley: dividing by the running mean
        // introduces a high-note bias when only a few samples span a period.
        let left = differences[selected - 1]
        let middle = differences[selected]
        let right = differences[selected + 1]
        let denominator = left - 2 * middle + right
        let correction = abs(denominator) > 1e-12 ? 0.5 * (left - right) / denominator : 0
        let frequency = rate / (Double(selected) + max(-1, min(1, correction)))
        guard confidence >= 0.80, frequency >= 40, frequency <= 1_400 else {
            return PitchEstimate(frequency: nil, confidence: confidence, rms: rms)
        }
        return PitchEstimate(frequency: frequency, confidence: confidence, rms: rms)
    }
}

/// The acoustic estimate is not snapped to a tuning. Brief octave mistakes are
/// rejected in time, while a sustained new note (including a real octave jump)
/// is accepted promptly. The clock is supplied so this is testable without audio.
struct GuitarPitchTracker {
    private var stableLogPitch: Double?
    private var lastTime: TimeInterval?
    private var lastVoicedTime: TimeInterval?
    private var pendingLogPitch: Double?
    private var pendingSince: TimeInterval = 0
    private var pendingCount = 0

    mutating func reset() { self = GuitarPitchTracker() }

    mutating func update(_ estimate: PitchEstimate, at time: TimeInterval) -> PitchEstimate {
        guard time.isFinite else { reset(); return PitchEstimate(frequency: nil, confidence: 0, rms: estimate.rms) }
        if let lastTime, time < lastTime || time - lastTime > 0.5 { reset() }
        let elapsed = max(0.001, min(0.15, time - (lastTime ?? time - 0.043)))
        lastTime = time
        guard let frequency = estimate.frequency, frequency.isFinite, frequency > 0,
              estimate.confidence >= 0.8, estimate.rms >= GuitarPitchDetector.minimumRMS else {
            pendingLogPitch = nil
            pendingCount = 0
            // A dropout holds the needle only briefly; silence never leaves a
            // stale note indefinitely or supplies a fake confident estimate.
            if let lastVoicedTime, time - lastVoicedTime <= 0.13, let stableLogPitch {
                return PitchEstimate(frequency: pow(2, stableLogPitch), confidence: 0, rms: estimate.rms)
            }
            stableLogPitch = nil
            lastVoicedTime = nil
            return PitchEstimate(frequency: nil, confidence: estimate.confidence, rms: estimate.rms)
        }

        let logPitch = log2(frequency)
        if let stable = stableLogPitch, abs(logPitch - stable) * 1_200 <= 65 {
            let smoothing = 1 - exp(-elapsed / 0.065)
            stableLogPitch = stable + smoothing * (logPitch - stable)
            lastVoicedTime = time
            pendingLogPitch = nil
            pendingCount = 0
        } else {
            if let pending = pendingLogPitch, abs(logPitch - pending) * 1_200 <= 45 {
                pendingLogPitch = (pending * Double(pendingCount) + logPitch) / Double(pendingCount + 1)
                pendingCount += 1
            } else {
                pendingLogPitch = logPitch
                pendingSince = time
                pendingCount = 1
            }
            let isOctave = stableLogPitch.map { abs(abs(logPitch - $0) * 1_200 - 1_200) < 80 } ?? false
            let requiredTime: Double = stableLogPitch == nil ? 0.035 : (isOctave ? 0.12 : 0.075)
            if pendingCount >= 2, time - pendingSince >= requiredTime {
                stableLogPitch = pendingLogPitch
                lastVoicedTime = time
                pendingLogPitch = nil
                pendingCount = 0
            } else if let lastVoicedTime, time - lastVoicedTime > 0.18 {
                // An unstable attack should show "listening", not the previous
                // string indefinitely. Keep the candidate's confirmation time.
                stableLogPitch = nil
            }
        }
        // Holding a previous needle position is presentation continuity, not
        // evidence that the old note is still sounding during a new attack.
        let displayConfidence = pendingLogPitch == nil ? estimate.confidence : 0
        return PitchEstimate(frequency: stableLogPitch.map { pow(2, $0) }, confidence: displayConfidence, rms: estimate.rms)
    }
}

enum GuitarPitch {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static func frequency(midi: Int, concertA: Double = 440) -> Double {
        concertA * pow(2, Double(midi - 69) / 12)
    }
    static func midi(frequency: Double, concertA: Double = 440) -> Int {
        Int((69 + 12 * log2(frequency / concertA)).rounded())
    }
    static func name(midi: Int, octave: Bool = true) -> String {
        names[((midi % 12) + 12) % 12] + (octave ? String(midi / 12 - 1) : "")
    }
    static func cents(frequency: Double, target: Double) -> Double {
        1_200 * log2(frequency / target)
    }
    static func parse(_ text: String) -> Int? {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
        guard let letter = note.first?.uppercased(), let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][letter] else { return nil }
        var tail = String(note.dropFirst())
        var accidental = 0
        if tail.first == "#" { accidental = 1; tail.removeFirst() }
        else if tail.first == "b" { accidental = -1; tail.removeFirst() }
        guard let octave = Int(tail) else { return nil }
        let midi = (octave + 1) * 12 + base + accidental
        return (28...88).contains(midi) ? midi : nil
    }
}

struct GuitarTuning: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var notes: [Int] // Lowest string first; string number is count - index.

    static let presets: [GuitarTuning] = [
        .init(id: "six-standard", name: "Standard E", notes: [40, 45, 50, 55, 59, 64]),
        .init(id: "six-eb", name: "E♭ standard", notes: [39, 44, 49, 54, 58, 63]),
        .init(id: "six-d", name: "D standard", notes: [38, 43, 48, 53, 57, 62]),
        .init(id: "six-cs", name: "C♯ standard", notes: [37, 42, 47, 52, 56, 61]),
        .init(id: "six-c", name: "C standard", notes: [36, 41, 46, 51, 55, 60]),
        .init(id: "six-drop-d", name: "Drop D", notes: [38, 45, 50, 55, 59, 64]),
        .init(id: "six-drop-cs", name: "Drop C♯", notes: [37, 44, 49, 54, 58, 63]),
        .init(id: "six-drop-c", name: "Drop C", notes: [36, 43, 48, 53, 57, 62]),
        .init(id: "six-drop-b", name: "Drop B", notes: [35, 42, 47, 52, 56, 61]),
        .init(id: "six-drop-a", name: "Drop A", notes: [33, 40, 45, 50, 54, 59]),
        .init(id: "six-dadgad", name: "DADGAD", notes: [38, 45, 50, 55, 57, 62]),
        .init(id: "six-open-d", name: "Open D", notes: [38, 45, 50, 54, 57, 62]),
        .init(id: "six-open-g", name: "Open G", notes: [38, 43, 50, 55, 59, 62]),
        .init(id: "six-open-e", name: "Open E", notes: [40, 47, 52, 56, 59, 64]),
        .init(id: "six-open-c", name: "Open C", notes: [36, 43, 48, 55, 60, 64]),
        .init(id: "seven-standard", name: "Standard B", notes: [35, 40, 45, 50, 55, 59, 64]),
        .init(id: "seven-bb", name: "B♭ standard", notes: [34, 39, 44, 49, 54, 58, 63]),
        .init(id: "seven-a", name: "A standard", notes: [33, 38, 43, 48, 53, 57, 62]),
        .init(id: "seven-drop-a", name: "Drop A", notes: [33, 40, 45, 50, 55, 59, 64]),
        .init(id: "seven-drop-ab", name: "Drop A♭", notes: [32, 39, 44, 49, 54, 58, 63]),
        .init(id: "seven-drop-g", name: "Drop G", notes: [31, 38, 43, 48, 53, 57, 62]),
        .init(id: "seven-drop-fs", name: "Drop F♯", notes: [30, 37, 42, 47, 52, 56, 61]),
        .init(id: "seven-open-g", name: "Open G", notes: [31, 38, 43, 47, 50, 55, 62])
    ]
}

/// A configuration notification can describe our own startup or an unrelated
/// output change. Only a stopped engine or a changed input needs rebuilding.
struct TunerInputConfiguration: Equatable {
    let deviceID: UInt32
    let sampleRate: Double
    let channelCount: UInt32
}

struct TunerCaptureRecovery {
    private var restartTimes = [TimeInterval]()

    static func needsRestart(isRunning: Bool, expected: TunerInputConfiguration?,
                             current: TunerInputConfiguration?) -> Bool {
        !isRunning || expected == nil || current == nil || expected != current
    }

    mutating func allowRestart(at uptime: TimeInterval) -> Bool {
        restartTimes.removeAll { uptime - $0 >= 10 }
        guard restartTimes.count < 3 else { return false }
        restartTimes.append(uptime)
        return true
    }
}

#if !PITCH_DETECTOR_CHECKS
import SwiftUI
import AVFoundation
import CoreAudio
import AudioToolbox

// Avoid the SDK's newer @State macro when compiling with Command Line Tools.
private typealias TunerState<Value> = SwiftUI.State<Value>

private enum BuiltInMicrophone {
    static func find() -> (AudioDeviceID, String)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty else { return nil }
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return nil }
        for device in devices {
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                             mScope: kAudioObjectPropertyScopeGlobal,
                                                             mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var inputAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                         mScope: kAudioDevicePropertyScopeInput,
                                                         mElement: kAudioObjectPropertyElementMain)
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &inputAddress, 0, nil, &inputSize) == noErr,
                  inputSize > 0 else { continue }
            var deviceNameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            let nameStatus = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &deviceNameRef)
            let deviceName: String
            if nameStatus == noErr, let reference = deviceNameRef { deviceName = reference.takeRetainedValue() as String }
            else { deviceName = "Built-in microphone" }
            return (device, deviceName)
        }
        return nil
    }
}

/// The render callback only copies a buffer and enqueues work. A nonblocking
/// gate bounds the backlog; discontinuities discard the old sample history.
private final class TunerAnalysisWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FretFlow.pitch-analysis", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)
    private var history = [Float]()
    private var nextSampleTime: AVAudioFramePosition?
    private var tracker = GuitarPitchTracker()
    private var lastRate: Double = 0

    func accept(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime,
                deliver: @escaping @Sendable (PitchEstimate) -> Void) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0,
              gate.wait(timeout: .now()) == .success else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let sampleRate = buffer.format.sampleRate
        let sampleTime = time.isSampleTimeValid ? time.sampleTime : nil
        queue.async { [self] in
            defer { gate.signal() }
            if lastRate != sampleRate || (sampleTime != nil && nextSampleTime != nil && sampleTime != nextSampleTime) {
                history.removeAll(keepingCapacity: true)
                tracker.reset()
            }
            lastRate = sampleRate
            nextSampleTime = sampleTime.map { $0 + AVAudioFramePosition(samples.count) }
            history.append(contentsOf: samples)
            let windowSize = max(4_096, Int(sampleRate * 0.17))
            guard history.count >= windowSize else { return }
            if history.count > windowSize { history.removeFirst(history.count - windowSize) }
            let estimate = GuitarPitchDetector.estimate(samples: history, sampleRate: sampleRate)
            deliver(tracker.update(estimate, at: ProcessInfo.processInfo.systemUptime))
        }
    }
}

@MainActor
final class GuitarTunerModel: ObservableObject {
    @Published var isListening = false
    @Published var isReconnecting = false
    @Published var isRequestingPermission = false
    @Published var frequency: Double?
    @Published var confidence: Double = 0
    @Published var inputLevel: Double = 0
    @Published var status = "Ready when you are. Start the microphone, then pluck one open string."
    @Published var hasError = false
    @Published var permissionDenied = false
    @Published var inputName = "MacBook built-in microphone"
    @Published var customTunings: [GuitarTuning] = []
    @Published var mode = "6 strings" { didSet { selectedString = nil; ensureTuningFits() } }
    @Published var tuningID = "six-standard" { didSet { selectedString = nil } }
    @Published var selectedString: Int?
    @Published var concertA: Double = 440 {
        didSet { UserDefaults.standard.set(concertA, forKey: "FretFlow.tuner.concertA") }
    }
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var configurationTask: Task<Void, Never>?
    private var inputConfiguration: TunerInputConfiguration?
    private var captureRecovery = TunerCaptureRecovery()
    private var tapInstalled = false
    private var generation = UUID()

    init() {
        if let data = UserDefaults.standard.data(forKey: "FretFlow.tuner.custom"),
           let saved = try? JSONDecoder().decode([GuitarTuning].self, from: data) {
            customTunings = saved.filter { (6...7).contains($0.notes.count) && $0.notes.allSatisfy { (28...88).contains($0) } }
        }
        let storedA = UserDefaults.standard.double(forKey: "FretFlow.tuner.concertA")
        if (430...450).contains(storedA) { concertA = storedA }
    }

    var tunings: [GuitarTuning] {
        (GuitarTuning.presets + customTunings).filter { $0.notes.count == (mode == "7 strings" ? 7 : 6) }
    }
    var tuning: GuitarTuning { tunings.first(where: { $0.id == tuningID }) ?? tunings[0] }
    var isCustomTuning: Bool { customTunings.contains { $0.id == tuningID } }
    var targetIndex: Int? {
        guard mode != "Chromatic" else { return nil }
        if let selectedString, tuning.notes.indices.contains(selectedString) { return selectedString }
        guard let frequency else { return nil }
        return tuning.notes.indices.min {
            abs(GuitarPitch.cents(frequency: frequency, target: GuitarPitch.frequency(midi: tuning.notes[$0], concertA: concertA))) <
            abs(GuitarPitch.cents(frequency: frequency, target: GuitarPitch.frequency(midi: tuning.notes[$1], concertA: concertA)))
        }
    }
    var targetMidi: Int? {
        if mode == "Chromatic" {
            return frequency.map { GuitarPitch.midi(frequency: $0, concertA: concertA) }
        }
        return targetIndex.map { tuning.notes[$0] }
    }
    var cents: Double? {
        guard let frequency, let targetMidi else { return nil }
        return GuitarPitch.cents(frequency: frequency, target: GuitarPitch.frequency(midi: targetMidi, concertA: concertA))
    }
    var inTune: Bool { confidence >= 0.8 && (cents.map { abs($0) <= 3 } ?? false) }

    private func ensureTuningFits() {
        if !tunings.contains(where: { $0.id == tuningID }) { tuningID = tunings[0].id }
    }

    func saveTuning(name: String, notes: [Int], replacing id: String?) {
        let item = GuitarTuning(id: id ?? UUID().uuidString, name: name, notes: notes)
        if let index = customTunings.firstIndex(where: { $0.id == item.id }) { customTunings[index] = item }
        else { customTunings.append(item) }
        persistTunings()
        mode = notes.count == 7 ? "7 strings" : "6 strings"
        tuningID = item.id
    }

    func deleteCustomTuning() {
        customTunings.removeAll { $0.id == tuningID }
        persistTunings()
        ensureTuningFits()
    }

    private func persistTunings() {
        if let encoded = try? JSONEncoder().encode(customTunings) {
            UserDefaults.standard.set(encoded, forKey: "FretFlow.tuner.custom")
        }
    }

    func start() {
        guard !isListening, !isRequestingPermission else { return }
        hasError = false
        permissionDenied = false
        captureRecovery = TunerCaptureRecovery()
        generation = UUID()
        let requestGeneration = generation
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCapture()
        case .notDetermined:
            isRequestingPermission = true
            status = "Allow microphone access in the macOS prompt."
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.generation == requestGeneration else { return }
                    self.isRequestingPermission = false
                    if granted { self.beginCapture() }
                    else { self.showPermissionError() }
                }
            }
        default:
            showPermissionError()
        }
    }

    private func showPermissionError() {
        hasError = true
        permissionDenied = true
        status = "Microphone access is off. Allow FretFlow in System Settings → Privacy & Security → Microphone, then try again."
    }

    private struct CaptureError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func beginCapture() {
        let captureEngine = AVAudioEngine()
        engine = captureEngine
        // Never stop or dispose an engine on its notification thread. macOS
        // can post while start() is still establishing the hardware format.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                        object: captureEngine, queue: nil) { [weak self, weak captureEngine] _ in
            Task { @MainActor in
                guard let self, let captureEngine, self.engine === captureEngine, self.isListening else { return }
                self.scheduleConfigurationCheck(for: captureEngine)
            }
        }
        do {
            try configureAndStart(captureEngine)
            isListening = true
            if !captureEngine.isRunning { scheduleConfigurationCheck(for: captureEngine) }
        } catch {
            stop()
            hasError = true
            status = "Could not start the microphone: \(error.localizedDescription)"
        }
    }

    private func currentInputConfiguration(_ captureEngine: AVAudioEngine) -> TunerInputConfiguration? {
        let input = captureEngine.inputNode
        guard let unit = input.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &deviceID, &size) == noErr else { return nil }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return TunerInputConfiguration(deviceID: deviceID, sampleRate: format.sampleRate, channelCount: format.channelCount)
    }

    private func configureAndStart(_ captureEngine: AVAudioEngine) throws {
        guard let (deviceID, deviceName) = BuiltInMicrophone.find() else {
            throw CaptureError("No built-in microphone was found. This tuner expects your MacBook’s microphone.")
        }
        let input = captureEngine.inputNode
        guard let unit = input.audioUnit else {
            throw CaptureError("The microphone could not be opened. Close other audio tools and try again.")
        }
        var activeDevice = AudioDeviceID(0)
        var activeDeviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let readStatus = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, 0, &activeDevice, &activeDeviceSize)
        // Reassigning an already-selected input unnecessarily reconfigures the
        // engine and can cause the startup notification that stopped tuning.
        if readStatus != noErr || activeDevice != deviceID {
            var selectedDevice = deviceID
            let deviceStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                   kAudioUnitScope_Global, 0, &selectedDevice,
                                                   UInt32(MemoryLayout<AudioDeviceID>.size))
            guard deviceStatus == noErr else {
                throw CaptureError("Could not select the built-in microphone. Check System Settings → Sound → Input, then try again.")
            }
        }
        guard let configuration = currentInputConfiguration(captureEngine), configuration.deviceID == deviceID else {
            throw CaptureError("The built-in microphone has no active audio input. Check Sound settings and try again.")
        }
        let worker = TunerAnalysisWorker()
        let captureGeneration = generation
        input.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [weak self] buffer, time in
            worker.accept(buffer, at: time) { [weak self] reading in
                Task { @MainActor in
                    guard let self, self.isListening, self.generation == captureGeneration else { return }
                    self.frequency = reading.frequency
                    self.confidence = reading.confidence
                    let decibels = 20 * log10(max(reading.rms, 0.00001))
                    self.inputLevel = max(0, min(1, (decibels + 90) / 90))
                    self.status = reading.frequency == nil
                        ? (reading.rms < GuitarPitchDetector.minimumRMS ? "Very quiet input — move the guitar closer to your MacBook and pluck one string." : "Finding a steady note — mute the other strings and let one ring.")
                        : "Listening through \(self.inputName)."
                }
            }
        }
        tapInstalled = true
        captureEngine.prepare()
        try captureEngine.start()
        inputConfiguration = configuration
        inputName = deviceName
        isReconnecting = false
        status = "Listening — pluck one open string near your MacBook."
    }

    private func scheduleConfigurationCheck(for captureEngine: AVAudioEngine) {
        configurationTask?.cancel()
        let checkGeneration = generation
        configurationTask = Task { @MainActor [weak self, weak captureEngine] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self, let captureEngine, !Task.isCancelled,
                  self.generation == checkGeneration, self.isListening, self.engine === captureEngine else { return }
            self.configurationTask = nil
            self.reconcileCapture(captureEngine)
        }
    }

    private func reconcileCapture(_ captureEngine: AVAudioEngine) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            stop()
            showPermissionError()
            return
        }
        guard TunerCaptureRecovery.needsRestart(isRunning: captureEngine.isRunning,
                                                expected: inputConfiguration,
                                                current: currentInputConfiguration(captureEngine)) else { return }
        guard captureRecovery.allowRestart(at: ProcessInfo.processInfo.systemUptime) else {
            stop()
            hasError = true
            status = "The microphone could not reconnect after an audio change. Check Sound settings, then start the microphone again."
            return
        }
        generation = UUID()
        isReconnecting = true
        frequency = nil
        inputLevel = 0
        confidence = 0
        status = "Reconnecting to your MacBook microphone…"
        captureEngine.stop()
        if tapInstalled { captureEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        inputConfiguration = nil
        do {
            // Keep the same engine, but rebuild its tap with fresh sample
            // history and the new hardware format before restarting it.
            try configureAndStart(captureEngine)
            if !captureEngine.isRunning { scheduleConfigurationCheck(for: captureEngine) }
        } catch {
            captureEngine.stop()
            if tapInstalled { captureEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            isReconnecting = true
            scheduleConfigurationCheck(for: captureEngine)
        }
    }

    func stop() {
        generation = UUID()
        isRequestingPermission = false
        configurationTask?.cancel()
        configurationTask = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        tapInstalled = false
        engine = nil
        inputConfiguration = nil
        isListening = false
        isReconnecting = false
        frequency = nil
        inputLevel = 0
        confidence = 0
        hasError = false
        status = "Microphone stopped."
    }
}

private enum TunerColors {
    static let label = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let background = Color(nsColor: .controlBackgroundColor)
    static let card = Color(nsColor: .windowBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
}

struct TunerView: View {
    @StateObject private var tuner = GuitarTunerModel()
    @TunerState private var showingCustom = false
    @TunerState private var editingTuning: GuitarTuning?

    private var tint: Color { tuner.inTune ? .green : .accentColor }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Get in tune").font(.largeTitle.weight(.semibold))
                        Text("Your guitar, your tuning, your MacBook microphone.")
                            .foregroundStyle(TunerColors.secondary)
                    }
                    Spacer()
                    Button {
                        tuner.isListening ? tuner.stop() : tuner.start()
                    } label: {
                        Label(tuner.isListening ? "Stop microphone" : "Start microphone",
                              systemImage: tuner.isListening ? "mic.slash" : "mic")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(tuner.isRequestingPermission)
                }
                HStack(spacing: 20) {
                    Picker("Instrument", selection: $tuner.mode) {
                        Text("6 strings").tag("6 strings")
                        Text("7 strings").tag("7 strings")
                        Text("Chromatic").tag("Chromatic")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 370)
                    if tuner.mode != "Chromatic" {
                        Picker("Tuning", selection: $tuner.tuningID) {
                            ForEach(tuner.tunings) { tuning in Text(tuning.name).tag(tuning.id) }
                        }
                        .frame(maxWidth: 300)
                    }
                    Spacer(minLength: 0)
                }

                VStack(spacing: 20) {
                    HStack(spacing: 8) {
                        Circle().fill(tuner.isReconnecting ? Color.orange : (tuner.isListening ? Color.green : TunerColors.secondary.opacity(0.4))).frame(width: 7, height: 7)
                        Text(tuner.isReconnecting ? "RECONNECTING" : (tuner.isListening ? "MICROPHONE ON" : "MICROPHONE OFF"))
                            .font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(TunerColors.secondary)
                    }
                    VStack(spacing: 4) {
                        Text(tuner.targetMidi.map { GuitarPitch.name(midi: $0, octave: false) } ?? "—")
                            .font(.system(size: 86, weight: .medium, design: .rounded))
                            .foregroundStyle(tuner.frequency == nil ? TunerColors.secondary : tint)
                            .contentTransition(.numericText())
                        Text(pitchCaption).font(.system(.body, design: .monospaced)).foregroundStyle(TunerColors.secondary)
                    }
                    CentsMeter(cents: tuner.cents, isInTune: tuner.inTune)
                        .frame(height: 74)
                        .padding(.horizontal, 25)
                    Text(tuningInstruction)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(tuner.inTune ? Color.green : TunerColors.label)
                        .frame(height: 28)

                    if tuner.mode != "Chromatic" {
                        HStack(spacing: 10) {
                            ForEach(tuner.tuning.notes.indices, id: \.self) { index in
                                stringButton(index)
                            }
                        }
                        HStack {
                            Text("Lowest → highest string").font(.caption).foregroundStyle(TunerColors.secondary)
                            Spacer()
                            Button(tuner.selectedString == nil ? "Automatic string detection" : "Use automatic detection") {
                                tuner.selectedString = nil
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(tuner.selectedString == nil)
                        }
                    }
                    HStack(spacing: 16) {
                        Label("Input", systemImage: "waveform").font(.caption).foregroundStyle(TunerColors.secondary)
                        ProgressView(value: tuner.inputLevel).tint(tuner.inputLevel > 0.92 ? .orange : .accentColor)
                            .frame(maxWidth: 220)
                        Spacer()
                        Text(tuner.frequency == nil ? "Waiting for a clear note" : (tuner.confidence < 0.8 ? "Listening…" : "Confidence \(Int(tuner.confidence * 100))%"))
                            .font(.caption).foregroundStyle(TunerColors.secondary)
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity)
                .background(TunerColors.card, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(TunerColors.separator))

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: tuner.hasError ? "exclamationmark.circle" : "info.circle")
                        .foregroundStyle(tuner.hasError ? Color.orange : TunerColors.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tuner.status).font(.callout).foregroundStyle(tuner.hasError ? Color.orange : TunerColors.secondary)
                        Text("For an unplugged electric, keep the guitar close to your MacBook, mute the other strings, and pluck one open string. Select its string button if automatic selection is uncertain. Audio stays on your Mac and is never saved.")
                            .font(.caption).foregroundStyle(TunerColors.secondary)
                        if tuner.permissionDenied {
                            Button("Open microphone settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                            }.buttonStyle(.link)
                        }
                    }
                    Spacer()
                }
                Divider()
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Reference pitch").font(.headline)
                        Stepper(value: $tuner.concertA, in: 430...450, step: 0.5) {
                            Text("A4 = \(tuner.concertA, specifier: "%.1f") Hz")
                                .font(.system(.body, design: .monospaced))
                        }.frame(width: 215)
                    }
                    Spacer()
                    if tuner.isCustomTuning && tuner.mode != "Chromatic" {
                        Button("Edit tuning") {
                            editingTuning = tuner.tuning
                            showingCustom = true
                        }
                        Button("Delete", role: .destructive) { tuner.deleteCustomTuning() }
                    }
                    Button {
                        editingTuning = nil
                        showingCustom = true
                    } label: { Label("Custom tuning", systemImage: "plus") }
                }
            }
            .padding(32)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(TunerColors.label)
        .background(TunerColors.background)
        .onDisappear { tuner.stop() }
        .sheet(isPresented: $showingCustom) {
            CustomTuningSheet(existing: editingTuning, defaultCount: tuner.mode == "7 strings" ? 7 : 6) { name, notes, id in
                tuner.saveTuning(name: name, notes: notes, replacing: id)
            }
        }
    }

    private var pitchCaption: String {
        guard let frequency = tuner.frequency else {
            if let targetMidi = tuner.targetMidi { return "Target \(GuitarPitch.name(midi: targetMidi))" }
            return "Pluck an open string"
        }
        let heard = GuitarPitch.name(midi: GuitarPitch.midi(frequency: frequency, concertA: tuner.concertA))
        let target = tuner.targetMidi.map { GuitarPitch.name(midi: $0) } ?? heard
        return String(format: "%.1f Hz  ·  Heard %@  ·  Target %@", frequency, heard, target)
    }

    private var tuningInstruction: String {
        if tuner.isReconnecting { return "Reconnecting microphone…" }
        guard let cents = tuner.cents else { return tuner.isListening ? "Let one string ring" : "Start the microphone to tune" }
        if tuner.confidence < 0.8 { return "Let one string ring" }
        if tuner.selectedString != nil && abs(cents) > 700 {
            return "Different octave — check the selected string"
        }
        if abs(cents) <= 3 { return "In tune" }
        return String(format: "%@  ·  %.0f cents %@", cents < 0 ? "Tune up" : "Tune down", abs(cents), cents < 0 ? "flat" : "sharp")
    }

    private func stringButton(_ index: Int) -> some View {
        let isActive = tuner.targetIndex == index
        let manuallySelected = tuner.selectedString == index
        return Button {
            tuner.selectedString = manuallySelected ? nil : index
        } label: {
            VStack(spacing: 5) {
                Text("\(tuner.tuning.notes.count - index)").font(.caption2).foregroundStyle(TunerColors.secondary)
                Text(GuitarPitch.name(midi: tuner.tuning.notes[index], octave: false)).font(.title3.weight(.semibold))
                Text(GuitarPitch.name(midi: tuner.tuning.notes[index])).font(.caption2).foregroundStyle(TunerColors.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isActive ? tint.opacity(0.13) : TunerColors.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? tint : Color.clear, lineWidth: manuallySelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("String \(tuner.tuning.notes.count - index), \(GuitarPitch.name(midi: tuner.tuning.notes[index]))")
        .accessibilityHint("Select this string as the tuning target")
    }
}

private struct CentsMeter: View {
    let cents: Double?
    let isInTune: Bool
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(TunerColors.separator)
                    .frame(height: 5)
                    .offset(y: 29)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.green.opacity(0.35))
                    .frame(width: width * 0.06, height: 11)
                    .position(x: width / 2, y: 31)
                ForEach([-50, -25, 0, 25, 50], id: \.self) { mark in
                    let x = width * (Double(mark) + 50) / 100
                    Rectangle().fill(TunerColors.secondary.opacity(0.45))
                        .frame(width: 1, height: mark == 0 ? 22 : 12)
                        .position(x: x, y: 30)
                    Text(mark == 0 ? "IN TUNE" : "\(mark > 0 ? "+" : "")\(mark)")
                        .font(.system(size: 10, weight: mark == 0 ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(TunerColors.secondary)
                        .position(x: x, y: 60)
                }
                if let cents {
                    let clamped = max(-50, min(50, cents))
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(isInTune ? Color.green : Color.accentColor)
                        .position(x: width * (clamped + 50) / 100, y: 13)
                        .animation(.linear(duration: 0.1), value: clamped)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tuning accuracy")
        .accessibilityValue(cents.map { String(format: "%.0f cents %@", abs($0), $0 < 0 ? "flat" : "sharp") } ?? "No pitch detected")
    }
}

private struct CustomTuningSheet: View {
    let existing: GuitarTuning?
    let save: (String, [Int], String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @TunerState private var name: String
    @TunerState private var notes: [String]
    @TunerState private var stringCount: Int

    init(existing: GuitarTuning?, defaultCount: Int, save: @escaping (String, [Int], String?) -> Void) {
        self.existing = existing
        self.save = save
        _name = State(initialValue: existing?.name ?? "")
        let count = existing?.notes.count ?? defaultCount
        _stringCount = State(initialValue: count)
        let initial = existing?.notes ?? (count == 7 ? [35, 40, 45, 50, 55, 59, 64] : [40, 45, 50, 55, 59, 64])
        _notes = State(initialValue: initial.map { GuitarPitch.name(midi: $0) })
    }

    private var parsed: [Int]? {
        let result = notes.compactMap { GuitarPitch.parse($0) }
        return result.count == stringCount ? result : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existing == nil ? "Save a custom tuning" : "Edit custom tuning").font(.title2.weight(.semibold))
            TextField("Tuning name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Strings", selection: $stringCount) {
                Text("6 strings").tag(6)
                Text("7 strings").tag(7)
            }.pickerStyle(.segmented)
            Text("Enter pitches from your lowest string to your highest, including the octave. Examples: B1, E2, F♯2, B♭2.")
                .font(.callout).foregroundStyle(TunerColors.secondary)
            HStack(spacing: 10) {
                ForEach(notes.indices, id: \.self) { index in
                    VStack(spacing: 8) {
                        Text("String \(stringCount - index)").font(.caption).foregroundStyle(TunerColors.secondary)
                        TextField("E2", text: $notes[index])
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            Text(parsed == nil ? "Use valid notes from E1 through E6, including an octave number." : "This tuning will be saved on this Mac.")
                .font(.caption).foregroundStyle(parsed == nil ? Color.orange : TunerColors.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save tuning") {
                    guard let parsed else { return }
                    save(name.trimmingCharacters(in: .whitespacesAndNewlines), parsed, existing?.id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsed == nil)
            }
        }
        .padding(28)
        .frame(width: 610)
        .foregroundStyle(TunerColors.label)
        .background(TunerColors.card)
        .onChange(of: stringCount) { _, newValue in
            if newValue == 7 && notes.count == 6 { notes.insert("B1", at: 0) }
            else if newValue == 6 && notes.count == 7 { notes.removeFirst() }
        }
    }
}
#endif
