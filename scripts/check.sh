#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Offline synthetic checks always run, even without macOS or personal scores.
node Tests/youtube-player-checks.cjs Resources/YouTube.html
node Tests/youtube-clock-checks.cjs
node Tests/timeline-checks.cjs
node Tests/click-grid-checks.cjs

GP_FIXTURES="${FRET_FLOW_GP_DIR:-$ROOT/Resources/Library}"
if node -e 'const fs = require("node:fs"); const d = process.argv[1]; process.exit(fs.existsSync(d) && fs.readdirSync(d).some(n => /\.(gp[345]?|gpx)$/i.test(n)) ? 0 : 1)' "$GP_FIXTURES"; then
  if node -e 'require("playwright")' >/dev/null 2>&1; then
    node Tests/renderer-checks.cjs "$GP_FIXTURES"
  else
    echo "SKIP browser rendering: Playwright is not installed."
  fi
else
  echo "SKIP Guitar Pro fixture and renderer checks: no local scores. Synthetic timing checks ran."
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "SKIP all Swift checks: swiftc is not installed. Node checks passed; Swift remains unverified."
  exit 0
fi
mkdir -p .build/cache
run_swift() {
  local name="$1"
  shift
  swiftc -O -swift-version 5 -module-cache-path .build/cache "$@" -o ".build/$name"
  ".build/$name"
}
run_swift tuner-checks -D PITCH_DETECTOR_CHECKS Sources/FretFlow/Tuner.swift Tests/TunerChecks.swift
run_swift playback-clock-checks Sources/FretFlow/PlaybackClock.swift Tests/PlaybackClockChecks.swift
run_swift click-track-checks -D CLICK_TRACK_CHECKS Sources/FretFlow/ClickTrack.swift Tests/ClickTrackChecks.swift
run_swift recording-onset-checks Sources/FretFlow/RecordingOnsetMatcher.swift Tests/RecordingOnsetChecks.swift
run_swift recording-clock-checks Sources/FretFlow/RecordingPlaybackClock.swift Tests/RecordingPlaybackClockChecks.swift
run_swift practice-state-checks Sources/FretFlow/PracticeState.swift Tests/PracticeStateChecks.swift
run_swift youtube-clock-checks Sources/FretFlow/PlaybackClock.swift Sources/FretFlow/YouTubeController.swift Tests/YouTubeClockChecks.swift
run_swift youtube-dom-clock-checks Sources/FretFlow/PlaybackClock.swift Sources/FretFlow/YouTubeController.swift Tests/YouTubeDOMClockChecks.swift
run_swift video-suggestion-checks -parse-as-library Sources/FretFlow/VideoSuggestions.swift Tests/VideoSuggestionChecks.swift

if [[ "$(uname -s)" != Darwin ]]; then
  echo "SKIP macOS framework checks: AppKit, PDFKit, WebKit, Combine and audio capture require macOS."
  exit 0
fi
run_swift youtube-checks Sources/FretFlow/PlaybackClock.swift Sources/FretFlow/YouTubeController.swift Tests/YouTubeChecks.swift
run_swift recording-sync-checks Sources/FretFlow/RecordingSyncStore.swift Tests/RecordingSyncChecks.swift
run_swift recording-auto-sync-checks Sources/FretFlow/RecordingAutoSync.swift Sources/FretFlow/RecordingOnsetMatcher.swift Sources/FretFlow/RecordingPlaybackClock.swift Tests/RecordingAutoSyncChecks.swift
run_swift playback-audio-envelope-checks Sources/FretFlow/PlaybackAudioCapture.swift Tests/PlaybackAudioEnvelopeChecks.swift
