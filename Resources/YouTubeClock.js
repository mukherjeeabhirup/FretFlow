// Read-only media clock, injected into FretFlow's current YouTube embed only.
// No media sources, audio routing, network requests or player controls change.
(function () {
    'use strict';
    const config = __FRETFLOW_CLOCK_CONFIG__;
    const hosts = ['youtube.com', 'www.youtube.com', 'youtube-nocookie.com', 'www.youtube-nocookie.com'];
    function isCurrentEmbed() {
        return window.top !== window && location.protocol === 'https:'
            && !location.username && !location.password
            && hosts.includes(location.hostname.toLowerCase())
            && (!location.port || location.port === '443')
            && location.pathname === '/embed/' + config.videoID;
    }
    if (!isCurrentEmbed()) return;
    // A reload of the same URL must not reuse the previous document's sequence.
    // timeOrigin orders documents; the nonce distinguishes their message streams.
    const documentID = window.crypto.randomUUID();
    const documentStartedAt = performance.timeOrigin;
    let sequence = 0;
    let stopped = false;
    let observedVideo = null;
    let waitingPosition = null;
    function post(values) {
        if (stopped || !isCurrentEmbed()) return;
        const handler = window.webkit?.messageHandlers?.youtubeClock;
        if (!handler) return;
        handler.postMessage(Object.assign({loadID: config.loadID, videoID: config.videoID,
            documentID, documentStartedAt,
            sequence: ++sequence, generatedAt: Date.now()}, values));
    }
    function readClock(event) {
        if (stopped || !isCurrentEmbed()) return;
        // These are conservative, best-effort ad indicators. An unrecognized
        // advertisement cannot be ruled out solely by its DOM class names.
        if (document.querySelector('.ad-showing, .ad-interrupting')) {
            waitingPosition = null;
            post({kind: 'advertisement'});
            return;
        }
        const main = Array.from(document.querySelectorAll('video.html5-main-video'));
        const videos = main.length ? main : Array.from(document.querySelectorAll('video'));
        if (videos.length !== 1) { waitingPosition = null; post({kind: 'unavailable'}); return; }
        const video = videos[0];
        if (video !== observedVideo) { observedVideo = video; waitingPosition = null; }
        const position = video.currentTime, duration = video.duration, rate = video.playbackRate;
        if (!Number.isFinite(position) || !Number.isFinite(duration) || duration <= 0
            || !Number.isFinite(rate) || rate <= 0) {
            post({kind: 'unavailable'});
            return;
        }
        // waiting/stalled can precede a readyState change. Keep them gated
        // until playing or actual forward movement, including native polls
        // when the page's timers and playing event have been throttled.
        if (event?.type === 'waiting' || event?.type === 'stalled') waitingPosition = position;
        else if (['playing', 'seeking', 'seeked'].includes(event?.type) || video.paused || video.ended
            || (waitingPosition !== null && position > waitingPosition + 0.002)) waitingPosition = null;
        post({kind: 'sample', position, duration, rate, buffering: waitingPosition !== null,
            paused: video.paused, ended: video.ended, seeking: video.seeking,
            readyState: video.readyState});
    }
    // This symbol exists only in FretFlowClock's isolated JavaScript world.
    // Native polling covers WebKit's throttled timers without changing page
    // visibility, video controls, media sources or audio routing.
    Object.defineProperty(window, '__fretFlowReadClock', {configurable: true, value(expected) {
        if (stopped || !isCurrentEmbed() || expected?.loadID !== config.loadID
            || expected?.videoID !== config.videoID || expected?.documentID !== documentID) return false;
        readClock();
        return true;
    }});
    // Capture-phase listeners cover a replacement video element without
    // installing hooks on YouTube objects or altering the element itself.
    for (const name of ['play', 'playing', 'pause', 'ended', 'seeking', 'seeked', 'waiting', 'stalled', 'ratechange', 'loadedmetadata', 'timeupdate']) {
        document.addEventListener(name, readClock, true);
    }
    const ticker = window.setInterval(readClock, 50);
    document.addEventListener('visibilitychange', readClock, true);
    window.addEventListener('pagehide', () => { stopped = true; window.clearInterval(ticker); }, {once: true});
    readClock();
})();
