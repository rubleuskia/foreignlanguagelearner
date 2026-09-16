import AVFoundation
import Observation

@MainActor @Observable final class PlaybackController {
    let player = AVPlayer()
    var position = 0.0
    var isPlaying = false
    var errorMessage: String?
    private var observer: Any?
    private var playbackRange: ClosedRange<Double>?
    private var seekGeneration = 0
    private var seekInProgress = false

    func open(url: URL, position: Double, range: ClosedRange<Double>? = nil) {
        close()
        errorMessage = nil
        playbackRange = range
        let item = AVPlayerItem(url: url)
        if let range { item.forwardPlaybackEndTime = CMTime(seconds: range.upperBound, preferredTimescale: 600) }
        player.replaceCurrentItem(with: item)
        seek(to: position)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.seekInProgress else { return }
                self.position = self.clamped(time.seconds.isFinite ? time.seconds : 0)
                self.isPlaying = self.player.rate != 0
                if let error = self.player.currentItem?.error { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func toggle() {
        if player.rate != 0 { player.pause(); isPlaying = false }
        else {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                let end = playbackRange?.upperBound ?? player.currentItem?.duration.seconds ?? 0
                if end.isFinite, position >= end - 0.2 { seek(to: playbackRange?.lowerBound ?? 0) }
                player.play()
                isPlaying = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func seek(to seconds: Double) {
        position = clamped(seconds)
        seekGeneration += 1
        let generation = seekGeneration
        seekInProgress = true
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.seekGeneration == generation else { return }
                self.seekInProgress = false
                let actual = self.player.currentTime().seconds
                if actual.isFinite { self.position = self.clamped(actual) }
            }
        }
    }

    func close() {
        seekGeneration += 1
        seekInProgress = false
        player.pause()
        isPlaying = false
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
        playbackRange = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func clamped(_ seconds: Double) -> Double {
        guard let playbackRange else { return max(0, seconds) }
        return min(max(playbackRange.lowerBound, seconds), playbackRange.upperBound)
    }
}
