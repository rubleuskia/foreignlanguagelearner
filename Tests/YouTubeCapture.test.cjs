const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const script = fs.readFileSync('Shared/YouTubeCapture.js', 'utf8');
const validURL = 'https://m.youtube.com/api/timedtext?v=jNQXAC9IVRw&lang=en&pot=test&fmt=json3';

function page({ html = false, missing = false, entries = [] } = {}) {
    const response = { videoDetails: { videoId: 'jNQXAC9IVRw', title: 'Sample', lengthSeconds: '19' },
        captions: missing ? undefined : { playerCaptionsTracklistRenderer: { captionTracks: [
            { languageCode: 'en', baseUrl: '/api/timedtext?v=jNQXAC9IVRw&lang=en' }
        ] } } };
    let observe, requested;
    const context = vm.createContext({ URL, AbortSignal, crypto: { randomUUID: () => '00000000-0000-4000-8000-000000000001' },
        location: { hostname: 'm.youtube.com', href: 'https://m.youtube.com/watch?v=jNQXAC9IVRw' },
        document: { getElementById: () => null, scripts: html ? [{ textContent: 'var ytInitialPlayerResponse = ' + JSON.stringify(response) + ';' }] : [] },
        performance: { setResourceTimingBufferSize() {}, getEntriesByType: () => entries },
        PerformanceObserver: class { constructor(callback) { observe = callback; } observe() {} },
        fetch: async url => {
            requested = url;
            return { ok: true, text: async () => url.includes('pot=test') ? JSON.stringify({ events: [
                { tStartMs: 1200, dDurationMs: 2160, segs: [{ utf8: ' First\ncue ' }] }
            ] }) : '' };
        }
    });
    context.window = context;
    if (!html) context.ytInitialPlayerResponse = response;
    vm.runInContext(script, context);
    return { context, observe, requested: () => requested, capture: () => vm.runInContext('captureYouTube()', context) };
}

test('preserves cue times and does not export signed request parameters', async () => {
    const p = page({ entries: [{ name: validURL, decodedBodySize: 100 }] });
    const result = await p.capture();
    assert.equal(result.videoID, 'jNQXAC9IVRw');
    assert.equal(result.cues[0].start, 1.2);
    assert.equal(result.cues[0].end, 3.36);
    assert.equal(result.cues[0].text, 'First cue');
    assert.ok(!JSON.stringify(result).includes('pot='));
});

test('document-start observer retains working request when later empty requests arrive', async () => {
    const p = page();
    p.observe({ getEntries: () => [{ name: validURL, decodedBodySize: 100 }] });
    p.observe({ getEntries: () => [{ name: validURL.replace('&pot=test', ''), decodedBodySize: 0 }] });
    const result = await p.capture();
    assert.equal(result.cues.length, 1);
    assert.ok(p.requested().includes('pot=test'));
});

test('Safari isolated context can read serialized metadata from HTML', async () => {
    const p = page({ html: true, entries: [{ name: validURL, decodedBodySize: 100 }] });
    assert.equal((await p.capture()).cues.length, 1);
});

test('missing and inaccessible captions return recoverable errors', async () => {
    assert.match((await page({ missing: true }).capture()).error, /no available subtitles/);
    assert.match((await page().capture()).error, /enable subtitles/);
});
