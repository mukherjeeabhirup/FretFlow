#!/usr/bin/env node
'use strict';
// Usage: node Tests/timeline-checks.cjs [directory-containing-gp-files]
// Optional: FRET_FLOW_WEB_DIR, FRET_FLOW_GP_DIR. No npm dependencies required.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const app = path.resolve(__dirname, '..');
const web = path.resolve(process.env.FRET_FLOW_WEB_DIR || path.join(app, 'Resources/Web'));
const fixtures = path.resolve(process.argv[2] || process.env.FRET_FLOW_GP_DIR || path.join(app, 'Resources/Library'));
const at = require(path.join(web, 'vendor/alphaTab.min.js'));
const timing = require(path.join(web, 'timeline.js'));
const near = (actual, expected, tolerance = 1e-7) => assert(Math.abs(actual - expected) < tolerance, `${actual} != ${expected}`);

assert.equal(timing.annotationTime('[A] (1:07)'), 67);
assert.equal(timing.annotationTime('Verse'), null);
assert.equal(timing.annotationTime('(0:99)'), null);
const tempo = timing.tempoMap({division: 960, events: [
    {type: 81, tick: 0, beatsPerMinute: 120},
    {type: 81, tick: 960, beatsPerMinute: 60}
]}, 81);
near(tempo.tickToTime(960), 0.5);
near(tempo.tickToTime(1920), 1.5);

// A blank GPX pickup must not create a zero-length loop target or displace
// playback indices. Repeated real bars still retain their printed numbers and
// pass counts, even when another empty placeholder appears between them.
const emptyBars = [{index: 0}, {index: 1}, {index: 2}, {index: 3}];
const pickupLookup = {masterBars: [
    {masterBar: emptyBars[0], start: 0, end: 0},
    {masterBar: emptyBars[1], start: 0, end: 960},
    {masterBar: emptyBars[2], start: 960, end: 960},
    {masterBar: emptyBars[3], start: 960, end: 1920},
    {masterBar: emptyBars[1], start: 1920, end: 2880}
]};
const pickupTimeline = timing.build({}, {division: 960, events: []}, pickupLookup, 81);
assert.deepEqual(pickupTimeline.measures.map(({index, barIndex, occurrence}) => ({index, barIndex, occurrence})), [
    {index: 0, barIndex: 1, occurrence: 0},
    {index: 1, barIndex: 3, occurrence: 0},
    {index: 2, barIndex: 1, occurrence: 1}
]);
assert.equal(pickupTimeline.measureAt(0).barIndex, 1);
assert.equal(pickupTimeline.measureAt(0.5).barIndex, 3);
assert.equal(pickupTimeline.measureAt(1).occurrence, 1);
assert.equal(pickupTimeline.occurrenceForBar(1, 1.25).index, 2);
assert.equal(pickupTimeline.occurrenceForBar(0, 0), null);
near(pickupTimeline.duration, 1.5);
assert.equal(pickupLookup.masterBars.length, 5, 'Playback filtering mutated the printed score lookup');

// Recording lead-in is a content-time correction shared by every view of the
// timeline. It must not alter tempo, repeat structure or denominator pulses.
const offsetBars = [
    {index: 0, timeSignatureNumerator: 4, timeSignatureDenominator: 4},
    {index: 1, timeSignatureNumerator: 7, timeSignatureDenominator: 8}
];
const offsetMidi = {division: 960, events: [{type: 81, tick: 0, beatsPerMinute: 120}]};
const offsetLookup = {masterBars: [
    {masterBar: offsetBars[0], start: 0, end: 3840},
    {masterBar: offsetBars[1], start: 3840, end: 7200},
    {masterBar: offsetBars[0], start: 7200, end: 11040}
]};
const offsetScore = {masterBars: offsetBars};
const automatic = timing.build(offsetScore, offsetMidi, offsetLookup, 81);
const delayed = timing.build(offsetScore, offsetMidi, offsetLookup, 81, {offsetAdjustment: 0.75});
near(delayed.alignment.inferredOffset, automatic.alignment.offset);
near(delayed.alignment.adjustment, 0.75);
near(delayed.alignment.offset, 0.75);
near(delayed.duration, automatic.duration + 0.75);
near(delayed.toScore(0), 0);
near(delayed.toScore(0.75), 0);
delayed.measures.forEach((measure, index) => {
    const original = automatic.measures[index];
    near(measure.start, original.start + 0.75);
    near(measure.end, original.end + 0.75);
    near(delayed.toScore(measure.start), measure.scoreStart);
    assert.equal(measure.occurrence, original.occurrence);
    assert.equal(delayed.occurrenceForBar(measure.barIndex, measure.start).index, index);
});
delayed.clicks.forEach((click, index) => {
    near(click.time, automatic.clicks[index].time + 0.75);
    assert.equal(click.bpm, automatic.clicks[index].bpm);
    assert.equal(click.accentLevel, automatic.clicks[index].accentLevel);
});
assert(delayed.clicks.every(click => click.time >= 0.75), 'No click may sound in an unnotated video lead-in');
const longIntro = timing.build(offsetScore, offsetMidi, offsetLookup, 81, {offsetAdjustment: 120});
near(longIntro.clicks[0].time, 120);
near(longIntro.toScore(120.5), 0.5);
near(timing.offsetAdjustment(Infinity), 0);
near(timing.offsetAdjustment(NaN), 0);
near(timing.offsetAdjustment(121), 120);
near(timing.offsetAdjustment(-31), -30);
// Retain the inferred whole-second intro and add only the recording correction.
offsetBars[0].section = {text: '(0:04)'};
const correctedHint = timing.build(offsetScore, offsetMidi, offsetLookup, 81, {offsetAdjustment: 0.25});
near(correctedHint.alignment.inferredOffset, 4);
near(correctedHint.alignment.offset, 4.25);
near(correctedHint.clicks[0].time, 4.25);
delete offsetBars[0].section;
// Earlier offsets can fully hide bars before media zero. They must not create
// zero-length loop targets, duplicate clicks at zero, or displaced indices.
const earlier = timing.build(offsetScore, offsetMidi, offsetLookup, 81, {offsetAdjustment: -2.25});
assert.equal(earlier.measures.length, 2);
assert.equal(earlier.measures[0].barIndex, 1);
assert.equal(earlier.measures[1].barIndex, 0);
assert.equal(earlier.measures[1].occurrence, 1);
earlier.measures.forEach((measure, index) => {
    assert(measure.end > measure.start);
    assert.equal(measure.index, index);
});
assert(earlier.clicks.every(click => click.time >= 0 && earlier.measures[click.measureIndex].barIndex === click.barIndex));
assert(earlier.clicks.every((click, index, all) => !index || click.time > all[index - 1].time));
const beforeVideo = timing.build(offsetScore, offsetMidi, offsetLookup, 81, {offsetAdjustment: -30});
assert.equal(beforeVideo.measures.length, 0);
assert.equal(beforeVideo.clicks.length, 0);
near(beforeVideo.duration, 0);
near(beforeVideo.scoreDuration, automatic.scoreDuration);
assert.equal(offsetLookup.masterBars.length, 3, 'Alignment must not mutate expanded score timing');

// Audio matching uses generated attacks from every part, in nominal score
// seconds. Chord duplicates, non-notes and silent note-ons cannot bias it.
const referenceMidi = {division: 960, tickShift: 960, events: [
    {type: 81, tick: 0, beatsPerMinute: 120},
    {type: 81, tick: 1920, beatsPerMinute: 60},
    {type: 128, tick: 2880, noteVelocity: 80, track: 2},
    {type: 128, tick: 960, noteVelocity: 70, track: 0},
    {type: 128, tick: 964, noteVelocity: 95, track: 1},
    {type: 128, tick: 960, noteVelocity: 60, track: 2},
    {type: 128, tick: 980, noteVelocity: 90, track: 0},
    {type: 128, tick: 1920, noteVelocity: 0, track: 0},
    {type: 144, tick: 3840, noteVelocity: 80, track: 0},
    {type: 242, tick: 4800, noteVelocity: 80, track: 0},
    {type: 128, tick: -1, noteVelocity: 80, track: 0},
    {type: 128, tick: NaN, noteVelocity: 80, track: 0},
    {type: 128, tick: 5600, noteVelocity: Infinity, track: 0},
    {type: 128, tick: 58560, noteVelocity: 80, track: 0},
    {type: 128, tick: 58561, noteVelocity: 80, track: 0}
]};
const referenceTimes = timing.referenceAttacks(referenceMidi, timing.tempoMap(referenceMidi, 81));
assert.equal(referenceTimes.length, 4);
[0.5, 980 / 1920, 2, 60].forEach((time, index) => near(referenceTimes[index], time));
const referenceOriginal = timing.build(offsetScore, referenceMidi, offsetLookup, 81);
const referenceShifted = timing.build(offsetScore, referenceMidi, offsetLookup, 81, {offsetAdjustment: 30, trackIndex: 2});
assert.deepEqual(referenceOriginal.referenceAttacks, referenceTimes, 'tickShift was applied twice to generated note events');
assert.deepEqual(referenceShifted.referenceAttacks, referenceTimes, 'Recording offset or selected part changed reference attacks');
assert.equal(referenceMidi.events[2].tick, 2880, 'Reference extraction reordered source MIDI events');
const denseMidi = {division: 960, events: Array.from({length: 6_000}, (_, index) =>
    ({type: 128, tick: index * 20, noteVelocity: 80}))};
assert.equal(timing.referenceAttacks(denseMidi, timing.tempoMap(denseMidi, 81)).length, 2_000,
    'Audio-reference metadata exceeded its bounded bridge payload');

const results = [];
for (const filename of fs.readdirSync(fixtures).filter(name => /\.(?:gp[345]?|gpx)$/i.test(name)).sort()) {
    const score = at.importer.ScoreLoader.loadScoreFromBytes(fs.readFileSync(path.join(fixtures, filename)), new at.Settings());
    const midi = new at.midi.MidiFile();
    const generator = new at.midi.MidiFileGenerator(score, null, new at.midi.AlphaSynthMidiFileHandler(midi));
    generator.generate();
    const timeline = timing.build(score, midi, generator.tickLookup, at.midi.MidiEventType.TempoChange);
    assert(timeline.measures.length > 0, `${filename}: no measures`);
    assert(timeline.duration > 0, `${filename}: no duration`);
    assert(timeline.referenceAttacks.length > 0 && timeline.referenceAttacks.length <= 2_000, `${filename}: missing or unbounded audio references`);
    assert(timeline.referenceAttacks.every((time, index, all) => time >= 0 && time <= 60
        && (!index || time - all[index - 1] > 0.005)), `${filename}: invalid audio reference order`);
    const withRecordingOffset = timing.build(score, midi, generator.tickLookup, at.midi.MidiEventType.TempoChange,
        {offsetAdjustment: 1.75, trackIndex: score.tracks.length - 1});
    assert.deepEqual(withRecordingOffset.referenceAttacks, timeline.referenceAttacks,
        `${filename}: audio references must remain independent of selected part and video adjustment`);
    timeline.measures.forEach((measure, index) => {
        assert(measure.end > measure.start, `${filename}: nonpositive measure ${index}`);
        assert.equal(measure.index, index);
        if (index) near(measure.start, timeline.measures[index - 1].end);
        // Negative alignment offsets can put the opening pickup before media
        // time zero; only unclamped positions have an exact inverse.
        if (measure.start > 0) near(timeline.toScore(timeline.toMedia(measure.scoreStart)), measure.scoreStart);
        const middle = (measure.start + measure.end) / 2;
        assert.equal(timeline.measureAt(middle).index, index);
        assert.equal(timeline.occurrenceForBar(measure.barIndex, middle).index, index);
    });
    if (score.title === 'Ciel') near(timeline.alignment.offset, 4);
    if (score.title === 'Manala') assert(timeline.alignment.rejected.some(point => point.text.includes('4:42')));
    if (score.title === 'Ruin') {
        assert(timeline.alignment.rejected.some(point => point.text.includes('2:28')));
        near(timeline.referenceAttacks[0], 23.1);
    }
    if (score.title === 'Electric Sunrise') near(timeline.referenceAttacks[0], 0);
    if (score.title === 'Handmade Cities') near(timeline.referenceAttacks[0], 60 / 103);
    if (score.title === 'An Unnameable Desire') {
        assert.equal(timeline.measures.length, 100);
        assert.equal(timeline.measures[2].barIndex, 0);
        assert.equal(timeline.measures[2].occurrence, 1);
        near(timeline.measures[2].start, 2 * 7 * 60 / 174);
    }
    if (score.title === 'Heart' && generator.tickLookup.masterBars[0].end === 0) {
        assert.equal(timeline.measures.length, generator.tickLookup.masterBars.length - 1);
        assert.equal(timeline.measures[0].barIndex, 1);
        assert.equal(timeline.measureAt(0).index, 0);
        assert.equal(timeline.occurrenceForBar(0, 0), null);
    }
    results.push({title: score.title, printedMeasures: score.masterBars.length,
        playbackMeasures: timeline.measures.length, offset: timeline.alignment.offset,
        rejectedHints: timeline.alignment.rejected.length});
}
assert(results.length, `No Guitar Pro fixtures found in ${fixtures}`);
console.log(JSON.stringify({passed: true, scores: results}, null, 2));
