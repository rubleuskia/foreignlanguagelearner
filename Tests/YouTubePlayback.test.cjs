const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

function playerPage() {
    const source = fs.readFileSync('App/Services/YouTubePlayback.swift', 'utf8');
    const match = source.match(/<body><div id="player"><\/div><script>([\s\S]*?)<\/script>/);
    assert.ok(match, 'The player page should contain its inline script');
    const script = match[1].replaceAll('\\(videoID)', 'lmaZWix9h6M')
        .replaceAll('\\(Int(initial))', '45').replaceAll('\\(initial)', '45.75');
    const messages = [];
    let options, poll, seek, played = false;
    const player = {
        state: -1, time: 0, duration: 0,
        seekTo(time) { seek = time; },
        playVideo() { played = true; },
        getCurrentTime() { return this.time; },
        getPlayerState() { return this.state; },
        getDuration() { return this.duration; }
    };
    const context = vm.createContext({
        YT: { Player: function (_, value) { options = value; return player; } },
        webkit: { messageHandlers: { youtube: { postMessage: value => messages.push(value) } } },
        setInterval: callback => { poll = callback; }
    });
    vm.runInContext(script, context);
    context.onYouTubeIframeAPIReady();
    return { player, messages, poll: () => poll(), options: () => options,
        ready() { options.events.onReady({ target: player }); }, seek: () => seek, played: () => played };
}

test('autoplay resumes at the saved fractional position when the player becomes ready', () => {
    const page = playerPage();
    assert.equal(page.options().playerVars.autoplay, 1);
    assert.equal(page.options().playerVars.start, 45);
    page.ready();
    assert.equal(page.seek(), 45.75);
    assert.equal(page.played(), true);
});

test('unloaded and buffering states cannot overwrite the saved position with zero', () => {
    const page = playerPage();
    for (const state of [-1, 3, 5]) {
        page.player.state = state;
        page.player.duration = 100;
        page.poll();
        assert.equal(page.messages.at(-1).time, undefined);
    }
    page.player.state = 1;
    page.player.time = 46;
    page.poll();
    assert.equal(page.messages.at(-1).time, 46);
    assert.equal(page.messages.at(-1).playing, true);
    page.player.state = 2;
    page.player.time = 60;
    page.poll();
    assert.equal(page.messages.at(-1).time, 60);
    assert.equal(page.messages.at(-1).playing, false);
});

test('blocked autoplay is reported so the native reader can prompt for Play', () => {
    const page = playerPage();
    page.options().events.onAutoplayBlocked();
    assert.equal(page.messages.at(-1).autoplayBlocked, true);
});
