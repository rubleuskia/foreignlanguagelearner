import AVFoundation
import XCTest
@testable import ForeignLanguageLearner

private actor SuspendedAudioSession: PlaybackAudioSession {
    private var pending: [CheckedContinuation<Void, Error>] = []
    private(set) var activations = 0
    private(set) var deactivations = 0

    func activate() async throws {
        activations += 1
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func deactivate() { deactivations += 1 }

    func complete(failing: Bool = false) {
        let callbacks = pending
        pending = []
        for callback in callbacks {
            if failing { callback.resume(throwing: URLError(.cannotConnectToHost)) }
            else { callback.resume() }
        }
    }
}

@MainActor
final class PlaybackControllerTests: XCTestCase {
    private func waitForActivation(_ session: SuspendedAudioSession, count: Int = 1) async throws {
        for _ in 0..<100 {
            if await session.activations >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Audio activation did not start")
    }

    private func open(_ playback: PlaybackController) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        playback.open(url: url, position: 1, range: 1...3)
    }

    func testPauseWhileActivationWaitsKeepsUILiveAndRejectsLateStart() async throws {
        let session = SuspendedAudioSession()
        let playback = PlaybackController(audioSession: session)
        try open(playback)
        playback.play()
        try await waitForActivation(session)
        XCTAssertTrue(playback.wantsToPlay)
        // These UI-executor operations must remain possible while the audio server waits.
        playback.setRate(.double)
        playback.pause()
        await session.complete()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(playback.wantsToPlay)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.player.rate, 0)
        XCTAssertNil(playback.errorMessage)
        playback.close()
    }

    func testCloseAndReopenRejectsOldActivationFailure() async throws {
        let session = SuspendedAudioSession()
        let playback = PlaybackController(audioSession: session)
        try open(playback)
        playback.play()
        try await waitForActivation(session)
        playback.close()
        try open(playback)
        await session.complete(failing: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(playback.wantsToPlay)
        XCTAssertEqual(playback.player.rate, 0)
        XCTAssertNil(playback.errorMessage)
        playback.close()
    }

    func testSeekAndRateWaitForActivationThenStartAtLatestRate() async throws {
        let session = SuspendedAudioSession()
        let playback = PlaybackController(audioSession: session)
        try open(playback)
        let seekFinished = await withCheckedContinuation { continuation in
            playback.seek(to: 1.5) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(seekFinished)
        playback.play()
        try await waitForActivation(session)
        playback.setRate(.double)
        XCTAssertEqual(playback.player.rate, 0, "Rate changes must not bypass pending activation")
        await session.complete()
        for _ in 0..<100 {
            if playback.player.rate == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(playback.player.rate, 2)
        playback.player.pause() // Simulate a system interruption without clearing play intent.
        playback.play()
        try await waitForActivation(session, count: 2)
        playback.setRate(.half)
        XCTAssertEqual(playback.player.rate, 0)
        await session.complete()
        for _ in 0..<100 {
            if playback.player.rate == 0.5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(playback.player.rate, 0.5)
        playback.close()
    }

    func testActivationFailureStopsPlayIntentAndCanRetry() async throws {
        let session = SuspendedAudioSession()
        let playback = PlaybackController(audioSession: session)
        try open(playback)
        playback.play()
        try await waitForActivation(session)
        await session.complete(failing: true)
        for _ in 0..<100 {
            if playback.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(playback.errorMessage)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertFalse(playback.wantsToPlay)
        playback.play()
        try await waitForActivation(session, count: 2)
        XCTAssertNil(playback.errorMessage)
        playback.close()
        await session.complete()
    }
}
