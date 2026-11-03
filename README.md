# FretFlow

A local macOS guitar practice app with interactive tabs, YouTube playback, a score-based click track, and a microphone tuner for 6- and 7-string guitars.

## Supported files

- **Guitar Pro:** `.gp`, `.gp3`, `.gp4`, `.gp5`, and `.gpx` for interactive tabs and score timing.
- **PDF:** reference viewing only; automatic highlighting and score-based clicks require Guitar Pro files.

Tab files are not included. Import your own using **Add tabs**.

## Requirements

- macOS 14 or later.
- Xcode 16+ or equivalent Command Line Tools with a macOS 15+ SDK to build.
- Internet access for YouTube playback. Tabs and the tuner work locally.

## Build and run

From the project folder:

```sh
zsh scripts/build.sh
open dist/FretFlow.app
```

## Getting started

1. Choose **Add tabs**, import a file, and select it in the library.
2. Link a matching YouTube video and press **Play**.
3. Select a guitar part, enable the click track, adjust playback speed, or set an A/B loop.
4. For tuning, open **Tuner**, choose a tuning or chromatic mode, and press **Start microphone**. Allow microphone access when prompted.

Automatic recording alignment is experimental; some recordings may need a manual timing adjustment. Audio from the tuner and playback analysis is processed locally and is not saved or uploaded.
