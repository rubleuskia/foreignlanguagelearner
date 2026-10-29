import AVFoundation
import Observation
import MediaPlayer
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

@MainActor @Observable final class PlaybackController {
    let player = AVPlayer()
    private(set) var position = 0.0
    private(set) var isPlaying = false
    private(set) var wantsToPlay = false
    private(set) var selectedRate: PlaybackRate = .normal
    var errorMessage: String?
    var didReachEnd: (() -> Void)?

    var mediaTitle = "Language Learner"
    var mediaSubtitle = ""
    var remotePlay: (() -> Void)?
    var remotePause: (() -> Void)?
    var remoteSeek: ((Double) -> Void)?
    private static weak var nowPlayingController: PlaybackController?
    private static var remoteCommandsInstalled = false
    private static var audioSessionObservers: [NSObjectProtocol] = []

    private static let activeControllers = NSHashTable<PlaybackController>.weakObjects()
    private var statusObserver: NSKeyValueObservation?
    private var lastPublishedSecond: Double?

    init() {
        Self.activeControllers.add(self)
        Self.installRemoteCommands()
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                Self.updateScreenAwake()
                self?.updateNowPlaying()
            }
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
        mediaTitle = url.deletingPathExtension().lastPathComponent
        mediaSubtitle = ""
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
            MainActor.assumeIsolated {
                guard let self, self.observationGeneration == generation,
                      self.player.currentItem === item,
                      !self.seekInProgress else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.position = self.clamped(seconds)
                self.updateNowPlaying(force: false)
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
            MainActor.assumeIsolated {
                guard let item else { return }
                self?.finishPlayback(item: item, generation: generation)
            }
        }
        seek(to: self.position, completion: completion)
    }

    func setRate(_ rate: PlaybackRate) {
        defer { updateNowPlaying() }
        selectedRate = rate
        if wantsToPlay, !seekInProgress {
            player.playImmediately(atRate: rate.rawValue)
        }
    }

    func play() {
        guard player.currentItem != nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            if let previous = Self.nowPlayingController, previous !== self {
                if let pause = previous.remotePause { pause() } else { previous.pause() }
            }
            Self.nowPlayingController = self
            wantsToPlay = true
            isPlaying = true
            updateNowPlaying()
            if reachedEnd || isAtEnd {
                reachedEnd = false
                seek(to: playbackRange?.lowerBound ?? 0)
            } else if !seekInProgress {
                player.playImmediately(atRate: selectedRate.rawValue)
            }
        } catch {
            wantsToPlay = false
            isPlaying = false
            errorMessage = error.localizedDescription
        }
    }

    func pause() {
        defer { updateNowPlaying() }
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
            MainActor.assumeIsolated {
                guard let self, self.seekGeneration == generation else {
                    completion?(false)
                    return
                }
                self.seekInProgress = false
                let actual = self.player.currentTime().seconds
                if actual.isFinite { self.position = self.clamped(actual) }
                if self.wantsToPlay {
                    self.player.playImmediately(atRate: self.selectedRate.rawValue)
                }
                self.updateNowPlaying()
                completion?(finished)
            }
        }
    }

    func close(keepAudioSession: Bool = false) {
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
        lastPublishedSecond = nil
        didReachEnd = nil
        if Self.nowPlayingController === self {
            Self.nowPlayingController = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        if !keepAudioSession, Self.nowPlayingController == nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// System media surfaces (Lock Screen, Control Center and Dynamic Island) share this session.
    private func updateNowPlaying(force: Bool = true) {
        guard Self.nowPlayingController === self, player.currentItem != nil else { return }
        let second = floor(position)
        guard force || lastPublishedSecond != second else { return }
        lastPublishedSecond = second
        let start = playbackRange?.lowerBound ?? 0
        let end = playbackRange?.upperBound ?? player.currentItem?.duration.seconds ?? 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: mediaTitle,
            MPMediaItemPropertyArtist: mediaSubtitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, position - start),
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? Double(selectedRate.rawValue) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(selectedRate.rawValue)
        ]
        if end.isFinite { info[MPMediaItemPropertyPlaybackDuration] = max(0, end - start) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    enum RemoteAction: Sendable {
        case play, pause, toggle, seek(Double), skip(Double)
    }

    static func performRemote(_ action: RemoteAction) {
        guard let owner = nowPlayingController else { return }
        switch action {
        case .play:
            if let play = owner.remotePlay { play() } else { owner.play() }
        case .pause:
            if let pause = owner.remotePause { pause() } else { owner.pause() }
        case .toggle:
            performRemote(owner.wantsToPlay ? .pause : .play)
        case .seek(let relative):
            let position = relative + (owner.playbackRange?.lowerBound ?? 0)
            if let seek = owner.remoteSeek { seek(position) } else { owner.seek(to: position) }
        case .skip(let interval):
            let position = owner.clamped(owner.position + interval)
            if let seek = owner.remoteSeek { seek(position) } else { owner.seek(to: position) }
        }
    }

    private static func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        audioSessionObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in performRemote(.pause) }
        })
        audioSessionObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in performRemote(.pause) }
        })
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [(center.playCommand, RemoteAction.play),
                                  (center.pauseCommand, .pause),
                                  (center.togglePlayPauseCommand, .toggle)] {
            command.isEnabled = true
            command.addTarget { _ in
                Task { @MainActor in performRemote(action) }
                return .success
            }
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in performRemote(.seek(seconds)) }
            return .success
        }
        for (command, interval) in [(center.skipBackwardCommand, -10.0), (center.skipForwardCommand, 10.0)] {
            command.isEnabled = true
            command.preferredIntervals = [10]
            command.addTarget { _ in
                Task { @MainActor in performRemote(.skip(interval)) }
                return .success
            }
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
        updateNowPlaying()
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
