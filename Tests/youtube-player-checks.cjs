// Offline regression checks: the YouTube API, DOM, bridge, and timers are mocked.
// No remote scripts are loaded and no video/audio is played.
// Run from the FretFlow directory:
// node Tests/youtube-player-checks.cjs Resources/YouTube.html

const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const html = fs.readFileSync(process.argv[2], 'utf8');
const config = {videoID:'abcdefghijk',loadID:'test-load',origin:'https://com.local.fretflow'};
const source = html.match(/<script>([\s\S]*?)<\/script>/)[1].replace('__FRETFLOW_CONFIG__',JSON.stringify(config));
const messages = [], calls = [], ticks = [], scripts = [];
let options, state = 5, rate = 1, time = 0;
const mockPlayer = {
 getVideoData:()=>({title:'Unicode 🎸 <title>'}), getCurrentTime:()=>time, getDuration:()=>210,
 getPlayerState:()=>state,getPlaybackRate:()=>rate,getAvailablePlaybackRates:()=>[0.5,0.75,1,1.25],
 playVideo:()=>{calls.push('play');state=1;},pauseVideo:()=>{calls.push('pause');state=2;},
 seekTo:(value,allow)=>{calls.push(['seek',value,allow]);time=value;},
 setPlaybackRate:value=>{calls.push(['rate',value]);}
};
const window = {webkit:{messageHandlers:{youtube:{postMessage:v=>messages.push(v)}}},setInterval:fn=>{ticks.push(fn);return 1;},addEventListener:()=>{}};
const context = {window, document:{createElement:()=>({}),head:{appendChild:v=>scripts.push(v)}},YT:{Player:function(id,opts){options=opts;return mockPlayer;}},clearInterval:()=>{}};
vm.createContext(context);vm.runInContext(source,context);
assert.equal(scripts.length,1);assert.equal(calls.length,0);assert.equal(messages.length,0);
window.onYouTubeIframeAPIReady();assert.equal(options.playerVars.autoplay,0);assert.equal(options.playerVars.controls,1);
assert.equal(options.playerVars.origin,config.origin);assert.equal(options.playerVars.widget_referrer,config.origin);
options.events.onReady();assert.equal(messages.at(-1).kind,'ready');assert.equal(messages.at(-1).title,'Unicode 🎸 <title>');
window.fretFlowPlayer.seek(12);assert.equal(calls.at(-1),'pause');
const restartIndex = calls.length;
window.fretFlowPlayer.playFromStart();
assert.deepEqual(calls.slice(restartIndex), [['seek',0,true],'play'],
 'A restart from paused/cued playback must seek then play without queuing a pause');
window.fretFlowPlayer.play();options.events.onStateChange();assert.equal(messages.at(-1).state,1);
window.fretFlowPlayer.seek(28);assert.deepEqual(calls.at(-1),['seek',28,true]);
window.fretFlowPlayer.setRate(0.5);assert.equal(messages.at(-1).rate,1);
rate=0.5;options.events.onPlaybackRateChange();assert.equal(messages.at(-1).rate,0.5);
ticks[0]();assert.equal(messages.at(-1).position,28);assert.equal(messages.at(-1).loadID,config.loadID);
options.events.onAutoplayBlocked();assert.equal(messages.at(-1).kind,'blocked');
options.events.onError({data:153});assert.equal(messages.at(-1).code,153);
console.log('Offline YouTube player checks passed: cue, controls, identity, snapshots, pause/seek, actual rates, and error events.');
