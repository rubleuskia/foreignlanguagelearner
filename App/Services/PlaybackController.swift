import AVFoundation
import Observation
import UIKit

enum PlaybackRate: Float, CaseIterable, Identifiable, Sendable {
    case half = 0.5
    case threeQuarters = 0.75
    case normal = 1
    case oneAndHalf = 1.5
    case double = 2

    var id: Self { self }
    var title: String { "\(rawValue.formatted(.number.precision(.fractionLength(0...2))))×" }
}

protocol PlaybackAudioSession: Sendable {
    func activate() async throws
    func deactivate() async
}

/// Audio-session IPC can wait for the media server. Keep it off the UI executor
/// and serialize activation/deactivation for all players.
actor SystemPlaybackAudioSession: PlaybackAudioSession {
    static let shared = SystemPlaybackAudioSession()

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor @Observable final class PlaybackController {
    let player = AVPlayer()
    private(set) var position = 0.0
    private(set) var isPlaying = false
    private(set) var wantsToPlay = false
    private(set) var selectedRate: PlaybackRate = .normal
    var errorMessage: String?
    var didReachEnd: (() -> Void)?

    private static let activeControllers = NSHashTable<PlaybackController>.weakObjects()
    private var statusObserver: NSKeyValueObservation?

    private let audioSession: any PlaybackAudioSession
    private var activationTask: Task<Void, Never>?
    private var activationGeneration = 0
    private var sessionReady = false

    init(audioSession: any PlaybackAudioSession = SystemPlaybackAudioSession.shared) {
        self.audioSession = audioSession
        Self.activeControllers.add(self)
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { _, _ in
            Task { @MainActor in Self.updateScreenAwake() }
        }
    }

    deinit {
        Task { @MainActor in Self.updateScreenAwake() }
    }

    private static func updateScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = activeControllers.allObjects.contains {
            $0.wantsToPlay && $0.player.timeControlStatus == .playing
        }
    }

    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var playbackRange: ClosedRange<Double>?
    private var seekGeneration = 0
    private var observationGeneration = 0
    private var seekInProgress = false
    private var reachedEnd = false

    func open(url: URL, position: Double, range: ClosedRange<Double>? = nil,
              completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        close(keepAudioSession: true)
        errorMessage = nil
        playbackRange = Self.validRange(range)
        let item = AVPlayerItem(url: url)
        if let playbackRange {
            item.forwardPlaybackEndTime = CMTime(seconds: playbackRange.upperBound, preferredTimescale: 600)
        }
        player.replaceCurrentItem(with: item)
        self.position = clamped(position)
        reachedEnd = false
        observationGeneration += 1
        let generation = observationGeneration
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            // Leave AVFoundation's callback before touching player state or replacing items.
            Task { @MainActor in
                guard let self, self.observationGeneration == generation,
                      self.player.currentItem === item,
                      !self.seekInProgress else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.position = self.clamped(seconds)
                if let error = self.player.currentItem?.error {
                    self.errorMessage = error.localizedDescription
                }
                if let end = self.playbackRange?.upperBound,
                   self.wantsToPlay, self.position >= end - 0.03 {
                    self.finishPlayback(item: item, generation: generation)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let item else { return }
                self?.finishPlayback(item: item, generation: generation)
            }
        }
        seek(to: self.position, completion: completion)
    }

    func setRate(_ rate: PlaybackRate) {
        selectedRate = rate
        if wantsToPlay, sessionReady, !seekInProgress {
            player.playImmediately(atRate: rate.rawValue)
        }
    }

    func play() {
        guard player.currentItem != nil else { return }
        guard activationTask == nil else { return }
        sessionReady = false
        wantsToPlay = true
        isPlaying = true
        errorMessage = nil
        activationGeneration += 1
        let generation = activationGeneration
        activationTask = Task { [weak self, audioSession] in
            do {
                try Task.checkCancellation()
                try await audioSession.activate()
                guard let self, !Task.isCancelled,
                      self.activationGeneration == generation, self.wantsToPlay else { return }
                self.activationTask = nil
                self.sessionReady = true
                if self.reachedEnd || self.isAtEnd {
                    self.reachedEnd = false
                    self.seek(to: self.playbackRange?.lowerBound ?? 0)
                } else if !self.seekInProgress {
                    self.player.playImmediately(atRate: self.selectedRate.rawValue)
                }
            } catch {
                guard let self, !Task.isCancelled,
                      self.activationGeneration == generation else { return }
                self.activationTask = nil
                self.wantsToPlay = false
                self.isPlaying = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func pause() {
        activationGeneration += 1
        activationTask?.cancel()
        activationTask = nil
        sessionReady = false
        wantsToPlay = false
        isPlaying = false
        player.pause()
        Self.updateScreenAwake()
    }

    func toggle() {
        wantsToPlay ? pause() : play()
    }

    func seek(to seconds: Double,
              completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard player.currentItem != nil, seconds.isFinite else {
            completion?(false)
            return
        }
        position = clamped(seconds)
        reachedEnd = false
        seekGeneration += 1
        let generation = seekGeneration
        seekInProgress = true
        player.seek(
            to: CMTime(seconds: position, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else {
                    completion?(false)
                    return
                }
                self.seekInProgress = false
                let actual = self.player.currentTime().seconds
                if actual.isFinite { self.position = self.clamped(actual) }
                if self.wantsToPlay, self.sessionReady {
                    self.player.playImmediately(atRate: self.selectedRate.rawValue)
                }
                completion?(finished)
            }
        }
    }

    func close(keepAudioSession: Bool = false) {
        let hadAudio = player.currentItem != nil || activationTask != nil
        activationGeneration += 1
        activationTask?.cancel()
        activationTask = nil
        sessionReady = false
        seekGeneration += 1
        observationGeneration += 1
        seekInProgress = false
        reachedEnd = false
        wantsToPlay = false
        isPlaying = false
        player.pause()
        Self.updateScreenAwake()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        playbackRange = nil
        position = 0
        didReachEnd = nil
        if !keepAudioSession, hadAudio {
            Task { [audioSession] in await audioSession.deactivate() }
        }
    }

    private var isAtEnd: Bool {
        let end = playbackRange?.upperBound ?? player.currentItem?.duration.seconds ?? .infinity
        return end.isFinite && position >= end - 0.03
    }

    private func finishPlayback(item: AVPlayerItem, generation: Int) {
        guard observationGeneration == generation, player.currentItem === item else { return }
        player.pause()
        Self.updateScreenAwake()
        wantsToPlay = false
        isPlaying = false
        reachedEnd = true
        if let end = playbackRange?.upperBound { position = end }
        didReachEnd?()
    }

    private func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return playbackRange?.lowerBound ?? 0 }
        guard let playbackRange else { return max(0, seconds) }
        return min(max(playbackRange.lowerBound, seconds), playbackRange.upperBound)
    }

    private static func validRange(_ range: ClosedRange<Double>?) -> ClosedRange<Double>? {
        guard let range, range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound >= 0, range.upperBound > range.lowerBound else { return nil }
        return range
    }
}
