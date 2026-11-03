#!/usr/bin/env node
'use strict';
// Pure score timing checks. No sound, browser, microphone, or network access.
// Optionally pass one or more directories containing Guitar Pro fixtures.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const app = path.resolve(__dirname, '..');
const web = path.join(app, 'Resources/Web');
const at = require(path.join(web, 'vendor/alphaTab.min.js'));
const timing = require(path.join(web, 'timeline.js'));
const near = (actual, expected, message = '') => assert(Math.abs(actual - expected) < 1e-7, `${message}: ${actual} != ${expected}`);
const tempo = (tick, bpm) => ({type: 81, tick, beatsPerMinute: bpm});
function bar(index, numerator, denominator, extra = {}) {
    return {index, timeSignatureNumerator: numerator, timeSignatureDenominator: denominator, ...extra};
}
function build(entries, events = [tempo(0, 120)], extra = {}) {
    return timing.build({}, {division: 960, events, ...extra}, {masterBars: entries}, 81);
}
function sequential(bars) {
    let tick = 0;
    return bars.map(masterBar => {
        const duration = masterBar.duration ?? masterBar.timeSignatureNumerator * 3840 / masterBar.timeSignatureDenominator;
        const entry = {masterBar, start: tick, end: tick + duration};
        tick = entry.end;
        return entry;
    });
}

// Different beat units and a tempo change inside the first bar. A click at a
// shared barline belongs only to the next bar, with its new meter and accent.
const mixed = build(sequential([bar(0, 4, 4), bar(1, 7, 8), bar(2, 3, 4)]),
    [tempo(0, 120), tempo(1920, 60), tempo(3840, 90)]);
assert.equal(mixed.clickTrackError, null);
assert.equal(mixed.clicks.length, 14);
assert.deepEqual(mixed.clicks.slice(0, 4).map(c => c.time), [0, 0.5, 1, 2]);
assert.deepEqual(mixed.clicks.slice(0, 4).map(c => c.bpm), [120, 120, 60, 60]);
assert.deepEqual(mixed.clicks.map(c => c.measureIndex), [...Array(4).fill(0), ...Array(7).fill(1), ...Array(3).fill(2)]);
mixed.clicks.slice(4, 11).forEach((click, beat) => {
    near(click.time, 3 + beat / 3, '7/8 eighth-note pulse');
    assert.equal(click.beatIndex, beat);
    assert.equal(click.denominator, 8);
    assert.equal(click.accent, beat === 0);
});
near(mixed.clicks[11].time, 16 / 3);
assert.equal(mixed.clicks[11].numerator, 3);
assert(mixed.clicks.every(c => c.time < mixed.measures[c.measureIndex].end));
assert.equal(mixed.clicks.filter(c => c.time === 3).length, 1);

// Use every notated denominator pulse even in compound meter: 6/8 has six
// eighth-note clicks and one strong downbeat, not six quarter-note clicks.
const compound = build(sequential([bar(0, 6, 8), bar(1, 2, 2)]));
assert.deepEqual(compound.clicks.map(c => c.time), [0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2.5]);
assert.deepEqual(compound.clicks.map(c => c.accent), [true, false, false, false, false, false, true, false]);
assert.deepEqual(compound.clicks.slice(0, 6).map(c => c.accentLevel), [3, 0, 0, 1, 0, 0]);
assert.equal(compound.clicks[0].grouping, '3+3');
assert.equal(compound.clicks[0].groupingSource, 'Compound meter');

function notationBuild(masterBars, trackBeats = [[]], options = {}, events = [tempo(0, 120)]) {
    const score = {masterBars, tracks: trackBeats.map((bars, index) => ({index, staves: [{bars: masterBars.map((_, i) =>
        ({voices: [{beats: bars[i] || []}]}))}]}))};
    return timing.build(score, {division: 960, events}, {masterBars: sequential(masterBars)}, 81, options);
}
function grouped(index, numerator, denominator, groups, unit = denominator) {
    return bar(index, numerator, denominator, {actualBeamingRules: {
        timeSignatureNumerator: numerator, timeSignatureDenominator: denominator,
        groups: new Map([[unit, groups]])}});
}
function noteBeat(start, extra = {}, noteExtra = {}) {
    return {displayStart: start, playbackStart: start, graceType: 0,
        notes: [{accentuated: 0, ...noteExtra}], ...extra};
}
// Read the score's own partition instead of guessing an odd-meter pattern.
const odd = notationBuild([grouped(0, 7, 8, [2, 2, 3]), grouped(1, 7, 8, [3, 2, 2])]);
assert.deepEqual(odd.clicks.slice(0, 7).map(c => c.accentLevel), [3, 0, 1, 0, 1, 0, 0]);
assert.deepEqual(odd.clicks.slice(7).map(c => c.accentLevel), [3, 0, 0, 1, 0, 1, 0]);
assert.equal(odd.measures[0].grouping, '2+2+3');
assert.equal(odd.measures[1].grouping, '3+2+2');
assert.equal(build(sequential([bar(0, 7, 8)])).clicks[0].grouping, '');
const longOdd = notationBuild([grouped(0, 17, 16, [4, 4, 4, 5]), grouped(1, 7, 4, [8, 6], 8)]);
assert.deepEqual(longOdd.clicks.filter(c => c.accentLevel === 1).map(c => c.beatIndex), [4, 8, 12, 4]);
assert.equal(longOdd.measures[1].grouping, '4+3');
// 3+3+2 eighths in 4/4 adds group pulses between quarter-note clicks.
const syncopated = notationBuild([grouped(0, 4, 4, [3, 3, 2], 8)]);
assert.deepEqual(syncopated.clicks.map(c => c.time), [0, 0.5, 0.75, 1, 1.5]);
assert.equal(syncopated.clicks[2].accentLevel, 1);
assert.equal(syncopated.clicks[2].isSubdivision, true);
assert.equal(syncopated.clicks[2].accent, false);
assert.equal(syncopated.clicks[0].grouping, '3+3+2 · 1/8 notes');
// Ignore stale inherited rules, including equal-duration but different meters.
for (const master of [
    {...grouped(0, 7, 8, [4, 3]), timeSignatureNumerator: 4, timeSignatureDenominator: 4},
    {...grouped(0, 3, 4, [1, 1, 1]), timeSignatureNumerator: 6, timeSignatureDenominator: 8},
    grouped(0, 4, 4, [3, 3, 3, 4], 8),
    grouped(0, 4, 4, [2, -1, 3], 4)
]) {
    const timeline = notationBuild([master]);
    assert.notEqual(timeline.clicks[0].groupingSource, 'Score beam groups');
    if (master.timeSignatureNumerator === 6) assert.equal(timeline.clicks[0].grouping, '3+3');
}
// Explicit overrides apply to the edge AFTER a beat. Secondary beam breaks
// do not create metrical accents, and track choice controls the overrides.
const eighths = Array.from({length: 7}, (_, i) => noteBeat(i * 480));
const overrides = eighths.map(beat => ({...beat}));
overrides[1].beamingMode = 2; // merge across the original first group boundary
overrides[2].beamingMode = 1; // split before the fourth eighth
overrides[4].beamingMode = 3; // secondary beam split must be ignored
const overridden = notationBuild([grouped(0, 7, 8, [2, 2, 3])], [[eighths], [overrides]], {trackIndex: 1});
assert.equal(overridden.clicks[0].grouping, '3+1+3');
assert.deepEqual(overridden.clicks.map(c => c.accentLevel), [3, 0, 0, 1, 1, 0, 0]);
assert.equal(notationBuild([grouped(0, 7, 8, [2, 2, 3])], [[eighths], [overrides]], {trackIndex: 0}).clicks[0].grouping, '2+2+3');
assert.equal(notationBuild([bar(0, 4, 4)], [[[noteBeat(0, {beamingMode: 2}), noteBeat(480)]]]).clicks[0].grouping, '',
    'An isolated merge does not establish one whole-bar group');

// Written accents follow their exact onset, including offbeat accents. A
// chord or several voices must not double-trigger a click at the same time.
const accents = [noteBeat(0, {}, {accentuated: 2}), noteBeat(240, {}, {accentuated: 1}),
    noteBeat(240, {}, {accentuated: 2}), noteBeat(480, {}, {accentuated: 3}),
    noteBeat(720, {}, {accentuated: 1, isTieDestination: true}),
    noteBeat(1200, {graceType: 1}, {accentuated: 1}), noteBeat(1440, {}, {accentuated: 1, isGhost: true}),
    noteBeat(1920, {}, {accentuated: 2})];
const accented = notationBuild([bar(0, 4, 4)], [[], [accents]], {trackIndex: 1});
assert.deepEqual(accented.clicks.map(c => c.time), [0, 0.125, 0.5, 1, 1.5]);
assert.deepEqual(accented.clicks.map(c => c.accentLevel), [3, 2, 0, 2, 0]);
assert.equal(accented.clicks[1].beatIndex, 0);
assert.equal(accented.clicks[1].accent, false);
assert.equal(accented.clicks[1].isSubdivision, true);
assert.equal(notationBuild([bar(0, 4, 4)], [[], [accents]], {trackIndex: 0}).clicks.length, 4);
const repeatedAccentBar = grouped(0, 7, 8, [2, 2, 3]);
const repeatedAccents = notationBuild([repeatedAccentBar, repeatedAccentBar], [[[noteBeat(240, {}, {accentuated: 1})]]]);
assert.equal(repeatedAccents.clicks.filter(c => c.accentLevel === 2).length, 2);
near(repeatedAccents.clicks.filter(c => c.accentLevel === 2)[1].time, 1.875);
const pickupGroups = notationBuild([grouped(0, 6, 8, [3, 3])]);
assert.equal(pickupGroups.clicks[3].accentLevel, 1);
const groupedPickupBar = {...grouped(0, 6, 8, [3, 3]), isAnacrusis: true, duration: 1440};
const groupedPickup = notationBuild([groupedPickupBar]);
assert.deepEqual(groupedPickup.clicks.map(c => c.accentLevel), [1, 0, 0]);
assert(groupedPickup.clicks.every(c => !c.accent));
const pickupOverrides = notationBuild([groupedPickupBar], [[[noteBeat(0, {beamingMode: 1}), noteBeat(480), noteBeat(960)]]]);
assert.deepEqual(pickupOverrides.clicks.map(c => c.accentLevel), [1, 1, 0]);
const acceleratedAccent = notationBuild([bar(0, 4, 4)], [[accents]], {}, [tempo(0, 120), tempo(120, 60)]);
near(acceleratedAccent.clicks[1].time, 0.1875);
const swingBar = bar(0, 4, 4), swingBeat = noteBeat(480, {}, {accentuated: 1});
const swingScore = {masterBars: [swingBar], tracks: [{index: 0, staves: [{bars: [{voices: [{beats: [swingBeat]}]}]}]}]};
const swing = timing.build(swingScore, {division: 960, events: [tempo(0, 120)]}, {
    masterBars: sequential([swingBar]), getRelativeBeatPlaybackRange: () => ({startTick: 640, endTick: 960})
}, 81);
near(swing.clicks.find(c => c.accentLevel === 2).time, 1 / 3, 'Use sounding onset after triplet-feel adjustment');

// Playback order is expanded by alphaTab; repeated printed bars and alternate
// endings must retain their own occurrences, not be collapsed into one grid.
const repeatedBar = bar(0, 7, 8);
const repeat = build(sequential([repeatedBar, bar(1, 3, 4), repeatedBar, bar(2, 5, 8)]));
assert.equal(repeat.clicks.length, 22);
assert.deepEqual(repeat.clicks.filter(c => c.accent).map(c => [c.measureIndex, c.barIndex]), [[0, 0], [1, 1], [2, 0], [3, 2]]);
assert(repeat.clicks[10].time > repeat.clicks[0].time);
assert.equal(repeat.clicks[10].beatIndex, 0);

const pickup = build(sequential([bar(0, 4, 4, {isAnacrusis: true, duration: 1440}), bar(1, 4, 4)]));
assert.equal(pickup.clicks.length, 5);
near(pickup.clicks[0].time, 0.25);
assert.equal(pickup.clicks[0].beatIndex, 3);
assert.equal(pickup.clicks[0].accent, false);
near(pickup.clicks[1].time, 0.75);
assert.equal(pickup.clicks[1].accent, true);
const quarterPickup = build(sequential([bar(0, 4, 4, {isAnacrusis: true, duration: 960}), bar(1, 4, 4)]));
near(quarterPickup.clicks[0].time, 0);
assert.equal(quarterPickup.clicks[0].beatIndex, 3);
const emptyPickup = build(sequential([bar(0, 4, 4, {isAnacrusis: true, duration: 0}), bar(1, 4, 4)]));
assert.equal(emptyPickup.clicks.length, 4);
assert.equal(emptyPickup.clicks[0].barIndex, 1);
assert.equal(emptyPickup.clicks[0].measureIndex, 0);
assert.equal(emptyPickup.clicks[0].accent, true);

const delayed = build(sequential([bar(0, 4, 4, {section: {text: '(0:03)'}})]));
assert.deepEqual(delayed.clicks.map(c => c.time), [3, 3.5, 4, 4.5]);
const advanced = build(sequential([bar(0, 4, 4), bar(1, 4, 4, {section: {text: '(0:01)'}}), bar(2, 4, 4)]));
near(advanced.alignment.offset, -1);
assert.equal(advanced.clicks.length, 10);
assert.equal(advanced.clicks.filter(c => c.time === 0).length, 1);
assert.equal(advanced.clicks[0].beatIndex, 2);
assert.equal(advanced.clicks[0].accent, false);
const scaledBars = Array.from({length: 121}, (_, i) => bar(i, 4, 4));
for (const [index, text] of [[0, '(0:00)'], [20, '(0:41)'], [40, '(1:22)'], [60, '(2:03)']]) {
    scaledBars[index].section = {text};
}
const scaled = build(sequential(scaledBars));
near(scaled.alignment.scale, 1.025);
near(scaled.clicks[1].time, 0.5 * 1.025, 'Click follows score/media alignment scaling');
near(scaled.clicks[80].time, 41);
assert.equal(scaled.clicks[80].bpm, 120, 'BPM metadata retains the source quarter-note tempo');
const shifted = build(sequential([bar(0, 4, 4)]), [tempo(0, 120), tempo(1920, 60)], {tickShift: 960});
assert.deepEqual(shifted.clicks.map(c => c.time), [0.5, 1, 2, 3]);
assert.deepEqual(shifted.clicks.map(c => c.bpm), [120, 60, 60, 60]);

// Missing notation defaults to the same 4/4 that legacy timeline fixtures use;
// malformed explicit meter disables only the click track, never the tabs.
const unspecified = build([{masterBar: {index: 0}, start: 0, end: 3840}]);
assert.equal(unspecified.clicks.length, 4);
for (const bad of [bar(0, 0, 4), bar(0, 4, 3), bar(0, 129, 4), bar(0, 4, Infinity)]) {
    const result = build([{masterBar: bad, start: 0, end: 3840}]);
    assert.equal(result.clicks.length, 0);
    assert(result.clickTrackError);
    assert.equal(result.measures.length, 1);
}
const huge = build(sequential(Array.from({length: 1954}, (_, i) => bar(i, 128, 256))));
assert.equal(huge.clicks.length, 0);
assert.match(huge.clickTrackError, /too large/);

const folders = process.argv.slice(2).map(p => path.resolve(p));
if (!folders.length) {
    folders.push(path.join(app, 'Resources/Library'));
    const imported = path.join(app, 'tmp/new-score-fixtures');
    if (fs.existsSync(imported)) folders.push(imported);
}
const summaries = [];
for (const folder of folders) {
    for (const filename of fs.readdirSync(folder).filter(name => /\.(gp[345]?|gpx)$/i.test(name)).sort()) {
        const score = at.importer.ScoreLoader.loadScoreFromBytes(fs.readFileSync(path.join(folder, filename)), new at.Settings());
        const midi = new at.midi.MidiFile();
        const generator = new at.midi.MidiFileGenerator(score, null, new at.midi.AlphaSynthMidiFileHandler(midi));
        generator.generate();
        const timeline = timing.build(score, midi, generator.tickLookup, at.midi.MidiEventType.TempoChange);
        assert.equal(timeline.clickTrackError, null, filename);
        assert(timeline.clicks.length > 0, `${filename}: no clicks`);
        const seen = new Set();
        timeline.clicks.forEach((click, i) => {
            assert(Number.isFinite(click.time) && click.time >= 0, filename);
            if (i) assert(click.time > timeline.clicks[i - 1].time, `${filename}: duplicated or reversed pulse`);
            assert(!seen.has(`${click.measureIndex}/${click.time}`));
            seen.add(`${click.measureIndex}/${click.time}`);
            const measure = timeline.measures[click.measureIndex];
            const master = score.masterBars[click.barIndex];
            assert.equal(master.timeSignatureNumerator, click.numerator);
            assert.equal(master.timeSignatureDenominator, click.denominator);
            assert.equal(measure.barIndex, click.barIndex);
            assert(click.beatIndex >= 0 && click.beatIndex < click.numerator);
            assert.equal(click.accent, !click.isSubdivision && click.beatIndex === 0);
            assert(Number.isInteger(click.accentLevel) && click.accentLevel >= 0 && click.accentLevel <= 3);
            assert.equal(click.accentLevel === 3, click.accent);
            assert.equal(typeof click.grouping, 'string');
            assert(click.time >= measure.start - 1e-8 && click.time < measure.end);
            assert(click.bpm > 0 && Number.isFinite(click.bpm));
        });
        const tempos = timing.tempoMap(midi, at.midi.MidiEventType.TempoChange);
        for (const measure of timeline.measures) {
            const master = score.masterBars[measure.barIndex];
            if (master.isAnacrusis || measure.scoreStart * timeline.alignment.scale + timeline.alignment.offset < 0) continue;
            const entry = timeline.clicks.filter(c => c.measureIndex === measure.index && !c.isSubdivision);
            const unit = midi.division * 4 / master.timeSignatureDenominator;
            const expected = Math.min(master.timeSignatureNumerator, Math.ceil((measure.endTick - measure.startTick) / unit - 1e-9));
            assert.equal(entry.length, expected, `${filename}: missing beats in printed bar ${master.index + 1}`);
            near(entry[0].time, measure.start, 'First beat aligns to the measure highlight');
            for (const click of entry) {
                const tick = measure.startTick + click.beatIndex * unit + (midi.tickShift || 0);
                near(click.time, tempos.tickToTime(tick) * timeline.alignment.scale + timeline.alignment.offset);
            }
        }
        if (score.title === 'Heart') assert.equal(timeline.clicks[0].barIndex, 1);
        if (score.title === 'Heart') {
            const guitar2 = timing.build(score, midi, generator.tickLookup, at.midi.MidiEventType.TempoChange, {trackIndex: 1});
            assert.equal(guitar2.clicks.filter(c => c.accentLevel === 2 && c.isSubdivision).length, 60,
                'Heart Guitar 2 retains written offbeat accents');
            assert.equal(timeline.clicks.filter(c => c.accentLevel === 2).length, 0, 'Other guitar accents must not leak into selected track');
        }
        if (score.title === 'Manala') {
            assert(timeline.clicks.some(c => c.numerator === 7 && c.denominator === 8 && c.grouping === '2+2+3'));
        }
        if (score.title === 'Electric Sunrise') {
            assert(timeline.clicks.some(c => c.grouping === '3+3+3+4'));
            assert(timeline.clicks.filter(c => c.numerator === 4 && c.denominator === 4).every(c => c.grouping !== '3+3+3+4'));
        }
        for (const track of score.tracks) {
            const trackTimeline = timing.build(score, midi, generator.tickLookup, at.midi.MidiEventType.TempoChange, {trackIndex: track.index});
            assert.equal(trackTimeline.clickTrackError, null, `${filename}: track ${track.index}`);
            for (let i = 0; i < trackTimeline.clicks.length; i++) {
                const click = trackTimeline.clicks[i], measure = trackTimeline.measures[click.measureIndex];
                assert(click.time >= measure.start - 1e-8 && click.time < measure.end);
                if (i) assert(click.time > trackTimeline.clicks[i - 1].time, `${filename}: duplicate track ${track.index} accent`);
                assert.equal(click.accentLevel === 3, click.accent);
            }
        }
        if (score.title === 'Handmade Cities') assert(!timeline.clicks.some(c => c.time === 0 && c.accent));
        summaries.push({title: score.title, clicks: timeline.clicks.length, groups: [...new Set(timeline.clicks.map(c => c.grouping).filter(Boolean))],
            meters: [...new Set(timeline.clicks.map(c => `${c.numerator}/${c.denominator}`))]});
    }
}
assert(summaries.length, 'No Guitar Pro fixtures were found');
console.log(JSON.stringify({passed: true, syntheticCases: 'mixed meters, explicit beam groups and overrides, selected-track offbeat accents, tempo changes, repeats, pickups, alignment, bounds', scores: summaries}, null, 2));
