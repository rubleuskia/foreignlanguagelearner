import AVFoundation
import Observation

@MainActor @Observable final class PlaybackController {
    let player = AVPlayer()
    var position = 0.0
    var isPlaying = false
    var errorMessage: String?
    private var observer: Any?

    func open(url: URL, position: Double) {
        close()
        errorMessage = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        seek(to: position)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
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
                if let duration = player.currentItem?.duration.seconds, duration.isFinite, position >= duration - 0.2 { seek(to: 0) }
                player.play()
                isPlaying = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func seek(to seconds: Double) {
        position = max(0, seconds)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func close() {
        player.pause()
        isPlaying = false
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
