# Configuration and verification

## Optional YouTube recording suggestions

Playback, manual video links and external YouTube search need no API key. In-app recording suggestions use the official YouTube Data API v3 `search.list` endpoint with a title/artist query, `type=video`, embeddable/syndicated filters, and at most six results. Search does not start until the user requests it, and a result is linked only after **Use this video**. Titles/artists are editable before sending. No PDF text, pages or audio are sent. Availability and arrangement matching are not guaranteed.

Enable YouTube Data API v3 in your own Google Cloud project and restrict a key to that API. Each search consumes the project's quota. Configuration precedence:

1. **API setup (local)** secure field: held in memory for the current suggestion view only.
2. `FRETFLOW_YOUTUBE_API_KEY` in the app's launch environment.
3. `FretFlow.youtubeAPIKey` in the app's local UserDefaults (unencrypted; use only if appropriate locally).

Launching from Finder does not inherit arbitrary terminal environment variables. Use the in-memory field or launch the built executable from an environment configured locally. Do not put keys in the repository, command examples, screenshots, logs or PRs. No live API key was needed for the synthetic mocked tests, and no live API test was performed here.

Official references: [setup](https://developers.google.com/youtube/data/getting-started), [search.list](https://developers.google.com/youtube/data/reference/rest/v3/search/list), [API errors](https://developers.google.com/youtube/data/reference/rest/v3/errors).

## Persistence and privacy

Existing library JSON arrays and song IDs are retained, with optional fields for PDF sections, collections and duplicate detection. Video links and exact-score/video recording corrections keep their existing preferences and identities. New PDF reading and practice state use separate versioned preferences. Practice recording position, accepted speed and named loops are scoped by song and video; a replacement video does not inherit another recording's loop times. Opening a song restores a cued, paused position rather than autoplaying.

Imports keep originals unchanged. Sections share the imported PDF. Removing a library entry retains its imported file to protect other entries using it. PDF pages are restricted in an in-memory document, not a rewritten source. Preferences contain local titles, positions and loop names; they are not published. Private supplied files and derived artifacts stay outside all Git checkouts. Tests use independently created synthetic content only.

## Automated checks

Run `bash scripts/check.sh` from the checkout. It runs offline JavaScript player/clock simulations and synthetic score timeline/click-grid cases without requiring Guitar Pro files. If `swiftc` exists, it compiles portable pitch, clock, click-planning, onset-matching, practice-state and mocked suggestion checks. Native library/PDF, recording persistence, audio capture and controller checks additionally require macOS frameworks. Local Guitar Pro and Playwright renderer checks are optional; no personal fixture is bundled.

On this Linux machine, `bash scripts/check.sh` passes its Node checks and explicitly skips Swift because neither `swift` nor `swiftc` is installed. No compiler was installed. The added Swift tests and native app compilation remain unverified. `bash -n scripts/check.sh`, JavaScript syntax checks and Git whitespace checks are also run. No automated check here establishes real-song PDF synchronization.

## Manual verification on a Mac

Use a backup of the existing `~/Library/Application Support/FretFlow` folder and relevant app preferences before migration testing. Keep private originals and any diagnostic output outside all checkouts; do not attach tab screenshots or extracted text to issues/CI.

1. Run `bash scripts/check.sh`, then `zsh scripts/build.sh`. Launch `dist/FretFlow.app`. Resolve any compile/test failures before distributing the app. Confirm old imports, video links, custom tunings, concert A and recording calibrations remain available.
2. Import an independently created multipage PDF. Import identical bytes under a renamed file and verify no duplicate entry/file appears. Verify title/author fallback, title edits, collection search, and a normal Guitar Pro import. Simulate an unwritable library location and check that existing entries are retained and import errors are visible.
3. In a PDF, navigate by physical page number and previous/next; change zoom, Fit, scroll, switch songs and quit/relaunch. Verify each song restores its own page and zoom. Test the first/last page and an invalid page entry. Resize the window while Fit is selected. Test encrypted, unreadable and image-only PDFs for useful errors and view-only behavior.
4. Create two differently titled sections from one book, including overlapping ranges. Confirm navigation stays inside each range, page labels use original PDF page numbers, and each entry has independent page/zoom, video and loops. Verify the imported PDF bytes remain unchanged. If removing entries, confirm another section can still open its shared file.
5. Link a video manually. Seek, accept a supported slower speed, save two named A/B loops, switch songs and relaunch. Verify saved position/speed and loops return without autoplay; select a loop and press Play. Replace the recording, verify loops are isolated, then relink the previous video and confirm its state returns. Test with no network and with failed/slow cueing: saved positions must survive reset-to-zero placeholders.
6. Enable the four-beat count-in at a chosen BPM and press Play from a saved section. Verify pause acknowledgement, four visible/audible beats, then playback. Cancel during the count-in with Play/Pause, a seek, a speed change, a song change or Tuner. System alert sounds depend on macOS sound settings, and this convenience count-in is not a sample-accurate score click. No count-in is inferred from PDF notation; loop restarts do not automatically repeat it.
7. Test live YouTube startup, the infrequent iframe-update scenario, pause/play, buffering, forward/backward/small seeks, refused and accepted speeds, and loop restarts. Exercise the embedded controls too. Minimize/cover the app, change Spaces and return. Confirm clocks/clicks stop when progress is stale and resume only after fresh media-element movement. Native polling cannot overcome app/WebKit suspension; coarse iframe time must not enable clicks or recording analysis. Ads remain best-effort detection.
8. Expand recording suggestions without a key and verify local setup guidance. With a locally supplied restricted key, search an edited title, confirm a result, and relaunch to verify the saved link. Test no results, network loss, quota/key errors, cancel, rapid edits and song switching while a request is in flight. Stale results must not link to another song. Manual URLs must continue to work.
9. Permit the built-in MacBook microphone and try an unplugged electric in a real room. Cover quiet low notes, decay, stronger upper harmonics, genuine octave changes, 6/7-string presets, custom tunings, chromatic mode and concert A. Try denied permission and device interruption. Verify leaving Tuner stops capture. Synthetic signals do not establish actual guitar/microphone performance.
10. For a locally owned structured Guitar Pro score, verify part selection, measure seeking, repeats, tempo/meter changes, saved recording correction and clicks after buffering/seeking. PDF practice must never enable automatic measure following or score-derived clicks. Real-song PDF sync remains unsupported; see [PDF assessment](PDF-SYNC.md).

## Current limits

This host cannot build or run macOS SwiftUI/AppKit/PDFKit/WebKit, capture a microphone, or validate live YouTube playback. Swift logic tests were added but cannot run without a compiler. Suggestions are tested by synthetic/mock cases only. The clock fallback fails closed after 300 ms without fresh progress; background operation still depends on macOS/WebKit scheduling. The tuner detector and mic path were preserved; expanded synthetic tests remain distinct from real guitar testing. PDF recognition/timing is not implemented or claimed.
