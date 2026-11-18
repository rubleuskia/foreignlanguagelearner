import AVFoundation
import Combine
import Foundation

struct ExamAudioPlaybackPolicy: Sendable {
    let mode: ExamMode
    let duration: Double
    let windows: [String: ClosedRange<Double>]
    var allowsUserTransport: Bool { mode == .training }
    func clampedPosition(_ position: Double, taskID: String?) -> Double {
        let range = mode == .training ? taskID.flatMap { windows[$0] } ?? 0...max(0, duration) : 0...max(0, duration)
        return min(max(position.isFinite ? position : range.lowerBound, range.lowerBound), range.upperBound)
    }
}

/// Owns one player for one original recording. Task windows are playback limits, never extra copies.
@MainActor final class ExamAudioController: ObservableObject {
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var activeTaskID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var examStarted = false
    @Published private(set) var examFinished = false
    var onPosition: ((Double) -> Void)?
    var onInterruption: (() -> Void)?
    var onFinished: (() -> Void)?

    private let player = AVPlayer()
    private var policy: ExamAudioPlaybackPolicy?
    private var poll: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var wantsToResume = false
    private var systemInterrupted = false
    var allowsSeeking: Bool { policy?.allowsUserTransport == true }
    var allowsPausing: Bool { policy?.allowsUserTransport == true }

    init() { }

    func configure(url: URL, manifest: ExamAudioManifest, mode: ExamMode,
                   position savedPosition: Double, taskID: String?) async throws {
        close()
        let currentGeneration = generation
        guard url.isFileURL, manifest.timestampUnit == "milliseconds_relative_to_original_audio",
              manifest.source.durationMS > 0 else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
        let asset = AVURLAsset(url: url)
        let loadedDuration = try await asset.load(.duration).seconds
        guard currentGeneration == generation else { throw CancellationError() }
        let expected = Double(manifest.source.durationMS) / 1000
        guard loadedDuration.isFinite, loadedDuration > 0, abs(loadedDuration - expected) < 2 else {
            throw ExamAPIError(code: "INVALID_EXAM_MATERIAL")
        }
        var windows: [String: ClosedRange<Double>] = [:]
        for task in manifest.tasks {
            guard let window = task.window, window.lowerBound >= 0, window.upperBound <= expected + 0.05 else {
                throw ExamAPIError(code: "INVALID_EXAM_MATERIAL")
            }
            windows["listening-" + task.taskLabel] = window
        }
        policy = ExamAudioPlaybackPolicy(mode: mode, duration: expected, windows: windows)
        duration = expected
        activeTaskID = mode == .training ? taskID : nil
        position = policy?.clampedPosition(savedPosition, taskID: activeTaskID) ?? 0
        examStarted = mode == .exam
        examFinished = mode == .exam && position >= duration - 0.01
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        installObservers()
        let completed = await player.seek(to: CMTime(seconds: position, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        guard currentGeneration == generation, completed else { throw CancellationError() }
        observePosition()
        if mode == .exam, !examFinished { try resumeExam() }
    }

    func window(for taskID: String) -> ClosedRange<Double>? { policy?.windows[taskID] }

    /// Selecting a training slider prepares its window without briefly playing audio.
    func prepare(taskID: String) async throws {
        guard let policy, policy.mode == .training, let window = policy.windows[taskID] else { return }
        guard activeTaskID != taskID else { return }
        player.pause(); isPlaying = false; wantsToResume = false
        activeTaskID = taskID; position = window.lowerBound
        let currentGeneration = generation
        let completed = await player.seek(to: CMTime(seconds: position, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        guard completed, currentGeneration == generation else { throw CancellationError() }
        onPosition?(position)
    }

    func play(taskID: String) async throws {
        guard policy?.mode == .training else { return }
        try await prepare(taskID: taskID)
        if let window = policy?.windows[taskID], position >= window.upperBound - 0.01 {
            position = window.lowerBound
            _ = await player.seek(to: CMTime(seconds: position, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        try activate()
        wantsToResume = true; player.play(); isPlaying = true
    }

    func pause() {
        guard allowsPausing else { return }
        player.pause(); wantsToResume = false; isPlaying = false
        snapshot()
    }

    func seek(seconds: Double) {
        guard let policy, policy.allowsUserTransport else { return }
        position = policy.clampedPosition(seconds, taskID: activeTaskID)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        onPosition?(position)
    }

    /// Resumes the same exam recording; never rewinds or creates a new attempt.
    func resumeExam() throws {
        guard policy?.mode == .exam, !examFinished, !systemInterrupted else { return }
        try activate()
        examStarted = true; wantsToResume = true; player.play(); isPlaying = true
    }

    func suspendForSystem() {
        wantsToResume = isPlaying || policy?.mode == .exam
        player.pause(); isPlaying = false; systemInterrupted = true
        snapshot(); onInterruption?()
    }

    private func suspendForRouteChange() {
        suspendForSystem()
        // Removing headphones ends the route, not an ongoing AVAudioSession interruption.
        // Wait for the user's Continue gesture instead of resuming on the loudspeaker.
        systemInterrupted = false
        wantsToResume = false
    }

    func resumeAfterSystem() {
        systemInterrupted = false
        guard wantsToResume, !examFinished else { return }
        do { try activate(); player.play(); isPlaying = true }
        catch { errorMessage = error.localizedDescription }
    }

    func snapshot() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite, seconds >= 0 { position = min(seconds, duration) }
        onPosition?(position)
    }

    func close() {
        generation += 1
        poll?.cancel(); poll = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        player.pause(); player.replaceCurrentItem(with: nil)
        policy = nil; wantsToResume = false; systemInterrupted = false
        position = 0; duration = 0; isPlaying = false; activeTaskID = nil
        errorMessage = nil; examStarted = false; examFinished = false
    }

    private func activate() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        errorMessage = nil
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue { self.suspendForSystem() }
                else if options & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0 { self.resumeAfterSystem() }
                else { self.systemInterrupted = false }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in self?.suspendForRouteChange() }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish() }
        })
    }

    private func finish() {
        player.pause(); wantsToResume = false; isPlaying = false
        if policy?.mode == .exam { position = duration; examFinished = true }
        onPosition?(position); onFinished?()
    }

    private func observePosition() {
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.policy != nil else { return }
                if let error = self.player.currentItem?.error {
                    if self.errorMessage == nil {
                        self.errorMessage = error.localizedDescription; self.isPlaying = false; self.onInterruption?()
                    }
                    continue
                }
                self.snapshot()
                if let policy = self.policy, policy.mode == .training,
                   let id = self.activeTaskID, let end = policy.windows[id]?.upperBound, self.position >= end {
                    self.player.pause(); self.isPlaying = false; self.wantsToResume = false
                    self.position = end; self.onPosition?(end)
                } else { self.isPlaying = self.player.rate > 0 }
            }
        }
    }
}
