/* FretFlow timing helpers. All times at the native boundary are content seconds. */
(function (root, factory) {
    const helpers = factory();
    if (typeof module === 'object' && module.exports) module.exports = helpers;
    else root.FretFlowTimeline = helpers;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
    'use strict';
    const finite = value => typeof value === 'number' && Number.isFinite(value);
    function offsetAdjustment(value) {
        return finite(value) ? Math.max(-30, Math.min(120, value)) : 0;
    }
    const median = values => {
        const sorted = values.slice().sort((a, b) => a - b);
        return sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0;
    };
    function annotationTime(text) {
        const match = String(text || '').match(/(?:\(|\b)(\d{1,2}):(\d{2})(?:\.(\d+))?(?:\)|\b)/);
        if (!match || Number(match[2]) >= 60) return null;
        return Number(match[1]) * 60 + Number(match[2]) + (match[3] ? Number('0.' + match[3]) : 0);
    }
    function tempoMap(midi, tempoEventType) {
        const events = midi.events.filter(event => event.type === tempoEventType)
            .slice().sort((a, b) => a.tick - b.tick);
        const segments = [{tick: 0, time: 0, bpm: 120}];
        for (const event of events) {
            if (!finite(event.beatsPerMinute) || event.beatsPerMinute <= 0) continue;
            const previous = segments[segments.length - 1];
            const entry = {tick: event.tick,
                time: previous.time + (event.tick - previous.tick) * 60 / (previous.bpm * midi.division),
                bpm: event.beatsPerMinute};
            if (entry.tick === previous.tick) segments[segments.length - 1] = entry;
            else segments.push(entry);
        }
        function segmentAt(tick) {
            let lo = 0, hi = segments.length - 1;
            while (lo < hi) {
                const middle = Math.ceil((lo + hi) / 2);
                if (segments[middle].tick <= tick) lo = middle;
                else hi = middle - 1;
            }
            return segments[lo];
        }
        function tickToTime(tick) {
            const segment = segmentAt(tick);
            return segment.time + (tick - segment.tick) * 60 / (segment.bpm * midi.division);
        }
        return {segments, tickToTime, tempoAt: tick => segmentAt(tick).bpm};
    }
    function referenceAttacks(midi, map, noteOnEventType = 128) {
        // alphaTab's NoteOn enum is 128 (not the serialized MIDI status byte).
        // All parts contribute: the selected guitar may rest through an intro.
        // Generated note events already include repeats, swing and tickShift.
        const candidates = midi.events.filter(event => event.type === noteOnEventType
            && finite(event.tick) && event.tick >= 0
            && finite(event.noteVelocity) && event.noteVelocity > 0 && event.noteVelocity <= 127)
            .map(event => map.tickToTime(event.tick))
            .filter(time => finite(time) && time >= 0 && time <= 60)
            .sort((a, b) => a - b);
        const attacks = [];
        for (const time of candidates) {
            // A chord (or the same attack in several parts) is one onset, not
            // several votes. Keep the earliest time in each five-ms cluster.
            if (!attacks.length || time - attacks[attacks.length - 1] > 0.005 + 1e-9) {
                attacks.push(time);
                if (attacks.length >= 2_000) break;
            }
        }
        return attacks;
    }
    function inferAlignment(measures) {
        const seen = new Set(), candidates = [], rejected = [];
        for (const measure of measures) {
            if (seen.has(measure.barIndex)) continue;
            seen.add(measure.barIndex);
            const time = annotationTime(measure.section);
            if (time !== null) candidates.push({scoreTime: measure.scoreStart, mediaTime: time,
                barIndex: measure.barIndex, text: measure.section});
        }
        const initial = candidates.find(point => point.scoreTime < 0.1 && point.mediaTime <= 30);
        const baseOffset = initial ? initial.mediaTime - initial.scoreTime
            : median(candidates.map(point => point.mediaTime - point.scoreTime));
        let previousTime = -Infinity;
        const accepted = candidates.filter(point => {
            const residual = Math.abs(point.mediaTime - point.scoreTime - baseOffset);
            const plausible = residual <= Math.max(6, point.scoreTime * 0.05);
            if (!plausible || point.mediaTime <= previousTime) {
                rejected.push(point);
                return false;
            }
            previousTime = point.mediaTime;
            return true;
        });
        // Section labels have only whole-second precision. Preserve score tempo unless
        // several distant anchors consistently indicate more than a second of drift.
        let scale = 1;
        const distant = accepted.filter(point => point.scoreTime > 30);
        if (distant.length >= 3) {
            const estimated = median(distant.map(point => (point.mediaTime - baseOffset) / point.scoreTime));
            const duration = measures.length ? measures[measures.length - 1].scoreEnd : 0;
            if (estimated >= 0.97 && estimated <= 1.03 && Math.abs(estimated - 1) * duration > 1) scale = estimated;
        }
        const offset = accepted.length ? Math.max(-30, Math.min(30, baseOffset)) : 0;
        return {offset, scale, accepted, rejected,
            source: accepted.length ? 'Score tempo and validated section timestamps' : 'Score tempo and repeats'};
    }
    function selectedStaff(score, options) {
        const tracks = score.tracks || [];
        const index = options?.trackIndex;
        const track = tracks.find(track => track.index === index) || tracks[index]
            || tracks.find(track => track.staves?.some(staff => staff.stringTuning?.tunings?.length)) || tracks[0];
        return track?.staves?.[0];
    }
    function groupLabel(boundaries, fullTicks, unitTicks, denominator) {
        const ticks = [...boundaries, fullTicks];
        const lengths = ticks.slice(1).map((tick, index) => tick - ticks[index]);
        const units = lengths.map(length => length / unitTicks);
        if (units.every(value => Math.abs(value - Math.round(value)) < 1e-7)) {
            return units.map(Math.round).join('+');
        }
        // A written group can start between the meter's pulses (e.g. 3+3+2
        // eighth notes in 4/4). Keep its actual unit in the label.
        for (let multiple = 2; multiple <= 64 && denominator * multiple <= 256; multiple *= 2) {
            const subdivisions = units.map(value => value * multiple);
            if (subdivisions.every(value => Math.abs(value - Math.round(value)) < 1e-7)) {
                return subdivisions.map(Math.round).join('+') + ' · 1/' + (denominator * multiple) + ' notes';
            }
        }
        return 'Written beam groups';
    }
    function groove(masterBar, staffBar, division, numerator, denominator, phase) {
        const unitTicks = division * 4 / denominator;
        const fullTicks = numerator * unitTicks;
        const starts = new Set([0]);
        const rules = masterBar?.actualBeamingRules || masterBar?.beamingRules;
        let source = '';
        // GPX can retain a previous meter's rules after a meter change. Those
        // inherited rules must not add misplaced accents to the new measure.
        if (rules && (!rules.timeSignatureNumerator || rules.timeSignatureNumerator === numerator)
            && (!rules.timeSignatureDenominator || rules.timeSignatureDenominator === denominator)) {
            let rule;
            if (typeof rules.findRule === 'function') rule = rules.findRule(Math.max(8, denominator));
            else if (rules.groups instanceof Map) {
                const keys = [...rules.groups.keys()].sort((a, b) => a - b);
                const key = keys.find(key => key >= Math.max(8, denominator)) || keys[keys.length - 1];
                if (key) rule = [key, rules.groups.get(key)];
            }
            const [unit, groups] = rule || [];
            if (finite(unit) && unit > 0 && Array.isArray(groups) && groups.length <= 128
                && groups.length && groups.every(value => Number.isInteger(value) && value > 0)) {
                const groupTicks = groups.map(value => value * division * 4 / unit);
                if (Math.abs(groupTicks.reduce((a, b) => a + b, 0) - fullTicks) < 1e-7) {
                    let offset = 0;
                    for (const length of groupTicks) { starts.add(offset); offset += length; }
                    source = 'Score beam groups';
                }
            }
        }
        if (!source && denominator >= 8 && [6, 9, 12].includes(numerator)) {
            for (let beat = 3; beat < numerator; beat += 3) starts.add(beat * unitTicks);
            source = 'Compound meter';
        }
        // Only written primary-beam overrides change the grouping. Ordinary
        // note lengths, rests and secondary beam breaks are not accents.
        const beats = staffBar?.voices?.[0]?.beats || [];
        for (let i = 0; i + 1 < beats.length; i++) {
            const beat = beats[i], next = beats[i + 1];
            if (beat.graceType || next.graceType || beat.isEmpty || next.isEmpty) continue;
            const boundary = next.displayStart + phase;
            if (!finite(boundary) || boundary <= 0 || boundary >= fullTicks) continue;
            if (beat.beamingMode === 1) {
                if (!starts.has(boundary)) {
                    starts.add(boundary);
                    source = 'Score beam groups';
                }
            } else if (beat.beamingMode === 2 && finite(beat.displayStart)) {
                for (const start of starts) if (start > beat.displayStart + phase && start <= boundary) {
                    starts.delete(start);
                    source = 'Score beam groups';
                }
            }
        }
        const boundaries = [...starts].sort((a, b) => a - b);
        return {boundaries, grouping: source ? groupLabel(boundaries, fullTicks, unitTicks, denominator) : '', source};
    }
    function writtenAccents(staffBar, tickLookup) {
        const offsets = [];
        for (const voice of staffBar?.voices || []) {
            for (const beat of voice.beats || []) {
                if (beat.graceType || beat.isEmpty || !finite(beat.playbackStart) || beat.playbackStart < 0) continue;
                // Normal/heavy accents are attacks. Tenuto, ghost notes and
                // tied destinations do not create a new accented attack.
                if ((beat.notes || []).some(note => !note.isTieDestination && !note.isGhost
                    && (note.accentuated === 1 || note.accentuated === 2))) {
                    const range = tickLookup.getRelativeBeatPlaybackRange?.(beat);
                    offsets.push(finite(range?.startTick) ? range.startTick : beat.playbackStart);
                }
            }
        }
        return offsets;
    }
    function clickGrid(score, measures, map, division, shift, alignment, options, tickLookup) {
        const clicks = [];
        const staff = selectedStaff(score, options);
        // Bound bridge payloads from unusually large or malformed imports. A
        // click-track failure must not prevent viewing or playing the score.
        const limit = 250_000;
        if (!finite(division) || division <= 0) {
            return {clicks, clickTrackError: 'The score has no usable beat timing.'};
        }
        for (const measure of measures) {
            const {numerator, denominator} = measure;
            if (!Number.isInteger(numerator) || numerator < 1 || numerator > 128
                || !Number.isInteger(denominator) || denominator < 1 || denominator > 256
                || (denominator & (denominator - 1)) !== 0) {
                return {clicks: [], clickTrackError: 'The score contains an unsupported time signature.'};
            }
            const beatTicks = division * 4 / denominator;
            const durationTicks = measure.endTick - measure.startTick;
            // A pickup occupies the end of its written meter: a one-quarter
            // pickup in 4/4 is beat 4, not a new accented downbeat. A fractional
            // pickup can start between pulses; do not invent a click there.
            const phase = measure.isAnacrusis ? Math.max(0, numerator * beatTicks - durationTicks) : 0;
            const firstBeat = Math.max(0, Math.ceil(phase / beatTicks - 1e-9));
            const masterBar = score.masterBars?.[measure.barIndex];
            const staffBar = staff?.bars?.[measure.barIndex];
            const groups = groove(masterBar, staffBar, division, numerator, denominator, phase);
            measure.grouping = groups.grouping;
            measure.groupingSource = groups.source;
            // Merge coincident pulses, group boundaries and note accents into
            // one sound, keeping the strongest accent at an exact onset.
            const points = new Map();
            const addPoint = (offset, level, downbeat = false) => {
                if (!finite(offset) || offset < -1e-7 || offset >= durationTicks - 1e-7) return;
                const key = Math.round(Math.max(0, offset) * 1e6);
                const previous = points.get(key);
                if (previous) { previous.level = Math.max(previous.level, level); previous.downbeat ||= downbeat; }
                else points.set(key, {offset: Math.max(0, offset), level, downbeat});
            };
            for (let beatIndex = firstBeat; beatIndex < numerator; beatIndex++) {
                addPoint(beatIndex * beatTicks - phase, beatIndex === 0 ? 3 : 0, beatIndex === 0);
            }
            for (const boundary of groups.boundaries) {
                // For a pickup, a group at the written bar's zero is outside
                // the played fragment; do not invent an initial downbeat.
                addPoint(boundary - phase, boundary === 0 ? 3 : 1, boundary === 0);
            }
            for (const offset of writtenAccents(staffBar, tickLookup)) addPoint(offset, 2);
            for (const point of [...points.values()].sort((a, b) => a.offset - b.offset)) {
                const tick = measure.startTick + point.offset;
                const scoreTime = map.tickToTime(tick + shift);
                const time = scoreTime * alignment.scale + alignment.offset;
                // Unlike cursor positions, negative aligned clicks cannot be
                // clamped: that would pile several beats onto media time zero.
                if (time < -1e-9) continue;
                if (clicks.length >= limit) {
                    return {clicks: [], clickTrackError: 'This score is too large for a click track.'};
                }
                const beatPosition = (point.offset + phase) / beatTicks;
                clicks.push({time: Math.max(0, time), barIndex: measure.barIndex,
                    measureIndex: measure.index, beatIndex: Math.min(numerator - 1, Math.floor(beatPosition + 1e-7)), numerator, denominator,
                    bpm: map.tempoAt(tick + shift), accent: point.downbeat, accentLevel: point.level,
                    isSubdivision: Math.abs(beatPosition - Math.round(beatPosition)) > 1e-7,
                    grouping: groups.grouping, groupingSource: groups.source});
            }
        }
        return {clicks, clickTrackError: null};
    }
    function build(score, midi, tickLookup, tempoEventType, options = {}) {
        const map = tempoMap(midi, tempoEventType);
        const occurrences = new Map();
        const shift = finite(midi.tickShift) ? midi.tickShift : 0;
        // Some GPX files contain an empty pickup placeholder with no playback
        // ticks (for example Heart). Keep its printed bar number in the score,
        // but omit it from the seek/loop timeline so every listed measure plays.
        let measures = tickLookup.masterBars.filter(entry => entry.end > entry.start).map((entry, index) => {
            const barIndex = entry.masterBar.index;
            const occurrence = occurrences.get(barIndex) || 0;
            occurrences.set(barIndex, occurrence + 1);
            return {index, barIndex, occurrence,
                numerator: entry.masterBar.timeSignatureNumerator ?? 4,
                denominator: entry.masterBar.timeSignatureDenominator ?? 4,
                isAnacrusis: Boolean(entry.masterBar.isAnacrusis),
                label: 'Bar ' + (barIndex + 1) + (occurrence ? ' · pass ' + (occurrence + 1) : ''),
                section: entry.masterBar.section?.text || '',
                scoreStart: map.tickToTime(entry.start + shift),
                scoreEnd: map.tickToTime(entry.end + shift),
                startTick: entry.start, endTick: entry.end};
        });
        const inferred = inferAlignment(measures);
        const adjustment = offsetAdjustment(options.offsetAdjustment);
        const alignment = {...inferred, inferredOffset: inferred.offset, adjustment,
            offset: inferred.offset + adjustment};
        const toMedia = scoreTime => Math.max(0, scoreTime * alignment.scale + alignment.offset);
        const toScore = mediaTime => Math.max(0, (mediaTime - alignment.offset) / alignment.scale);
        const scoreDuration = measures.length ? measures[measures.length - 1].scoreEnd : 0;
        for (const measure of measures) {
            measure.start = toMedia(measure.scoreStart);
            measure.end = toMedia(measure.scoreEnd);
        }
        // Earlier recording alignment can put an entire opening bar before
        // video time zero. Omit those bars from seek/loop targets, preserving
        // printed bar numbers and repeat passes without zero-length entries.
        measures = measures.filter(measure => measure.end > measure.start);
        measures.forEach((measure, index) => { measure.index = index; });
        const clickTrack = clickGrid(score, measures, map, midi.division, shift, alignment, options, tickLookup);
        const attacks = referenceAttacks(midi, map, options.noteOnEventType);
        return {measures, alignment, ...clickTrack, referenceAttacks: attacks,
            scoreDuration, duration: toMedia(scoreDuration), toMedia, toScore,
            measureAt(position) {
                if (!measures.length) return null;
                let lo = 0, hi = measures.length - 1;
                while (lo < hi) {
                    const middle = Math.ceil((lo + hi) / 2);
                    if (measures[middle].start <= position) lo = middle;
                    else hi = middle - 1;
                }
                return measures[lo];
            },
            occurrenceForBar(barIndex, position) {
                const matches = measures.filter(measure => measure.barIndex === barIndex);
                return matches.find(measure => position >= measure.start && position < measure.end)
                    || matches.reduce((best, measure) => !best || Math.abs(measure.start - position) < Math.abs(best.start - position) ? measure : best, null);
            }};
    }
    return {annotationTime, tempoMap, referenceAttacks, inferAlignment, offsetAdjustment, build};
});
