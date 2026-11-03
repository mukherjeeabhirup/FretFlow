// Opt-in integration check: opens an official studio upload, always muted.
// Compile with Sources/FretFlow/{PlaybackClock,YouTubeController}.swift. Run from the project folder.
import AppKit
import Foundation
import WebKit

@main struct YouTubeLiveSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = LiveDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class LiveDelegate: NSObject, NSApplicationDelegate {
    var controller: YouTubeController!
    var window: NSWindow!
    var timer: Timer?
    var start = Date()
    var stage = 0
    var played = false
    var slowed = false
    var sought = false
    var observedFreshClock = false
    var pauseStoppedClickClock = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = YouTubeController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FretFlow — muted playback check"
        window.contentView = controller.webView
        window.center(); window.makeKeyAndOrderFront(nil)
        controller.cue(videoID: "RLytwCPVpSk")
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func tick() {
        if stage == 0 && controller.isReady {
            stage = 1
            controller.webView.evaluateJavaScript("player.mute(); player.playVideo();", completionHandler: nil)
        }
        if stage == 1 && controller.hasFreshPlaybackClock && controller.position > 1 {
            observedFreshClock = true
            played = true; stage = 2
            controller.setRate(0.5)
        }
        if stage == 2 && controller.hasFreshPlaybackClock && controller.rate == 0.5 && controller.position > 1.5 {
            slowed = true; stage = 3
            controller.seek(to: 12)
        }
        if stage == 3 && controller.hasFreshPlaybackClock && controller.position >= 11.5 {
            sought = true; finish()
        } else if Date().timeIntervalSince(start) > 45 { finish() }
    }
    func finish() {
        timer?.invalidate()
        controller.pause()
        pauseStoppedClickClock = !controller.hasFreshPlaybackClock
        let result: [String: Any] = ["ready": controller.isReady, "playedMuted": played,
            "halfSpeed": slowed, "seeked": sought, "position": controller.position,
            "duration": controller.duration, "rate": controller.rate, "status": controller.status,
            "freshClickClock": observedFreshClock, "pauseStopsClickClockImmediately": pauseStoppedClickClock]
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/live-check")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(to: folder.appendingPathComponent("youtube.json"))
        controller.webView.takeSnapshot(with: nil) { image, _ in
            if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("youtube.png"))
            }
            NSApp.terminate(nil)
        }
    }
}
