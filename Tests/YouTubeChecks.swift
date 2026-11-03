// Offline regression checks: no WKWebView is created and no audio/network is used.
// Run from the FretFlow directory:
// swiftc -swift-version 5 -module-cache-path /tmp/fretflow-youtube-module-cache Sources/FretFlow/PlaybackClock.swift Sources/FretFlow/YouTubeController.swift Tests/YouTubeChecks.swift -o /tmp/fretflow-youtube-checks
// /tmp/fretflow-youtube-checks

import Foundation
@main struct YouTubeParserChecks {
 static func main() {
  let id = "abcdefghijk"
  let accepted = [id," https://youtu.be/\(id)?si=abc ","https://www.youtube.com/watch?v=\(id)&t=5","youtube.com/watch?v=\(id)","https://music.youtube.com/watch?v=\(id)","https://www.youtube.com/embed/\(id)","https://www.youtube.com/shorts/\(id)","https://www.youtube.com/live/\(id)"]
  let rejected = ["", "short", "https://evil.example/watch?v=\(id)", "https://youtube.com.evil.example/watch?v=\(id)", "https://youtube.com@evil.example/watch?v=\(id)", "https://evil@youtube.com/watch?v=\(id)", "javascript:alert(1)", "https://youtube.com/watch?v=\(id)&v=XXXXXXXXXXX", "https://youtube.com:1234/watch?v=\(id)", "https://youtu.be/\(id)/extra"]
  for input in accepted { precondition(YouTubeController.videoID(from:input) == id, "Should accept: \(input)") }
  for input in rejected { precondition(YouTubeController.videoID(from:input) == nil, "Should reject: \(input)") }
  print("Offline YouTube URL parser checks passed (18 cases).")
 }
}
