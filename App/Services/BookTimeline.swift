import Foundation

struct BookTimeline: Equatable, Sendable {
    struct Location: Equatable, Sendable {
        let index: Int
        let trackID: String
        let localTime: Double
    }

    enum TimelineError: LocalizedError, Equatable {
        case noTracks
        case invalidDuration(trackID: String)
        case invalidTotal
        case invalidTime

        var errorDescription: String? {
            switch self {
            case .noTracks: "A book must contain at least one track."
            case .invalidDuration(let id): "Track \(id) has an invalid duration."
            case .invalidTotal: "The combined book duration is invalid."
            case .invalidTime: "Playback time must be finite."
            }
        }
    }

    let trackIDs: [String]
    let durations: [Double]
    let offsets: [Double]
    let total: Double

    init(tracks: [(id: String, duration: Double)]) throws {
        guard !tracks.isEmpty else { throw TimelineError.noTracks }
        var offsets: [Double] = []
        var total = 0.0
        for track in tracks {
            guard track.duration.isFinite, track.duration > 0 else {
                throw TimelineError.invalidDuration(trackID: track.id)
            }
            offsets.append(total)
            total += track.duration
            guard total.isFinite else { throw TimelineError.invalidTotal }
        }
        self.trackIDs = tracks.map(\.id)
        self.durations = tracks.map(\.duration)
        self.offsets = offsets
        self.total = total
    }

    func location(at seconds: Double) throws -> Location {
        guard seconds.isFinite else { throw TimelineError.invalidTime }
        let clamped = min(max(0, seconds), total)
        if clamped == total {
            let index = trackIDs.count - 1
            return .init(index: index, trackID: trackIDs[index], localTime: durations[index])
        }
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = (low + high) / 2
            if offsets[middle] <= clamped { low = middle + 1 } else { high = middle }
        }
        let index = max(0, low - 1)
        return .init(index: index, trackID: trackIDs[index], localTime: clamped - offsets[index])
    }

    func globalTime(trackID: String, localTime: Double) throws -> Double {
        guard localTime.isFinite else { throw TimelineError.invalidTime }
        guard let index = trackIDs.firstIndex(of: trackID) else {
            throw TimelineError.invalidDuration(trackID: trackID)
        }
        return offsets[index] + min(max(0, localTime), durations[index])
    }
}
