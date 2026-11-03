#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/cache
swiftc -O -swift-version 5 -module-cache-path .build/cache -D PITCH_DETECTOR_CHECKS \
  Sources/FretFlow/Tuner.swift Tests/TunerChecks.swift -o .build/tuner-checks
.build/tuner-checks
swiftc -O -swift-version 5 -module-cache-path .build/cache \
  Sources/FretFlow/PlaybackClock.swift Sources/FretFlow/YouTubeController.swift Tests/YouTubeChecks.swift -o .build/youtube-checks
.build/youtube-checks
swiftc -O -swift-version 5 -module-cache-path .build/cache \
  Sources/FretFlow/PlaybackClock.swift Sources/FretFlow/YouTubeController.swift Tests/YouTubeDOMClockChecks.swift -o .build/youtube-dom-clock-checks
.build/youtube-dom-clock-checks
swiftc -O -swift-version 5 -module-cache-path .build/cache \
  Sources/FretFlow/PlaybackClock.swift Tests/PlaybackClockChecks.swift -o .build/playback-clock-checks
.build/playback-clock-checks
swiftc -O -swift-version 5 -module-cache-path .build/cache -D CLICK_TRACK_CHECKS \
  Sources/FretFlow/ClickTrack.swift Tests/ClickTrackChecks.swift -o .build/click-track-checks
.build/click-track-checks
swiftc -O -swift-version 5 -module-cache-path .build/cache \
  Sources/FretFlow/RecordingSyncStore.swift Tests/RecordingSyncChecks.swift -o .build/recording-sync-checks
.build/recording-sync-checks
swiftc -O -swift-version 5 -module-cache-path .build/cache \
  Sources/FretFlow/RecordingOnsetMatcher.swift Tests/RecordingOnsetChecks.swift -o .build/recording-onset-checks
.build/recording-onset-checks
swiftc -O -swift-version 5 -module-cache-path .build/cache \
  Sources/FretFlow/RecordingPlaybackClock.swift Tests/RecordingPlaybackClockChecks.swift -o .build/recording-clock-checks
.build/recording-clock-checks
swiftc -O -swift-version 5 -module-cache-path .build/cache \
  Sources/FretFlow/RecordingAutoSync.swift Sources/FretFlow/RecordingOnsetMatcher.swift \
  Sources/FretFlow/RecordingPlaybackClock.swift Tests/RecordingAutoSyncChecks.swift -o .build/recording-auto-sync-checks
.build/recording-auto-sync-checks
swiftc -O -swift-version 5 -module-cache-path .build/cache \
  Sources/FretFlow/PlaybackAudioCapture.swift Tests/PlaybackAudioEnvelopeChecks.swift -o .build/playback-audio-envelope-checks
.build/playback-audio-envelope-checks
node Tests/youtube-player-checks.cjs Resources/YouTube.html
node Tests/youtube-clock-checks.cjs
GP_FIXTURES="${FRET_FLOW_GP_DIR:-$ROOT/Resources/Library}"
if node -e 'const fs = require("node:fs"); const dir = process.argv[1]; process.exit(fs.existsSync(dir) && fs.readdirSync(dir).some(name => /\.(gp[345]?|gpx)$/i.test(name)) ? 0 : 1)' "$GP_FIXTURES"; then
  node Tests/timeline-checks.cjs "$GP_FIXTURES"
  if [[ -n "${FRET_FLOW_GP_DIR:-}" ]]; then
    node Tests/click-grid-checks.cjs "$GP_FIXTURES"
  else
    node Tests/click-grid-checks.cjs
  fi
  # Browser checks additionally need Playwright (set NODE_PATH if installed elsewhere).
  if node -e 'require("playwright")' >/dev/null 2>&1; then
    node Tests/renderer-checks.cjs "$GP_FIXTURES"
  else
    print "Skipping browser rendering checks: Playwright is not installed."
  fi
else
  print "Skipping score-dependent timeline, click-grid, and renderer checks: no Guitar Pro fixtures in $GP_FIXTURES."
  print "Set FRET_FLOW_GP_DIR to a local fixture directory to run them. Personal scores are not included in the repository."
fi
