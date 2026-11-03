// Offline simulated bridge checks. No remote scripts, media, scores or devices.
// node Tests/youtube-player-checks.cjs Resources/YouTube.html
'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const html = fs.readFileSync(process.argv[2] || path.join(__dirname, '../Resources/YouTube.html'), 'utf8');
const config = {videoID: 'abcdefghijk', loadID: 'test-load', origin: 'https://com.local.fretflow'};
const source = html.match(/<script>([\s\S]*?)<\/script>/)[1].replace('__FRETFLOW_CONFIG__', JSON.stringify(config));
function fixture() {
    const messages = [], calls = [], ticks = [], scripts = [], events = {}, cleared = [];
    let options, state = 5, rate = 1, time = 0, timestamp = 1_700_000_000_000;
    const mockPlayer = {
        getVideoData: () => ({title: 'Synthetic 🎸 <title>'}), getCurrentTime: () => time, getDuration: () => 210,
        getPlayerState: () => state, getPlaybackRate: () => rate, getAvailablePlaybackRates: () => [0.5, 0.75, 1, 1.25],
        playVideo: () => { calls.push('play'); state = 1; }, pauseVideo: () => { calls.push('pause'); state = 2; },
        seekTo: (value, allow) => { calls.push(['seek', value, allow]); time = value; },
        setPlaybackRate: value => { calls.push(['rate', value]); }
    };
    const window = {webkit: {messageHandlers: {youtube: {postMessage: value => messages.push(value)}}},
        setInterval(fn, ms) { assert.equal(ms, 100); ticks.push(fn); return ticks.length; },
        addEventListener(name, fn) { events[name] = fn; }};
    const context = {window, Date: {now: () => timestamp},
        document: {createElement: () => ({}), head: {appendChild: value => scripts.push(value)}},
        YT: {Player: function (id, opts) { options = opts; return mockPlayer; }}, clearInterval: id => cleared.push(id)};
    vm.runInNewContext(source, context);
    return {messages, calls, ticks, scripts, events, cleared, window,
        get options() { return options; },
        set observed(value) { ({state = state, rate = rate, time = time} = value); },
        advance(ms) { timestamp += ms; },
        ready() { window.onYouTubeIframeAPIReady(); options.events.onReady(); },
        poll(expected = config) { return window.fretFlowPlayer.readClock(expected); }};
}
const f = fixture();
assert.equal(f.scripts.length, 1); assert.equal(f.calls.length, 0); assert.equal(f.messages.length, 0);
assert.equal(f.poll(), false, 'Native polling before ready must not create a snapshot');
f.ready();
assert.equal(f.options.playerVars.autoplay, 0); assert.equal(f.options.playerVars.controls, 1);
assert.equal(f.options.playerVars.origin, config.origin); assert.equal(f.options.playerVars.widget_referrer, config.origin);
assert.equal(f.messages.at(-1).kind, 'ready'); assert.equal(f.messages.at(-1).title, 'Synthetic 🎸 <title>');
assert.equal(f.messages.at(-1).ready, true);
assert.equal(f.messages.at(-1).sequence, 1); assert.equal(f.messages.at(-1).generatedAt, 1_700_000_000_000);
f.options.events.onReady();
assert.equal(f.messages.length, 1); assert.equal(f.ticks.length, 1, 'Duplicate readiness installed duplicate timers');
// Restore persisted position/rate through readiness: leave the cue paused.
f.window.fretFlowPlayer.seek(12); assert.equal(f.calls.at(-1), 'pause');
f.window.fretFlowPlayer.setRate(0.5);
assert.equal(f.messages.at(-1).rate, 1, 'Requested rate must not masquerade as the observed rate');
assert.equal(f.messages.at(-1).state, 2);
const restartIndex = f.calls.length;
f.window.fretFlowPlayer.playFromStart();
assert.deepEqual(f.calls.slice(restartIndex), [['seek', 0, true], 'play']);
f.window.fretFlowPlayer.play(); f.options.events.onStateChange(); assert.equal(f.messages.at(-1).state, 1);
f.window.fretFlowPlayer.seek(28); assert.deepEqual(f.calls.at(-1), ['seek', 28, true]);
f.observed = {rate: 0.5}; f.options.events.onPlaybackRateChange(); assert.equal(f.messages.at(-1).rate, 0.5);
f.ticks[0](); assert.equal(f.messages.at(-1).position, 28); assert.equal(f.messages.at(-1).loadID, config.loadID);
// No page timer runs while hidden. Polling samples current API state, with its
// generation time. The native source policy separately forbids this coarse
// source from scheduling clicks even if its cached playing/time getters move.
const hiddenCount = f.messages.length, callsBeforePoll = f.calls.length;
f.advance(5_000); f.observed = {state: 3, time: 28.2};
assert.equal(f.messages.length, hiddenCount);
assert.equal(f.poll(), true); assert.equal(f.messages.at(-1).state, 3);
assert.equal(f.messages.at(-1).ready, true, 'Fresh polling must recover a delayed initial ready message');
assert.equal(f.messages.at(-1).generatedAt, 1_700_000_005_000);
assert.equal(f.calls.length, callsBeforePoll, 'Clock polling changed transport');
assert.equal(f.window.fretFlowPlayer.readClock(), false);
for (const expected of [{...config, loadID: 'retired'}, {...config, videoID: 'XXXXXXXXXXX'}]) {
    const count = f.messages.length;
    assert.equal(f.poll(expected), false); assert.equal(f.messages.length, count);
}
f.observed = {state: 1, time: 28.2}; f.advance(50); f.poll();
f.advance(50); f.poll(); assert.equal(f.messages.at(-1).position, 28.2, 'Frozen getters were extrapolated by the wrapper');
f.observed = {state: 2}; f.options.events.onStateChange(); assert.equal(f.messages.at(-1).state, 2);
f.options.events.onAutoplayBlocked(); assert.equal(f.messages.at(-1).kind, 'blocked');
f.options.events.onError({data: 153}); assert.equal(f.messages.at(-1).code, 153);
for (let i = 1; i < f.messages.length; i++) assert.ok(f.messages[i].sequence > f.messages[i - 1].sequence);
f.events.pagehide(); const retiredCount = f.messages.length;
assert.equal(f.cleared.length, 1); assert.equal(f.poll(), false);
f.ticks[0](); f.options.events.onReady(); f.options.events.onError({data: 100});
assert.equal(f.messages.length, retiredCount, 'A discarded player kept emitting clock events');
console.log('Offline YouTube player checks passed: cue/restore, identity, event timestamps, hidden native polls, frozen getters, actual rates and retirement.');
