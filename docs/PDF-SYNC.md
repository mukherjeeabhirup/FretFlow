# PDF timing assessment

PDF practice is supported without Guitar Pro files. Automatic measure following, recording matching, and score-derived clicks remain disabled for PDFs. No scrolling timer, fixed recording offset, or guessed tempo is substituted for musical timing.

## Local assessment

The privately supplied archive was moved outside all checkouts before extraction. It contains six PDF documents and macOS metadata sidecars. Local MuPDF text/trace sampling of the first five pages of each document found mixed text, image, and vector content. Five documents opened successfully; one failed with this installed tool. The successful samples included extractable text and vertical vector segments, but text-layer searches did not establish tempo or meter. Cover images, layout paths, and isolated vertical lines cannot be treated as validated barlines. The assessment did not reconstruct or validate a complete measure timeline, repeats, rhythmic durations, or recording alignment.

Only these aggregate structural observations are documented. No PDF, page image, extracted text, score conversion, song title, or private fixture is committed. Originals are unchanged. MuPDF was used for local assessment, not added as an app dependency.

## Requirements for reliable synchronization

A supported recognition pipeline must establish and validate all of the following:

- Page geometry, staff/tab systems, and measure bounds, including scanned and rotated pages, with confidence and rejection rules.
- Rhythmic durations, voices, pickup measures, tempo markings and changes, beat units, meter, rests, tuplets, and ties. Tab fret numbers alone do not determine timing.
- Playback order through repeats, alternate endings, and navigation symbols, with a mapping back to printed page coordinates.
- An independently reviewed timeline and beat/accent grid, with explicit uncertainty. Low-confidence recognition must remain view-only.
- Recording-specific alignment and handling of lead-ins, drift, edits, buffering, seeking, and playback speed. A correct written timeline alone is insufficient.
- Synthetic public fixtures plus local manual comparison against the private originals on a Mac, without publishing derived artifacts.

Text and vector extraction can assist recognition and editable metadata, but the current evidence does not justify enabling measure synchronization for any of the supplied PDFs. The existing Guitar Pro path retains its structured timing and recording correction behavior.
