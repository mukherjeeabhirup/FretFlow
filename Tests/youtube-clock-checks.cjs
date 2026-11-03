'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../Resources/YouTubeClock.js'), 'utf8')
    .replace('__FRETFLOW_CLOCK_CONFIG__', JSON.stringify({videoID: 'abcdefghijk', loadID: 'one-load'}));
let documentNumber = 0;

function fixture(address = 'https://www.youtube.com/embed/abcdefghijk', options = {}) {
    const messages = [], intervals = [], events = {}, pageEvents = {};
    let reads = 0, ad = false, videos = [];
    const document = {
        querySelector(selector) { reads++; return ad && selector.includes('.ad-showing') ? {} : null; },
        querySelectorAll(selector) { reads++; return selector === 'video.html5-main-video' ? videos.filter(v => v.main) : videos; },
        addEventListener(name, callback) { events[name] = callback; }
    };
    const window = {
        crypto: {randomUUID: () => '00000000-0000-4000-8000-' + String(++documentNumber).padStart(12, '0')},
        webkit: {messageHandlers: {youtubeClock: {postMessage(value) { messages.push(value); }}}},
        setInterval(fn, ms) { assert.equal(ms, 50); intervals.push(fn); return intervals.length; },
        clearInterval() {}, addEventListener(name, callback) { pageEvents[name] = callback; }
    };
    window.top = options.mainFrame ? window : {};
    let timestamp = 1_700_000_000_000;
    const context = vm.createContext({window, document, location: new URL(address), Date: {now: () => timestamp},
        performance: {timeOrigin: options.documentStartedAt ?? 1_699_999_999_500}});
    vm.runInContext(source, context);
    return {messages, intervals, events, pageEvents, get reads() { return reads; },
        setVideos(value) { videos = value; }, setAd(value) { ad = value; },
        advance(ms) { timestamp += ms; },
        event(name) { events[name]({type: name}); },
        poll(expected = {}) {
            const latest = messages.at(-1);
            return window.__fretFlowReadClock(Object.assign({loadID: 'one-load', videoID: 'abcdefghijk',
                documentID: latest.documentID}, expected));
        },
        tick() { timestamp += 50; intervals.forEach(fn => fn()); }};
}
function video(values = {}) {
    const object = {};
    const properties = Object.assign({main: true, currentTime: 4.125, duration: 200, playbackRate: 1,
        paused: false, ended: false, seeking: false, readyState: 4}, values);
    for (const [key, value] of Object.entries(properties)) {
        Object.defineProperty(object, key, {get: () => properties[key], set() { throw new Error('Clock changed a media property'); }});
    }
    Object.defineProperty(object, 'updateFixture', {value(values) { Object.assign(properties, values); }});
    return object;
}

for (const address of ['https://www.youtube.com/embed/XXXXXXXXXXX', 'https://www.youtube.com/watch?v=abcdefghijk',
    'https://youtube.com.evil.test/embed/abcdefghijk', 'http://www.youtube.com/embed/abcdefghijk',
    'https://www.youtube.com:444/embed/abcdefghijk', 'https://name@www.youtube.com/embed/abcdefghijk', 'https://com.local.fretflow']) {
    const f = fixture(address);
    assert.equal(f.reads, 0, 'Unrelated frame DOM was inspected');
    assert.equal(f.messages.length, 0);
    assert.equal(f.intervals.length, 0);
}
assert.equal(fixture(undefined, {mainFrame: true}).reads, 0);
const f = fixture();
assert.equal(f.messages.at(-1).kind, 'unavailable');
f.setVideos([video()]); f.tick();
const sample = f.messages.at(-1);
assert.equal(sample.kind, 'sample'); assert.equal(sample.position, 4.125);
assert.equal(sample.videoID, 'abcdefghijk'); assert.equal(sample.loadID, 'one-load');
assert.equal(sample.generatedAt, 1_700_000_000_050); assert.equal(sample.sequence, 2);
assert.equal(sample.documentStartedAt, 1_699_999_999_500);
const reloaded = fixture(undefined, {documentStartedAt: 1_700_000_000_000});
assert.equal(reloaded.messages.at(-1).sequence, 1);
assert.notEqual(reloaded.messages.at(-1).documentID, sample.documentID,
    'A same-URL iframe reload reused the old document identity');
assert.equal(reloaded.messages.at(-1).documentStartedAt, 1_700_000_000_000);
f.setVideos([video({paused: true})]); f.events.pause();
assert.equal(f.messages.at(-1).paused, true, 'Pause event must report without waiting for the interval');
f.setVideos([video({seeking: true})]); f.events.seeking();
assert.equal(f.messages.at(-1).seeking, true);
f.setVideos([video({playbackRate: 0.5})]); f.events.ratechange();
assert.equal(f.messages.at(-1).rate, 0.5);
f.setAd(true); f.tick();
assert.equal(f.messages.at(-1).kind, 'advertisement');
assert.equal(f.messages.at(-1).position, undefined, 'Ad position must not be offered as the song clock');
f.setAd(false); f.setVideos([video(), video()]); f.tick();
assert.equal(f.messages.at(-1).kind, 'unavailable', 'Ambiguous multiple videos must not select an arbitrary clock');
f.setVideos([video({main: false})]); f.tick();
assert.equal(f.messages.at(-1).kind, 'sample', 'A unique video remains usable if YouTube changes the CSS class');
f.setVideos([video({duration: Infinity})]); f.tick();
assert.equal(f.messages.at(-1).kind, 'unavailable');
const before = f.messages.length; f.pageEvents.pagehide(); f.tick();
assert.equal(f.messages.length, before, 'A discarded frame kept sending clock messages');
const privateEmbed = fixture('https://www.youtube-nocookie.com/embed/abcdefghijk');
privateEmbed.setVideos([video()]); privateEmbed.tick();
assert.equal(privateEmbed.messages.at(-1).kind, 'sample');
// Suspend page intervals for several seconds, as WebKit may do while hidden.
// Native calls still read the current element without touching transport.
const hidden = fixture();
const media = video({currentTime: 10});
hidden.setVideos([media]); hidden.tick();
const beforePoll = hidden.messages.at(-1);
hidden.advance(5_000); media.updateFixture({currentTime: 15});
assert.equal(hidden.messages.at(-1), beforePoll, 'The fixture unexpectedly ran a hidden page timer');
assert.equal(hidden.poll(), true);
assert.equal(hidden.messages.at(-1).position, 15);
assert.equal(hidden.messages.at(-1).generatedAt - beforePoll.generatedAt, 5_000);
const pollCount = hidden.messages.length;
for (const expected of [{loadID: 'retired'}, {videoID: 'XXXXXXXXXXX'}, {documentID: 'retired'}]) {
    assert.equal(hidden.poll(expected), false);
    assert.equal(hidden.messages.length, pollCount, 'A retired native poll emitted media data');
}
// A playing property is allowed to stay true during a stall; emit the waiting
// signal even before readyState changes and retain it through native polling.
hidden.event('waiting');
assert.equal(hidden.messages.at(-1).buffering, true);
hidden.advance(50); hidden.poll();
assert.equal(hidden.messages.at(-1).buffering, true);
media.updateFixture({currentTime: 15.05}); hidden.advance(50); hidden.poll();
assert.equal(hidden.messages.at(-1).buffering, false, 'Native-observed motion must recover a missed playing event');
hidden.event('stalled'); assert.equal(hidden.messages.at(-1).buffering, true);
hidden.event('playing'); assert.equal(hidden.messages.at(-1).buffering, false);
media.updateFixture({paused: true}); hidden.event('pause');
assert.equal(hidden.messages.at(-1).paused, true);
media.updateFixture({paused: false}); hidden.event('stalled');
media.updateFixture({seeking: true, currentTime: 3}); hidden.event('seeking');
assert.equal(hidden.messages.at(-1).seeking, true);
assert.equal(hidden.messages.at(-1).buffering, false, 'A backward seek retained a stall at the old position');
media.updateFixture({seeking: false, playbackRate: 0.5}); hidden.event('ratechange');
assert.equal(hidden.messages.at(-1).rate, 0.5);
media.updateFixture({currentTime: 3.025}); hidden.event('visibilitychange');
assert.equal(hidden.messages.at(-1).position, 3.025, 'Visibility restoration should refresh immediately');
const retiredCount = hidden.messages.length;
hidden.pageEvents.pagehide(); hidden.advance(1_000);
assert.equal(hidden.poll(), false);
assert.equal(hidden.messages.length, retiredCount);
console.log('YouTube clock script checks passed: exact embed scope, read-only media state, event timing, hidden native polling, buffering/seek recovery, retirement, ads and ambiguous video rejection.');
