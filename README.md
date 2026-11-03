# FretFlow

A local macOS guitar practice app with PDF tab books, interactive Guitar Pro scores, YouTube playback, practice loops, and a microphone tuner.

## Supported files

- **PDF:** page navigation, zoom, saved reading position, and named song sections within books. Each section can have its own video and practice loops. PDF measure following and score-based clicks are not supported.
- **Guitar Pro:** `.gp`, `.gp3`, `.gp4`, `.gp5`, and `.gpx`, with interactive notation, experimental recording alignment, and score-based clicks.

Import your own tabs with **Add tabs**. Originals are unchanged; personal scores are not included in this repository. Tab processing and tuner audio stay on your Mac.

## Requirements

macOS 14+, Xcode 16+ or Command Line Tools with a macOS 15+ SDK, and internet access for YouTube. No API key is needed for playback or manual video links. Optional recording suggestions require a locally configured YouTube Data API key; see [verification and configuration](docs/VERIFICATION.md).

## Build and run

```sh
zsh scripts/build.sh
open dist/FretFlow.app
```

## Basic usage

1. **Add tabs**, then select a PDF or Guitar Pro score. Right-click a library entry to edit its title, artist, collection, or add a song using a PDF page range.
2. Navigate PDF pages with the reader toolbar; choose a zoom or Fit. Reading position and zoom are saved per entry.
3. Paste a YouTube URL and choose **Link video**, or search optional suggestions and confirm a recording. Playback position and accepted speed are saved per song and video, without autoplay on reopening.
4. Set A/B around a section, give the loop a name, and save it. Choose a saved loop, then Play; optionally enable the four-beat count-in at your chosen tempo. PDF tempo is not inferred.
5. Open **Tuner**, choose a 6/7-string preset, custom tuning, or chromatic mode, and start the MacBook microphone. Audio is processed locally.

Run offline checks with `bash scripts/check.sh`. Linux runs Node checks and any available portable Swift checks; native UI, audio and live playback require a Mac. See [verification](docs/VERIFICATION.md) for limitations and manual checks.
