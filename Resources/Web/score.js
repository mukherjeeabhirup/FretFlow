(function () {
    'use strict';
    const status = document.getElementById('status');
    const viewport = document.getElementById('score-scroll');
    const at = window.alphaTab;
    const state = {songID: null, score: null, timeline: null, midi: null, tickLookup: null, selectedTrack: 0,
        offsetAdjustment: 0, alignmentRevision: 0,
        follow: true, zoom: 1, suppress: 0, rendered: false, lastMeasure: -1,
        clock: {position: 0, duration: 0, isPlaying: false, rate: 1},
        clockReceivedAt: 0, lastClockPosition: 0, loop: null, loadID: 0};
    let api;
    function post(type, values = {}) {
        const message = {type, ...values};
        if (Object.prototype.hasOwnProperty.call(values, 'songID')) message.alignmentRevision = state.alignmentRevision;
        if (window.webkit?.messageHandlers?.fretflow) window.webkit.messageHandlers.fretflow.postMessage(message);
        window.dispatchEvent(new CustomEvent('fretflow-message', {detail: message}));
    }
    function silent(action) {
        state.suppress++;
        try { return action(); } finally { state.suppress--; }
    }
    function showError(error) {
        const message = error?.message || String(error || 'Unable to display this score.');
        status.textContent = message;
        status.className = 'error';
        status.hidden = false;
        post('error', {songID: state.songID, message});
    }
    function positionNow() {
        let position = state.clock.position;
        // Smooth short gaps between native player snapshots; never extrapolate forever
        // through buffering, sleep, a stalled bridge, or a closed player.
        const elapsed = Math.min(0.35, Math.max(0, (performance.now() - state.clockReceivedAt) / 1000));
        if (state.clock.isPlaying) position += elapsed * state.clock.rate;
        return state.clock.duration > 0 ? Math.min(position, state.clock.duration) : position;
    }
    function effectiveRate() { return state.clock.rate / (state.timeline?.alignment.scale || 1); }
    function syncClock() {
        if (!api || !state.timeline || !api.isReadyForPlayback) return;
        const position = positionNow();
        const nominalTime = state.timeline.toScore(position);
        const scoreTime = Math.min(Math.max(0, state.timeline.scoreDuration - 0.002), nominalTime);
        const clockFresh = performance.now() - state.clockReceivedAt <= 350;
        const playingWithinScore = state.clock.isPlaying && clockFresh
            && position >= state.timeline.alignment.offset
            && nominalTime < state.timeline.scoreDuration - 0.002;
        silent(() => {
            const rate = effectiveRate();
            if (Math.abs(api.playbackSpeed - rate) > 0.0001) api.playbackSpeed = rate;
            if (playingWithinScore && api.playerState !== at.synth.PlayerState.Playing) api.play();
            else if (!playingWithinScore && api.playerState !== at.synth.PlayerState.Paused) api.pause();
            // alphaTab's unanchored player clock is speed-adjusted, unlike the native
            // media clock, whose currentTime remains content time at every rate.
            api.player.output.updatePosition(scoreTime * 1000 / rate);
        });
        const measure = state.timeline.measureAt(position);
        if (measure && measure.index !== state.lastMeasure) {
            state.lastMeasure = measure.index;
            post('measure', {songID: state.songID, index: measure.index,
                barIndex: measure.barIndex, occurrence: measure.occurrence,
                label: measure.label, section: measure.section, start: measure.start, end: measure.end,
                numerator: measure.numerator, denominator: measure.denominator});
        }
    }
    function sendScore(type = 'score') {
        const {score, timeline} = state;
        if (!score || !timeline) return;
        post(type, {songID: state.songID, alignmentRevision: state.alignmentRevision,
            title: score.title || 'Untitled', artist: score.artist || '',
            tracks: score.tracks.map(track => ({index: track.index, name: track.name || 'Guitar ' + (track.index + 1),
                tuning: Array.from(track.staves.find(staff => staff.tuning.length)?.tuning || []).reverse()})),
            selectedTrack: state.selectedTrack,
            measures: timeline.measures.map(({index, barIndex, occurrence, label, section, start, end, numerator, denominator}) =>
                ({index, barIndex, occurrence, label, section, start, end, numerator, denominator})),
            clicks: timeline.clicks, clickTrackError: timeline.clickTrackError,
            referenceAttacks: timeline.referenceAttacks,
            duration: timeline.duration,
            alignment: {source: timeline.alignment.source, offset: timeline.alignment.offset,
                inferredOffset: timeline.alignment.inferredOffset, adjustment: timeline.alignment.adjustment,
                scale: timeline.alignment.scale, acceptedHints: timeline.alignment.accepted.length,
                rejectedHints: timeline.alignment.rejected.map(point => ({barIndex: point.barIndex, text: point.text}))}});
    }
    function rebuildTimeline() {
        state.timeline = window.FretFlowTimeline.build(state.score, state.midi, state.tickLookup,
            at.midi.MidiEventType.TempoChange, {trackIndex: state.selectedTrack, offsetAdjustment: state.offsetAdjustment,
                noteOnEventType: at.midi.MidiEventType.NoteOn});
    }
    function initialize() {
        if (!at) throw new Error('The bundled notation renderer could not be loaded.');
        window.FretFlowNotationLayout.configure(at);
        api = new at.AlphaTabApi(document.getElementById('score'), {
            core: {
                scriptFile: new URL('vendor/alphaTab.min.js', document.baseURI).href,
                fontDirectory: new URL('vendor/font/', document.baseURI).href,
                // WebKit denies file-origin worker imports. The native app loads only
                // one part at a time; partial rendering keeps scrolling responsive.
                useWorkers: location.protocol !== 'file:',
                enableLazyLoading: true
            },
            display: {scale: 1, layoutMode: at.LayoutMode.Page, staveProfile: at.StaveProfile.Tab,
                padding: [20, 15, 25, 15], barCountPerPartial: 8,
                effectBandPaddingBottom: 10, effectStaffPaddingBottom: 4,
                systemPaddingTop: 14, systemPaddingBottom: 14},
            player: {playerMode: at.PlayerMode.EnabledExternalMedia,
                enableCursor: true, enableAnimatedBeatCursor: !window.matchMedia('(prefers-reduced-motion: reduce)').matches,
                enableElementHighlighting: true,
                enableUserInteraction: false, scrollElement: viewport, scrollMode: at.ScrollMode.OffScreen,
                scrollOffsetY: -75, scrollSpeed: 180},
            notation: {rhythmMode: at.TabRhythmMode.ShowWithBars, hideTuning: false}
        });
        api.player.output.handler = {
            get backingTrackDuration() { return (state.timeline?.scoreDuration || 0) * 1000 / effectiveRate(); },
            get playbackRate() { return effectiveRate(); },
            set playbackRate(_value) {},
            get masterVolume() { return 1; },
            set masterVolume(_value) {},
            seekTo(milliseconds) {
                if (!state.suppress && state.timeline) post('seek', {songID: state.songID,
                    position: state.timeline.toMedia(milliseconds * effectiveRate() / 1000)});
            },
            play() { if (!state.suppress) post('play', {songID: state.songID}); },
            pause() { if (!state.suppress) post('pause', {songID: state.songID}); }
        };
        api.error.on(showError);
        api.renderFinished.on(() => {
            state.rendered = true;
            status.hidden = true;
            syncClock();
        });
        api.playerReady.on(syncClock);
        api.beatMouseUp.on(beat => {
            if (!beat || !state.timeline) return;
            const measure = state.timeline.occurrenceForBar(beat.voice.bar.masterBar.index, positionNow());
            if (measure) post('seek', {songID: state.songID, position: measure.start});
        });
        // A small fixed update cadence avoids one WK bridge call per display frame.
        // Cursor positions are deterministic and do not run on a synthesizer timer.
        window.setInterval(syncClock, 50);
    }
    window.FretFlow = {
        loadScore(base64, songID, adjustment = 0, alignmentRevision = 0) {
            const loadID = ++state.loadID;
            state.songID = String(songID || '');
            state.score = null;
            state.timeline = null;
            state.midi = null;
            state.tickLookup = null;
            state.offsetAdjustment = window.FretFlowTimeline.offsetAdjustment(adjustment);
            state.alignmentRevision = Number.isSafeInteger(alignmentRevision) && alignmentRevision >= 0 ? alignmentRevision : 0;
            state.lastMeasure = -1;
            state.rendered = false;
            state.clock = {position: 0, duration: 0, isPlaying: false, rate: 1};
            status.className = '';
            status.textContent = 'Opening your tabs…';
            status.hidden = false;
            silent(() => api.pause());
            // Allow WebKit to paint the loading state before importing the score.
            window.setTimeout(() => {
                if (loadID !== state.loadID) return;
                try {
                    const binary = atob(String(base64));
                    if (binary.length > 64 * 1024 * 1024) throw new Error('This Guitar Pro file exceeds the 64 MB import limit.');
                    const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
                    const score = at.importer.ScoreLoader.loadScoreFromBytes(bytes, api.settings);
                    const midi = new at.midi.MidiFile();
                    const generator = new at.midi.MidiFileGenerator(score, api.settings, new at.midi.AlphaSynthMidiFileHandler(midi));
                    generator.generate();
                    state.score = score;
                    state.midi = midi;
                    state.tickLookup = generator.tickLookup;
                    const firstGuitar = score.tracks.find(track => track.staves.some(staff => staff.tuning.length && !staff.isPercussion));
                    state.selectedTrack = firstGuitar?.index || 0;
                    rebuildTimeline();
                    // The FretFlow timeline owns alignment. Never apply GP audio sync
                    // and the native-media correction twice. Original files are intact.
                    for (const bar of score.masterBars) bar.syncPoints = undefined;
                    score.backingTrack = undefined;
                    silent(() => api.load(score, [state.selectedTrack]));
                    sendScore();
                } catch (error) { showError(error); }
            }, 0);
        },
        setClock(clock) {
            if (!clock || !Number.isFinite(clock.position)) return;
            state.clock = {position: Math.max(0, clock.position),
                duration: Number.isFinite(clock.duration) ? Math.max(0, clock.duration) : 0,
                isPlaying: Boolean(clock.isPlaying),
                rate: Number.isFinite(clock.rate) ? Math.max(0.25, Math.min(4, clock.rate)) : 1};
            state.clockReceivedAt = performance.now();
            syncClock();
        },
        selectTrack(index) {
            if (!state.score || !Number.isInteger(index) || !state.score.tracks[index]) return;
            if (state.selectedTrack !== index) {
                state.selectedTrack = index;
                rebuildTimeline();
                silent(() => api.renderTracks([state.score.tracks[index]]));
            }
            post('clicks', {songID: state.songID, selectedTrack: index, alignmentRevision: state.alignmentRevision,
                clicks: state.timeline.clicks, clickTrackError: state.timeline.clickTrackError});
        },
        setOffsetAdjustment(value, alignmentRevision = 0) {
            state.offsetAdjustment = window.FretFlowTimeline.offsetAdjustment(value);
            state.alignmentRevision = Number.isSafeInteger(alignmentRevision) && alignmentRevision >= 0 ? alignmentRevision : 0;
            if (!state.score || !state.midi || !state.tickLookup) return;
            rebuildTimeline();
            state.lastMeasure = -1;
            sendScore('timeline');
            syncClock();
        },
        setZoom(value) {
            if (!Number.isFinite(value)) return;
            state.zoom = Math.min(2, Math.max(0.6, value));
            api.settings.display.scale = state.zoom;
            silent(() => { api.updateSettings(); api.render(); });
        },
        setFollow(value) {
            state.follow = Boolean(value);
            api.settings.player.scrollMode = state.follow ? at.ScrollMode.OffScreen : at.ScrollMode.Off;
            silent(() => api.updateSettings());
            if (state.follow && state.rendered) api.scrollToCursor();
        },
        setLoop(startSeconds, endSeconds) {
            // Transport looping belongs to the native media player. Keep this range
            // available to diagnostics without starting a second competing loop.
            state.loop = Number.isFinite(startSeconds) && Number.isFinite(endSeconds) && endSeconds > startSeconds
                ? {start: startSeconds, end: endSeconds} : null;
        },
        diagnostics() {
            return {songID: state.songID, rendered: state.rendered, ready: api?.isReadyForPlayback || false,
                tick: api?.tickPosition || 0, time: api?.timePosition || 0, track: state.selectedTrack,
                playing: api?.playerState === at.synth.PlayerState.Playing,
                measure: state.lastMeasure, follow: state.follow, zoom: state.zoom,
                scoreDuration: state.timeline?.scoreDuration || 0, loop: state.loop,
                alignmentRevision: state.alignmentRevision, offsetAdjustment: state.offsetAdjustment};
        }
    };
    try { initialize(); post('ready', {version: '1.0', renderer: 'alphaTab 1.8.4'}); }
    catch (error) { showError(error); }
})();
