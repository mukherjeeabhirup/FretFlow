#!/usr/bin/env node
'use strict';
// Usage: NODE_PATH=/path/to/node_modules node Tests/renderer-checks.cjs [GP-directory]
// Needs playwright; uses a fresh temporary browser profile and only local fixtures.
// Options: FRET_FLOW_WEB_DIR, FRET_FLOW_GP_DIR, FRET_FLOW_BROWSER (chromium/webkit),
// FRET_FLOW_BROWSER_EXECUTABLE, FRET_FLOW_PLAYWRIGHT_MODULE, FRET_FLOW_SCREENSHOT.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const playwright = require(process.env.FRET_FLOW_PLAYWRIGHT_MODULE || 'playwright');
const app = path.resolve(__dirname, '..');
const web = path.resolve(process.env.FRET_FLOW_WEB_DIR || path.join(app, 'Resources/Web'));
const fixtures = path.resolve(process.argv[2] || process.env.FRET_FLOW_GP_DIR || path.join(app, 'Resources/Library'));
const browserName = process.env.FRET_FLOW_BROWSER || 'chromium';
const macChrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const executablePath = process.env.FRET_FLOW_BROWSER_EXECUTABLE
    || (browserName === 'chromium' && fs.existsSync(macChrome) ? macChrome : undefined);

async function run() {
    assert(playwright[browserName], `Unknown browser ${browserName}`);
    const browser = await playwright[browserName].launch({headless: true, executablePath,
        args: browserName === 'chromium' ? ['--allow-file-access-from-files'] : []});
    try {
        const page = await browser.newPage({viewport: {width: 1100, height: 850}});
        const errors = [], networkRequests = [], summaries = [];
        await page.addInitScript(() => {
            window.messages = [];
            window.webkit = {messageHandlers: {fretflow: {postMessage: message => window.messages.push(message)}}};
        });
        page.on('pageerror', error => errors.push(error.message));
        page.on('request', request => { if (/^https?:/.test(request.url())) networkRequests.push(request.url()); });
        await page.goto(pathToFileURL(path.join(web, 'index.html')).href);
        await page.waitForFunction(() => window.messages.some(message => message.type === 'ready'));
        async function load(filename, adjustment = 0, alignmentRevision = 0) {
            await page.evaluate(({base64, filename, adjustment, alignmentRevision}) => {
                window.messages = [];
                window.FretFlow.loadScore(base64, filename, adjustment, alignmentRevision);
            }, {filename, adjustment, alignmentRevision, base64: fs.readFileSync(path.join(fixtures, filename)).toString('base64')});
            await page.waitForFunction(() => window.messages.some(message => message.type === 'score')
                && window.FretFlow.diagnostics().rendered);
            return page.evaluate(() => window.messages.find(message => message.type === 'score'));
        }
        const filenames = fs.readdirSync(fixtures).filter(name => /\.(gp[345]?|gpx)$/i.test(name)).sort();
        assert(filenames.length, `No Guitar Pro fixtures found in ${fixtures}`);
        let repeatFixture, layoutFixture;
        for (const filename of filenames) {
            const score = await load(filename);
            assert(score.duration > 0);
            assert(score.measures.length > 0);
            assert(score.tracks.length > 0);
            assert.equal(score.clickTrackError, null, `${filename}: click-grid error`);
            assert(score.clicks.length > 0, `${filename}: missing native click metadata`);
            assert(score.referenceAttacks.length > 0 && score.referenceAttacks.length <= 2_000,
                `${filename}: missing or unbounded recording-alignment reference attacks`);
            assert(score.referenceAttacks.every((time, index, all) => time >= 0 && time <= 60
                && (!index || time - all[index - 1] > 0.005)), `${filename}: invalid recording-alignment references`);
            score.clicks.forEach((click, index) => {
                const measure = score.measures[click.measureIndex];
                assert(measure && measure.barIndex === click.barIndex);
                assert(click.time >= measure.start - 0.000001 && click.time < measure.end);
                assert([0, 1, 2, 3].includes(click.accentLevel), `${filename}: invalid accent level`);
                assert.equal(click.accent, click.accentLevel === 3);
                if (click.accent) assert.equal(click.beatIndex, 0);
                assert(click.bpm > 0 && click.numerator === measure.numerator && click.denominator === measure.denominator);
                if (index) assert(click.time > score.clicks[index - 1].time);
            });
            score.measures.forEach((measure, index) => {
                assert(measure.end > measure.start);
                if (index) assert(measure.start >= score.measures[index - 1].end - 0.001);
            });
            const middle = score.measures[Math.floor(score.measures.length * 0.55)];
            await page.evaluate(position => window.FretFlow.setClock({position, duration: 1000, isPlaying: false, rate: 1}), middle.start + 0.01);
            const normal = await page.evaluate(() => window.FretFlow.diagnostics());
            assert.equal(normal.measure, middle.index);
            await page.evaluate(position => window.FretFlow.setClock({position, duration: 1000, isPlaying: false, rate: 0.5}), middle.start + 0.01);
            const slower = await page.evaluate(() => window.FretFlow.diagnostics());
            assert(Math.abs(normal.tick - slower.tick) <= 1, 'Playback speed changed the content-position cursor');
            if (score.tracks.length > 1) {
                await page.evaluate(() => window.FretFlow.selectTrack(1));
                assert.equal((await page.evaluate(() => window.FretFlow.diagnostics())).track, 1);
                const partClicks = await page.evaluate(() => window.messages.filter(message => message.type === 'clicks').at(-1));
                assert(partClicks && partClicks.selectedTrack === 1 && partClicks.songID === filename,
                    'Part selection did not send a replacement click grid');
                assert.equal(partClicks.clickTrackError, null);
                assert(partClicks.clicks.length > 0);
                if (score.title === 'Heart') {
                    assert(partClicks.clicks.some(click => click.accentLevel === 2 && click.isSubdivision),
                        'Heart Guitar 2 lost its written offbeat accents');
                    assert.notDeepEqual(partClicks.clicks, score.clicks, 'Heart parts share the wrong accent grid');
                }
                const before = await page.evaluate(() => window.messages.filter(message => message.type === 'clicks').length);
                await page.evaluate(() => window.FretFlow.selectTrack(1));
                const after = await page.evaluate(() => window.messages.filter(message => message.type === 'clicks').length);
                assert.equal(after, before + 1, 'Reselecting the current part must still acknowledge its click grid');
            }
            const transport = await page.evaluate(() => window.messages.filter(message => ['play', 'pause', 'seek'].includes(message.type)));
            assert.equal(transport.length, 0, 'A native clock update fed back into transport control');
            if (filename === filenames[0]) {
                await page.evaluate(position => window.FretFlow.setClock({position, duration: 1000, isPlaying: true, rate: 1}), middle.start + 0.01);
                await page.waitForTimeout(500);
                const stale = await page.evaluate(() => window.FretFlow.diagnostics());
                assert.equal(stale.playing, false, 'A stale native clock left the animated green cursor playing');
                await page.waitForTimeout(120);
                const frozen = await page.evaluate(() => window.FretFlow.diagnostics());
                assert(Math.abs(frozen.time - stale.time) < 1, 'The green cursor advanced after its clock became stale');

                const currentGrid = await page.evaluate(() => window.messages.filter(message => message.type === 'clicks').at(-1)
                    ?? window.messages.find(message => message.type === 'score'));
                await page.evaluate(() => window.FretFlow.setOffsetAdjustment(0.75, 17));
                const aligned = await page.evaluate(() => window.messages.filter(message => message.type === 'timeline').at(-1));
                assert.equal(aligned.alignmentRevision, 17);
                assert.equal(aligned.alignment.adjustment, 0.75);
                assert.equal(aligned.alignment.inferredOffset, score.alignment.offset);
                assert.equal(aligned.alignment.offset, score.alignment.offset + 0.75);
                assert.deepEqual(aligned.referenceAttacks, score.referenceAttacks, 'Video adjustment or part selection shifted nominal attack references');
                assert.equal(aligned.selectedTrack, currentGrid.selectedTrack);
                aligned.clicks.forEach((click, index) => assert(Math.abs(click.time - currentGrid.clicks[index].time - 0.75) < 1e-6,
                    'Recording alignment shifted click timing inconsistently'));
                aligned.measures.forEach((measure, index) => {
                    assert(Math.abs(measure.start - score.measures[index].start - 0.75) < 1e-6);
                    assert(Math.abs(measure.end - score.measures[index].end - 0.75) < 1e-6);
                });
                await page.evaluate(() => window.FretFlow.setClock({position: 0.1, duration: 1000, isPlaying: true, rate: 1}));
                await page.waitForTimeout(100);
                const intro = await page.evaluate(() => window.FretFlow.diagnostics());
                assert.equal(intro.playing, false, 'The green cursor animated during a recording lead-in');
                assert(Math.abs(intro.time) < 1, 'The green cursor advanced before the aligned score start');
                await page.evaluate(position => window.FretFlow.setClock({position, duration: 1000, isPlaying: false, rate: 1}), aligned.measures[1].start + 0.01);
                const alignedNormal = await page.evaluate(() => window.FretFlow.diagnostics());
                await page.evaluate(position => window.FretFlow.setClock({position, duration: 1000, isPlaying: false, rate: 0.5}), aligned.measures[1].start + 0.01);
                const alignedSlow = await page.evaluate(() => window.FretFlow.diagnostics());
                assert(Math.abs(alignedNormal.tick - alignedSlow.tick) <= 1, 'Recording alignment changed with playback speed');
                await page.evaluate(() => window.FretFlow.selectTrack(0));
                const switched = await page.evaluate(() => window.messages.filter(message => message.type === 'clicks').at(-1));
                assert.equal(switched.alignmentRevision, 17);
                assert(Math.abs(switched.clicks[0].time - score.clicks[0].time - 0.75) < 1e-6, 'Part selection lost the saved recording alignment');
                await page.evaluate(() => window.FretFlow.setOffsetAdjustment(120, 18));
                const longIntro = await page.evaluate(() => window.messages.filter(message => message.type === 'timeline').at(-1));
                assert(longIntro.clicks.every(click => click.time >= 120));
                await page.evaluate(() => window.FretFlow.setOffsetAdjustment(-2.25, 19));
                const early = await page.evaluate(() => window.messages.filter(message => message.type === 'timeline').at(-1));
                assert(early.measures.every(measure => measure.end > measure.start), 'Earlier alignment created a zero-length loop');
                assert(early.clicks.every((click, index) => click.time >= 0 && (!index || click.time > early.clicks[index - 1].time)),
                    'Earlier alignment clamped pre-video clicks into a burst');
                const withSavedOffset = await load(filename, 0.5, 20);
                assert.equal(withSavedOffset.alignmentRevision, 20);
                assert.equal(withSavedOffset.alignment.adjustment, 0.5);
                assert.deepEqual(withSavedOffset.referenceAttacks, score.referenceAttacks, 'Saved offset shifted nominal attack references');
                assert(Math.abs(withSavedOffset.clicks[0].time - score.clicks[0].time - 0.5) < 1e-6,
                    'Saved alignment was missing from the initial loaded score');
                await load(filename);
            }
            if (score.title === 'An Unnameable Desire') repeatFixture = filename;
            if (score.title === 'Manala') layoutFixture = filename;
            summaries.push({title: score.title, playbackMeasures: score.measures.length,
                offset: score.alignment.offset, rejectedHints: score.alignment.rejectedHints});
        }
        if (repeatFixture) {
            const score = await load(repeatFixture);
            await page.evaluate(() => window.FretFlow.setClock({position: 5, duration: 300, isPlaying: false, rate: 1}));
            await page.waitForTimeout(100);
            await page.locator('.at-cursor-bar').scrollIntoViewIfNeeded();
            const cursor = await page.locator('.at-cursor-bar').boundingBox();
            assert(cursor, 'No bar highlight');
            await page.mouse.click(cursor.x + cursor.width * 0.55, cursor.y + cursor.height * 0.75);
            await page.waitForFunction(() => window.messages.some(message => message.type === 'seek'));
            const seek = await page.evaluate(() => window.messages.find(message => message.type === 'seek'));
            assert(Math.abs(seek.position - score.measures[2].start) < 0.01, 'Repeat click jumped to the first pass');
            await page.evaluate(end => window.FretFlow.setClock({position: end + 10, duration: end + 30, isPlaying: true, rate: 1}), score.duration);
            const final = await page.evaluate(() => window.FretFlow.diagnostics());
            assert.equal(final.measure, score.measures.length - 1);
            assert(final.time > 230000, 'End of score reset the cursor');
            await page.evaluate(() => { window.FretFlow.setFollow(false); window.FretFlow.setZoom(1.2); });
            const controls = await page.evaluate(() => window.FretFlow.diagnostics());
            assert.equal(controls.follow, false);
            assert.equal(controls.zoom, 1.2);
        }
        if (layoutFixture) {
            // Regression: Manala bar 49's long section title overlapped the palm
            // mute starting on beat 2; bar 39's number printed through its ties.
            // Check actual SVG geometry across the app's window sizes and zooms.
            for (const [width, zoom] of [[588, 0.75], [700, 1], [820, 1.15], [1100, 1.3]]) {
                await page.setViewportSize({width, height: 850});
                await page.evaluate(zoom => { window.FretFlow.setFollow(false); window.FretFlow.setZoom(zoom); }, zoom);
                const score = await load(layoutFixture);
                async function focusBar(barIndex) {
                    const measure = score.measures.find(measure => measure.barIndex === barIndex);
                    assert(measure);
                    await page.evaluate(position => window.FretFlow.setClock({position, duration: 300, isPlaying: false, rate: 1}), measure.start + 0.01);
                    await page.waitForTimeout(150);
                    await page.evaluate(() => {
                        const cursor = document.querySelector('.at-cursor-bar').getBoundingClientRect();
                        document.getElementById('score-scroll').scrollTop += cursor.top - 350;
                    });
                }
                await focusBar(48);
                await page.waitForFunction(() => Array.from(document.querySelectorAll('svg text')).some(e => e.textContent === '[E] (1:03)'));
                const annotations = await page.evaluate(() => {
                    const texts = Array.from(document.querySelectorAll('svg text'));
                    const heading = texts.find(e => e.textContent === '[E] (1:03)').getBoundingClientRect();
                    const nearbyPalmMutes = texts.filter(e => e.textContent === 'P.M.').map(e => e.getBoundingClientRect())
                        .filter(r => r.left < heading.right && r.right > heading.left && Math.abs(r.top - heading.top) < 120);
                    return {heading: heading.toJSON(), palmMutes: nearbyPalmMutes.map(r => r.toJSON())};
                });
                assert(annotations.palmMutes.length, `No palm-mute regression fixture at ${width}px / ${zoom}`);
                for (const palm of annotations.palmMutes) {
                    assert(palm.top >= annotations.heading.bottom + zoom || palm.bottom <= annotations.heading.top - zoom,
                        `Section heading overlaps a palm mute at ${width}px / ${zoom}: ${JSON.stringify(annotations)}`);
                }
                await focusBar(38);
                await page.waitForFunction(() => Array.from(document.querySelectorAll('svg text')).some(e => e.textContent.trim() === '39'));
                const number = await page.evaluate(() => {
                    const labels = Array.from(document.querySelectorAll('svg text')).filter(e => e.textContent.trim() === '39');
                    const label = labels[0];
                    if (!label) return {count: labels.length, missing: true};
                    const rect = label.getBoundingClientRect();
                    const overlappingPaths = Array.from(label.closest('svg').querySelectorAll('path')).filter(e => {
                        const other = e.getBoundingClientRect();
                        return other.width > 0 && other.height > 0 && other.left < rect.right && other.right > rect.left
                            && other.top < rect.bottom && other.bottom > rect.top;
                    });
                    return {count: labels.length, missing: false, collisions: overlappingPaths.length};
                });
                assert.equal(number.missing, false, 'Measure number was lost');
                assert.equal(number.count, 1, 'Measure number duplicated');
                assert.equal(number.collisions, 0, `Measure 39 overlaps a tie at ${width}px / ${zoom}`);
                const slide = await page.evaluate(() => {
                    const bar = document.querySelector('.at-cursor-bar').getBoundingClientRect();
                    const labels = Array.from(document.querySelectorAll('svg text'))
                        .filter(e => e.textContent === 'sl.')
                        .map(element => ({element, rect: element.getBoundingClientRect()}))
                        .filter(({rect}) => rect.left >= bar.left && rect.right <= bar.right && rect.top >= bar.top && rect.bottom <= bar.bottom)
                        .sort((a, b) => a.rect.top - b.rect.top || a.rect.left - b.rect.left);
                    if (!labels.length) return {missing: true};
                    const {element, rect} = labels[0];
                    let collisions = 0;
                    // Test the curve itself, not its rectangular bounding box:
                    // a valid slur deliberately leaves a gap around its label.
                    for (const curve of element.closest('svg').querySelectorAll('path')) {
                        const bounds = curve.getBoundingClientRect();
                        if (bounds.right <= rect.left || bounds.left >= rect.right || bounds.bottom <= rect.top || bounds.top >= rect.bottom) continue;
                        const length = curve.getTotalLength(), transform = curve.getScreenCTM();
                        for (let distance = 0; distance <= length; distance += 0.5) {
                            const point = curve.getPointAtLength(distance).matrixTransform(transform);
                            if (point.x > rect.left + 1 && point.x < rect.right - 1 && point.y > rect.top + 1 && point.y < rect.bottom - 1) {
                                collisions++;
                                break;
                            }
                        }
                    }
                    return {missing: false, collisions};
                });
                assert.equal(slide.missing, false, 'Legato slide label was lost');
                assert.equal(slide.collisions, 0, `Legato slide label crosses a chord tie at ${width}px / ${zoom}`);
            }
        }
        if (process.env.FRET_FLOW_SCREENSHOT) await page.screenshot({path: process.env.FRET_FLOW_SCREENSHOT});
        assert.deepEqual(errors, [], 'Browser script errors');
        assert.deepEqual(networkRequests, [], 'Score renderer made a network request');
        console.log(JSON.stringify({passed: true, browser: browserName, scores: summaries}, null, 2));
    } finally { await browser.close(); }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
