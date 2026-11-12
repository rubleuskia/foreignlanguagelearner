/* Runs on demand in Safari preprocessing or in the in-app YouTube browser.
   Only the transcript is returned; signed URLs and browser state stay on the page. */
if (!window.__fllCaptionObserver) {
    performance.setResourceTimingBufferSize(5000);
    window.__fllCaptionRequests = [];
    window.__fllCaptionObserver = new PerformanceObserver(list => {
        for (const entry of list.getEntries()) {
            if (entry.name.includes('/api/timedtext') && entry.decodedBodySize > 0) {
                window.__fllCaptionRequests.push(entry.name);
                if (window.__fllCaptionRequests.length > 10) window.__fllCaptionRequests.shift();
            }
        }
    });
    window.__fllCaptionObserver.observe({ type: 'resource', buffered: true });
}
async function captureYouTube() {
    const fail = message => ({ error: message });
    if (!['youtube.com', 'www.youtube.com', 'm.youtube.com'].includes(location.hostname))
        return fail('Open the video on youtube.com in Safari.');
    try {
        let response = document.getElementById('movie_player')?.getPlayerResponse?.() || window.ytInitialPlayerResponse;
        if (!response) {
            for (const script of document.scripts) {
                const match = /(?:var\s+)?ytInitialPlayerResponse\s*=\s*/.exec(script.textContent);
                if (!match) continue;
                const tail = script.textContent.slice(match.index + match[0].length);
                let depth = 0, quoted = false, escaped = false;
                for (let i = 0; i < tail.length; i++) {
                    const c = tail[i];
                    if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; }
                    else if (c === '"') quoted = true;
                    else if (c === '{') depth++;
                    else if (c === '}' && --depth === 0) { response = JSON.parse(tail.slice(0, i + 1)); break; }
                }
                if (response) break;
            }
        }
        const tracks = response?.captions?.playerCaptionsTracklistRenderer?.captionTracks;
        const details = response?.videoDetails;
        if (!tracks?.length || !details || details.isLiveContent)
            return fail('This video has no available subtitles, or is a live video. Choose a recorded video with subtitles.');
        const requests = [...performance.getEntriesByType('resource').filter(e => e.decodedBodySize > 0).map(e => e.name), ...(window.__fllCaptionRequests || [])].filter(name => {
            const u = new URL(name, location.href);
            return ['youtube.com', 'www.youtube.com', 'm.youtube.com'].includes(u.hostname) &&
                u.pathname === '/api/timedtext' && u.searchParams.get('v') === details.videoId;
        });
        const latest = requests.at(-1);
        const activeURL = latest ? new URL(latest, location.href) : null;
        const track = tracks.find(t => t.languageCode === activeURL?.searchParams.get('lang')) || tracks[0];
        const url = activeURL || new URL(track.baseUrl, location.href);
        if (!['youtube.com', 'www.youtube.com', 'm.youtube.com'].includes(url.hostname) || url.protocol !== 'https:')
            return fail('The subtitle address is not supported.');
        url.searchParams.set('fmt', 'json3');
        const result = await fetch(url.href, { signal: AbortSignal.timeout(12000) });
        if (!result.ok) return fail('YouTube did not return subtitles. Enable subtitles and try again.');
        const text = await result.text();
        if (!text || text.length > 5000000) return fail('Play the video, enable subtitles in the desired language, then try again.');
        const json = JSON.parse(text);
        const cues = (json.events || []).filter(e => e.segs && e.dDurationMs > 0).map(e => ({
            start: e.tStartMs / 1000,
            end: (e.tStartMs + e.dDurationMs) / 1000,
            text: e.segs.map(s => s.utf8 || '').join('').replace(/\s+/g, ' ').trim()
        })).filter(e => e.text).sort((a,b) => a.start - b.start);
        if (!cues.length) return fail('No timed subtitles were found. Enable subtitles and try again.');
        return { id: crypto.randomUUID(), videoID: details.videoId, title: details.title, language: track.languageCode,
            duration: Number(details.lengthSeconds), cues };
    } catch (_) { return fail('Could not load subtitles. Play the video, enable subtitles, then try again.'); }
}

var ExtensionPreprocessingJS = {
    run: function(arguments) {
        captureYouTube().then(result => arguments.completionFunction({ capture: JSON.stringify(result) }));
    }
};
