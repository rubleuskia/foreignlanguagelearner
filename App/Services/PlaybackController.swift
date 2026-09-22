import AVFoundation
import Observation

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

    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var playbackRange: ClosedRange<Double>?
    private var seekGeneration = 0
    private var observationGeneration = 0
    private var seekInProgress = false
    private var reachedEnd = false

    func open(url: URL, position: Double, range: ClosedRange<Double>? = nil) {
        close()
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
            MainActor.assumeIsolated {
                guard let self, self.observationGeneration == generation,
                      !self.seekInProgress else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.position = self.clamped(seconds)
                if let error = self.player.currentItem?.error {
                    self.errorMessage = error.localizedDescription
                }
                if let end = self.playbackRange?.upperBound,
                   self.wantsToPlay, self.position >= end - 0.03 {
                    self.finishPlayback()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishPlayback() }
        }
        seek(to: self.position)
    }

    func setRate(_ rate: PlaybackRate) {
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
            wantsToPlay = true
            isPlaying = true
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
        wantsToPlay = false
        isPlaying = false
        player.pause()
    }

    func toggle() {
        wantsToPlay ? pause() : play()
    }

    func seek(to seconds: Double) {
        guard player.currentItem != nil, seconds.isFinite else { return }
        position = clamped(seconds)
        reachedEnd = false
        seekGeneration += 1
        let generation = seekGeneration
        seekInProgress = true
        player.seek(
            to: CMTime(seconds: position, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.seekGeneration == generation else { return }
                self.seekInProgress = false
                let actual = self.player.currentTime().seconds
                if actual.isFinite { self.position = self.clamped(actual) }
                if self.wantsToPlay {
                    self.player.playImmediately(atRate: self.selectedRate.rawValue)
                }
            }
        }
    }

    func close() {
        seekGeneration += 1
        observationGeneration += 1
        seekInProgress = false
        reachedEnd = false
        wantsToPlay = false
        isPlaying = false
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        playbackRange = nil
        position = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private var isAtEnd: Bool {
        let end = playbackRange?.upperBound ?? player.currentItem?.duration.seconds ?? .infinity
        return end.isFinite && position >= end - 0.03
    }

    private func finishPlayback() {
        player.pause()
        wantsToPlay = false
        isPlaying = false
        reachedEnd = true
        if let end = playbackRange?.upperBound { position = end }
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
