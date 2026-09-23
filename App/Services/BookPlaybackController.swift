import Foundation
import Observation

@MainActor @Observable final class BookPlaybackController {
    let playback = PlaybackController()
    private(set) var activeTrackID: String?
    private(set) var localPosition = 0.0
    private(set) var globalPosition = 0.0
    private(set) var errorMessage: String?
    private(set) var timeline: BookTimeline?
    var wantsToPlay = false

    private var tracks: [LearningTrack] = []
    private var itemID: UUID?
    private var generation = 0
    private var positionTask: Task<Void, Never>?

    var isPlaying: Bool { playback.isPlaying }
    var totalDuration: Double { timeline?.total ?? 0 }
    var activeTrack: LearningTrack? { tracks.first { $0.id == activeTrackID } }

    func open(item: LearningItem) {
        close()
        itemID = item.id
        tracks = item.tracks
        do {
            timeline = try BookTimeline(tracks: tracks.map { ($0.id, $0.duration) })
            let track = tracks.first(where: { $0.id == item.lastTrackID }) ?? tracks.first
            guard let track else { throw BookTimeline.TimelineError.noTracks }
            openTrack(track.id, position: track.lastPosition, shouldPlay: false)
            observePosition()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggle() {
        guard let timeline else { return }
        if wantsToPlay {
            pause()
            return
        }
        wantsToPlay = true
        if globalPosition >= timeline.total - 0.001, let first = tracks.first {
            openTrack(first.id, position: 0, shouldPlay: true)
        } else {
            playback.play()
        }
    }

    func pause() {
        wantsToPlay = false
        playback.pause()
    }

    func seek(global seconds: Double) {
        guard let timeline, let location = try? timeline.location(at: seconds) else { return }
        openTrack(location.trackID, position: location.localTime, shouldPlay: wantsToPlay)
    }

    func seekLocal(_ seconds: Double) {
        let currentGeneration = generation
        playback.seek(to: seconds) { [weak self] valid in
            guard let self, valid, self.generation == currentGeneration else { return }
            self.refreshPosition()
            if self.wantsToPlay { self.playback.play() }
        }
    }

    func selectTrack(_ id: String) {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        openTrack(id, position: track.lastPosition, shouldPlay: wantsToPlay)
    }

    func snapshot(into item: LearningItem) {
        for saved in tracks {
            if let index = item.tracks.firstIndex(where: { $0.id == saved.id }) {
                item.tracks[index].lastPosition = min(max(0, saved.lastPosition), item.tracks[index].duration)
            }
        }
        guard let id = activeTrackID, let index = item.tracks.firstIndex(where: { $0.id == id }) else { return }
        item.tracks[index].lastPosition = min(max(0, localPosition), item.tracks[index].duration)
        item.lastTrackID = id
        item.duration = item.tracks.reduce(0) { $0 + $1.duration }
        item.lastPosition = (try? timeline?.globalTime(trackID: id, localTime: localPosition)) ?? 0
    }

    func retry() {
        guard let id = activeTrackID else { return }
        openTrack(id, position: localPosition, shouldPlay: wantsToPlay)
    }

    func dismissError() { errorMessage = nil; playback.errorMessage = nil }

    func close() {
        generation += 1
        positionTask?.cancel()
        positionTask = nil
        playback.close()
        activeTrackID = nil
        wantsToPlay = false
    }

    private func openTrack(_ id: String, position: Double, shouldPlay: Bool) {
        guard let itemID, let track = tracks.first(where: { $0.id == id }) else { return }
        generation += 1
        let currentGeneration = generation
        if let previous = activeTrackID, let index = tracks.firstIndex(where: { $0.id == previous }) {
            tracks[index].lastPosition = localPosition
        }
        activeTrackID = id
        localPosition = min(max(0, position), track.duration)
        errorMessage = nil
        let url = MediaImportService.directory(for: itemID).appending(path: track.mediaFilename)
        playback.open(url: url, position: localPosition) { [weak self] valid in
            guard let self, self.generation == currentGeneration, self.activeTrackID == id else { return }
            guard valid else {
                self.errorMessage = "Could not open \(track.title)."
                self.wantsToPlay = false
                return
            }
            if shouldPlay, self.wantsToPlay { self.playback.play() }
        }
        playback.didReachEnd = { [weak self] in
            self?.handleEnd(generation: currentGeneration, trackID: id)
        }
    }

    private func handleEnd(generation: Int, trackID: String) {
        guard generation == self.generation, activeTrackID == trackID,
              let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        localPosition = tracks[index].duration
        if index + 1 < tracks.count, wantsToPlay {
            openTrack(tracks[index + 1].id, position: 0, shouldPlay: true)
        } else {
            wantsToPlay = false
            refreshPosition()
        }
    }

    private func observePosition() {
        positionTask?.cancel()
        positionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.refreshPosition()
            }
        }
    }

    private func refreshPosition() {
        localPosition = playback.position
        guard let id = activeTrackID else { return }
        globalPosition = (try? timeline?.globalTime(trackID: id, localTime: localPosition)) ?? 0
        if let message = playback.errorMessage, let title = activeTrack?.title {
            errorMessage = "\(title): \(message)"
        }
    }
}
