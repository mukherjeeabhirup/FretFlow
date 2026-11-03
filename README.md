# FretFlow

A local macOS app for practicing guitar with interactive tablature, YouTube playback, a score-aware click track, and a microphone tuner.

FretFlow uses Guitar Pro files for structured notation and timing. PDFs can be opened as reference material. The interface is native SwiftUI/AppKit, with a bundled alphaTab renderer for the score and a separate embedded YouTube player.

## Features

- **Interactive tabs:** select guitar parts, follow the current measure, zoom, and click a measure to seek.
- **Practice controls:** A/B loops, repeat-aware measure navigation, and the playback speeds supported by the linked YouTube video.
- **Score-aware click:** tempo and meter changes, pickups, repeats, beam grouping, and written accents from the selected part. Click volume is independent of the video.
- **Recording alignment:** local analysis of the opening audio can estimate a start correction. Confident corrections are saved for the exact song, video, and score, and applied to tabs, clicks, seeks, and loop targets together.
- **Guitar tuner:** built-in MacBook microphone input, 6- and 7-string presets, standard/drop/lowered/open tunings, saved custom tunings, chromatic mode, and adjustable reference pitch.
- **Local library:** import Guitar Pro `.gp`, `.gp3`, `.gp4`, `.gp5`, `.gpx`, and PDF files.

## Current status

This is a personal application under active development. **Automatic alignment is experimental and does not reliably match every recording.** A start correction also cannot repair later edits, tempo drift, or a different arrangement.

The last playback validation, on October 26, 2026, used version **0.1.7, build 8**:

- Electric Sunrise completed the automatic first-play flow and saved a **+0.792-second** correction.
- Muted playback/click integration checks passed normal playback, half speed, seeking, pause, and resume.
- Every Piece Matters did not produce a confident match; its timing was left unchanged.
- Ciel exposed infrequent timing updates from the embedded player. The source includes a native polling fallback that compiles, but still needs dedicated polling tests and live playback validation.

The source is ahead of that installed build. This repository is a development snapshot, not a claim that all songs have been calibrated. The remaining synchronization work is to validate the polling fallback, inspect uncertain matches, and check more recordings without lowering confidence thresholds to force a result.

On November 3, 2026, a clean copy containing only repository files built and passed the native and offline YouTube checks with Swift 6.4.2 and the macOS 27.2 SDK. Score-dependent checks were explicitly skipped because private Guitar Pro fixtures were excluded. No live audio tests or installed-app update were performed for this repository preparation.

## Requirements

- macOS 14 or later. Development and device checks have been performed on Apple Silicon.
- Xcode 16 or newer, or equivalent Command Line Tools with a macOS 15+ SDK. The deployment target remains macOS 14; newer capture APIs are guarded by runtime availability checks. The build also uses the macOS `iconutil`, `codesign`, and `rsync` tools.
- An internet connection for YouTube playback. Score rendering and the tuner run locally.
- Node.js for JavaScript tests; Playwright and a compatible browser for optional renderer tests.

No Apple developer account, MusicKit configuration, YouTube API key, or paid service is required for the local build. YouTube playback availability remains subject to its own restrictions.

## Build and run

From the repository root:

```sh
xcode-select --install  # Only if the Command Line Tools are not installed.
zsh scripts/build.sh
open dist/FretFlow.app
```

The build script compiles the native sources, copies the renderer and other resources into an app bundle, and signs it locally for personal use. Its output is `dist/FretFlow.app`. It is not a notarized distribution build.

To install it in your user Applications folder, first quit any running copy of FretFlow, then:

```sh
mkdir -p "$HOME/Applications"
ditto dist/FretFlow.app "$HOME/Applications/FretFlow.app"
open "$HOME/Applications/FretFlow.app"
```

Use the app bundle or `open` to launch it normally. Launching the executable directly can affect how macOS attributes embedded-player audio, which matters for application-only capture.

`Package.swift` describes the native executable target, but `swift build` alone does not assemble the resources and metadata required by the desktop app. Use `scripts/build.sh` for a runnable bundle.

## Add music and practice

Purchased tab books and Guitar Pro scores are **not included in this repository**. Import your own files with **Add tabs**, select a song, then paste a matching YouTube link into the player panel and choose **Link video**.

1. Choose the guitar part you want to practice and press Play.
2. Use Follow to keep the current measure visible, or turn it off to read ahead.
3. Enable Click track to hear the score's beat and accent pattern. It is off on launch.
4. Use the Speed menu, set loop points A/B, or choose Loop this measure.
5. With automatic matching enabled, a new recording is restarted for an analysis pass. The click waits during matching. A confident result is saved; an uncertain result leaves the existing timeline unchanged.

**Match start** retries analysis. **Fine adjustment** provides a manual correction: positive values move tabs and clicks later; negative values move them earlier. Reset removes that recording's saved correction. Changing the timing clears an existing loop. Pause or Stop matching cancels a pending attempt.

PDFs do not supply automatic measure highlighting, score-derived clicks, or recording matching. Use a corresponding Guitar Pro file for those features.

## Tuner

Open **Tuner**, choose an instrument mode and tuning, and press **Start microphone**. Allow microphone access when macOS asks. If access was denied, enable FretFlow under **System Settings → Privacy & Security → Microphone**.

Pluck one open string and let it ring. Select a string to lock the target, or use automatic string selection. For an unplugged electric guitar, keep it near the MacBook microphone and mute the other strings. Opening the tuner pauses the video; leaving it stops microphone capture.

## Privacy and local data

- The tuner processes microphone input on the Mac. It does not save or upload audio or change the system's selected input device.
- Recording alignment analyzes only FretFlow's own playback through an application-specific ScreenCaptureKit filter. It does not use the microphone or capture screen images. Raw audio is processed in memory and is not saved or uploaded.
- macOS may request Screen & System Audio Recording permission for playback analysis. The exact prompt depends on the macOS version and its handling of an application's own audio.
- The score renderer uses bundled scripts and fonts. The separate YouTube player connects to YouTube and retains its normal controls, ads, and service restrictions. FretFlow does not download the video or extract an audio file.

Imported files are copied into `~/Library/Application Support/FretFlow/Imports/`; their originals remain unchanged. The saved library is in the same application-support directory. Video links, tuning settings, click volume, and recording corrections use local preferences under the bundle identifier `com.local.FretFlow`.

Generated builds, diagnostic output, and personal score files stay outside version control.

## Tests

The standard runner compiles native checks and runs the JavaScript suites:

```sh
zsh scripts/check.sh
```

The runner explicitly skips score-dependent checks when no Guitar Pro fixtures are available. The original development scores are not distributed here. For full score coverage, supply your own test files using `FRET_FLOW_GP_DIR`, or place them locally in `Resources/Library/`. Keep these files untracked.

```sh
FRET_FLOW_GP_DIR="/path/to/guitar-pro-fixtures" zsh scripts/check.sh
```

To test scores kept elsewhere, run the individual suites with their fixture directory:

```sh
node Tests/timeline-checks.cjs /path/to/guitar-pro-fixtures
node Tests/click-grid-checks.cjs /path/to/guitar-pro-fixtures
node Tests/renderer-checks.cjs /path/to/guitar-pro-fixtures
```

The renderer suite needs Playwright available to Node and an installed browser. It uses local Google Chrome when available; `FRET_FLOW_BROWSER_EXECUTABLE` selects another executable, and `FRET_FLOW_BROWSER` selects `chromium` or `webkit`. The main runner includes this suite only when it can resolve the `playwright` module.

Native checks cover pitch detection, click planning, playback clocks, saved corrections, onset matching, audio envelopes, and cancellation/retry behavior. Normal unit checks do not require microphone capture or live YouTube playback. Device and live-player checks are separate opt-in diagnostics. Read `Tests/YouTubeClickLiveChecks.swift`, `Sources/FretFlow/PlaybackCaptureDiagnostic.swift`, and `Sources/FretFlow/RecordingSyncSessionDiagnostic.swift` before running them: some play audio or save a real calibration, and the latter requires a matching song and linked video in the local library.

Synthetic tests do not establish real-guitar accuracy or physical speaker-to-screen synchronization. Those require testing on the actual device, recording, and audio output route.

## Project layout

| Path | Responsibility |
| --- | --- |
| `Sources/FretFlow/` | Native application, library, video bridge, tuner, click engine, and recording alignment |
| `Resources/Web/` | Bundled alphaTab renderer, timeline generation, notation layout, and fonts |
| `Resources/YouTube.html` | Embedded-player controls and metadata bridge |
| `Resources/YouTubeClock.js` | Read-only timing observations scoped to the current YouTube embed |
| `Resources/Library/` | Optional local score assets and library/video metadata |
| `Tests/` | Native, JavaScript, browser, and opt-in device checks |
| `scripts/` | App build, checks, and icon generation |

## Third-party software

The bundled **alphaTab 1.8.4** renderer is distributed under the Mozilla Public License 2.0. The bundled **Bravura** font uses the SIL Open Font License. Their notices and license texts are retained in [Resources/Web/THIRD-PARTY-NOTICES.txt](Resources/Web/THIRD-PARTY-NOTICES.txt) and `Resources/Web/vendor/`.

The upstream alphaTab bundle is unmodified; FretFlow's notation adjustments live in a separate adapter. Tab files and recordings retain their respective owners' rights. No license for the original application code has been selected in this repository.
