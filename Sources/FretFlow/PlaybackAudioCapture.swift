import Foundation
import Combine
import CoreAudio
import CoreMedia
import CoreGraphics
import ScreenCaptureKit

/// A short energy envelope, never a recording. The timestamp is the first
/// sample's presentation time converted to ProcessInfo.systemUptime seconds.
struct PlaybackAudioWindow: Equatable, Sendable {
    let hostTime: TimeInterval
    let duration: Double
    let rms: Double
    let peak: Double
    let flux: Double
}

/// Reduces PCM immediately to 10 ms energy windows. Raw audio is not retained.
/// The audio queue owns this value; the main actor receives only its envelopes.
struct PlaybackAudioEnvelope {
    private var sampleRate = 0.0
    private var targetFrames = 0
    private var frames = 0
    private var sumSquares = 0.0
    private var peak = 0.0
    private var windowStart = 0.0
    private var nextFrameTime: Double?
    private var previousRMS = 0.0

    mutating func reset() { self = PlaybackAudioEnvelope() }

    mutating func append(frameEnergy: Double, framePeak: Double,
                         at time: Double, rate: Double) -> PlaybackAudioWindow? {
        guard rate.isFinite, (8_000...192_000).contains(rate), time.isFinite,
              frameEnergy.isFinite, frameEnergy >= 0, framePeak.isFinite, framePeak >= 0 else {
            reset()
            return nil
        }
        if sampleRate != rate || (nextFrameTime != nil && abs(time - nextFrameTime!) > 0.002) {
            reset()
            sampleRate = rate
            targetFrames = max(1, Int((rate * 0.01).rounded()))
        }
        if frames == 0 { windowStart = time }
        sumSquares += frameEnergy
        peak = max(peak, framePeak)
        frames += 1
        nextFrameTime = time + 1 / rate
        guard frames >= targetFrames else { return nil }
        let rms = sqrt(sumSquares / Double(frames))
        let result = PlaybackAudioWindow(hostTime: windowStart, duration: Double(frames) / rate,
                                         rms: rms, peak: peak, flux: max(0, rms - previousRMS))
        previousRMS = rms
        frames = 0
        sumSquares = 0
        peak = 0
        return result
    }

    /// ScreenCaptureKit presentation times must be on the host clock. Refuse
    /// distant/unknown epochs rather than substituting callback arrival time.
    static func hostUptime(presentation: Double, hostClockNow: Double, uptimeNow: Double) -> Double? {
        guard presentation.isFinite, hostClockNow.isFinite, uptimeNow.isFinite else { return nil }
        let delay = presentation - hostClockNow
        guard (-2...0.25).contains(delay) else { return nil }
        return uptimeNow + delay
    }
}

private struct PlaybackAudioCaptureError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Captures only the current application's soundtrack. There is no display
/// output handler, microphone input, recording output, or audio file writer.
/// WebKit helpers are included through ScreenCaptureKit's application filter,
/// rather than by collecting WebKit processes belonging to unrelated apps.
@MainActor
final class PlaybackAudioCapture: ObservableObject {
    @Published private(set) var isStarting = false
    @Published private(set) var isCapturing = false
    @Published private(set) var error: String?
    var onWindow: ((PlaybackAudioWindow) -> Void)?
    var onFailure: ((String) -> Void)?

    /// Diagnostic only: this does not prompt. Do not use it to broaden the
    /// application-only filter or to bypass an OS permission decision.
    nonisolated static var hasScreenCapturePermission: Bool { CGPreflightScreenCaptureAccess() }

    private var generation: UInt64 = 0
    private var stream: SCStream?
    private var receiver: PlaybackAudioReceiver?
    private let queue = DispatchQueue(label: "com.local.FretFlow.playback-analysis", qos: .userInitiated)

    deinit {
        if let stream { Task { try? await stream.stopCapture() } }
    }

    func start() async throws {
        try Task.checkCancellation()
        generation &+= 1
        let ticket = generation
        let oldStream = stream
        stream = nil
        receiver = nil
        isStarting = true
        isCapturing = false
        error = nil
        if let oldStream { try? await oldStream.stopCapture() }
        guard ticket == generation, !Task.isCancelled else { throw CancellationError() }

        var candidate: SCStream?
        do {
            let content: SCShareableContent
            if #available(macOS 14.4, *) {
                // The OS can provide only this process's shareable metadata.
                let ownContent = try await SCShareableContent.currentProcess
                if !ownContent.displays.isEmpty,
                   ownContent.applications.contains(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) {
                    content = ownContent
                } else {
                    // Some releases redact the application/display list. The
                    // permission-backed discovery still yields exactly the same
                    // current-PID inclusion filter below, never a global filter.
                    guard ticket == generation, !Task.isCancelled else { throw CancellationError() }
                    content = try await SCShareableContent.current
                }
            } else {
                content = try await SCShareableContent.current
            }
            guard ticket == generation, !Task.isCancelled else { throw CancellationError() }
            guard let app = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
                throw PlaybackAudioCaptureError("FretFlow's playback audio could not be isolated. Keep its window open and try again.")
            }
            guard let display = content.displays.first else {
                throw PlaybackAudioCaptureError("No display is available for FretFlow's audio analysis. Keep the Mac awake and try again.")
            }
            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            // ScreenCaptureKit requires display geometry even for an audio-only
            // consumer. Never register screen output or access image buffers.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = false
            if #available(macOS 15.0, *) { configuration.captureMicrophone = false }

            let output = PlaybackAudioReceiver(onWindows: { [weak self] windows in
                Task { @MainActor in
                    guard let self, self.generation == ticket, self.isCapturing else { return }
                    for window in windows { self.onWindow?(window) }
                }
            }, onError: { [weak self] failure in
                Task { @MainActor in
                    guard let self, self.generation == ticket else { return }
                    let message = Self.description(for: failure)
                    self.error = message
                    self.cancel()
                    self.onFailure?(message)
                }
            })
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: output)
            candidate = newStream
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            stream = newStream
            receiver = output
            try await newStream.startCapture()
            guard ticket == generation, !Task.isCancelled else {
                try? await newStream.stopCapture()
                throw CancellationError()
            }
            isStarting = false
            isCapturing = true
        } catch {
            if let candidate { try? await candidate.stopCapture() }
            guard ticket == generation else { throw CancellationError() }
            stream = nil
            receiver = nil
            isStarting = false
            isCapturing = false
            if !(error is CancellationError) { self.error = Self.description(for: error) }
            throw error
        }
    }

    /// Synchronously invalidate delivery and detach the old stream. The cleanup
    /// task owns only that old stream, so it cannot stop a newly started one.
    func cancel() {
        if let oldStream = detach() { Task { try? await oldStream.stopCapture() } }
    }

    /// Await cleanup when the caller needs the old capture to be fully stopped.
    /// Invalidation still happens before the first suspension point.
    func stop() async {
        if let oldStream = detach() { try? await oldStream.stopCapture() }
    }

    private func detach() -> SCStream? {
        generation &+= 1
        let oldStream = stream
        stream = nil
        receiver = nil
        isStarting = false
        isCapturing = false
        return oldStream
    }

    private static func description(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain && nsError.code == -3801 {
            return "Allow FretFlow in System Settings > Privacy & Security > Screen & System Audio Recording, then try matching again."
        }
        return "Could not analyze FretFlow's playback: \(error.localizedDescription)"
    }
}

private final class PlaybackAudioReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onWindows: @Sendable ([PlaybackAudioWindow]) -> Void
    private let onError: @Sendable (Error) -> Void
    private var envelope = PlaybackAudioEnvelope()
    private var reportedInvalidBuffer = false

    init(onWindows: @escaping @Sendable ([PlaybackAudioWindow]) -> Void,
         onError: @escaping @Sendable (Error) -> Void) {
        self.onWindows = onWindows
        self.onError = onError
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError(error) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard !reportedInvalidBuffer, outputType == .audio, sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
                throw PlaybackAudioCaptureError("The playback audio format is unavailable.")
            }
            let asbd = description.pointee
            let sampleRate = asbd.mSampleRate
            let channels = Int(asbd.mChannelsPerFrame)
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            guard asbd.mFormatID == kAudioFormatLinearPCM,
                  asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  asbd.mBitsPerChannel == 32, (1...8).contains(channels),
                  asbd.mBytesPerFrame == UInt32(MemoryLayout<Float>.size * (nonInterleaved ? 1 : channels)),
                  sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
                  frames > 0, frames <= Int(sampleRate / 2) else {
                throw PlaybackAudioCaptureError("The playback audio format cannot be analyzed safely.")
            }
            let presentation = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            let hostClockNow = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            let uptimeNow = ProcessInfo.processInfo.systemUptime
            guard let start = PlaybackAudioEnvelope.hostUptime(presentation: presentation,
                                                               hostClockNow: hostClockNow, uptimeNow: uptimeNow) else {
                throw PlaybackAudioCaptureError("Playback audio arrived without a reliable timestamp. Try matching again.")
            }
            var windows = [PlaybackAudioWindow]()
            try sampleBuffer.withAudioBufferList { list, _ in
                guard list.count == (nonInterleaved ? channels : 1) else {
                    throw PlaybackAudioCaptureError("The playback audio channel layout is unsupported.")
                }
                let valuesPerBuffer = frames * (nonInterleaved ? 1 : channels)
                let buffers = try list.map { buffer -> UnsafeBufferPointer<Float> in
                    guard buffer.mNumberChannels == (nonInterleaved ? 1 : channels),
                          Int(buffer.mDataByteSize) >= valuesPerBuffer * MemoryLayout<Float>.size,
                          let data = buffer.mData else {
                        throw PlaybackAudioCaptureError("The playback audio buffer is incomplete.")
                    }
                    return UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: valuesPerBuffer)
                }
                for frame in 0..<frames {
                    var energy = 0.0
                    var peak = 0.0
                    for channel in 0..<channels {
                        let value = Double(nonInterleaved ? buffers[channel][frame] : buffers[0][frame * channels + channel])
                        guard value.isFinite else { throw PlaybackAudioCaptureError("The playback audio contains invalid samples.") }
                        energy += value * value
                        peak = max(peak, abs(value))
                    }
                    // Average channel energy, not signed amplitudes: opposite
                    // stereo phases must not erase an otherwise audible onset.
                    if let window = envelope.append(frameEnergy: energy / Double(channels), framePeak: peak,
                                                    at: start + Double(frame) / sampleRate, rate: sampleRate) {
                        windows.append(window)
                    }
                }
            }
            if !windows.isEmpty { onWindows(windows) }
        } catch {
            guard !reportedInvalidBuffer else { return }
            reportedInvalidBuffer = true
            onError(error)
        }
    }
}
