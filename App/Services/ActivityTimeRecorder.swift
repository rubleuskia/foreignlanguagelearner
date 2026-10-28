import Foundation
import SwiftData
import SwiftUI

/// Wall time, never media position: seeking and playback speed cannot inflate activity.
@MainActor final class ActivityTimeRecorder {
    private var lastUptime: TimeInterval?
    private var lastDate: Date?
    private var wasEligible = false
    private var pending: [Date: Double] = [:]
    private var elapsedSinceSave = 0.0
    private var savedEvents: [Date: UserActivityEvent] = [:]
    private(set) var error: String?

    func tick(eligible: Bool, now: Date = .now, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
              calendar: Calendar = .current) {
        defer { lastUptime = uptime; lastDate = now; wasEligible = eligible }
        guard eligible, wasEligible, let previous = lastUptime, let start = lastDate else { return }
        let elapsed = uptime - previous
        // A suspended process or clock adjustment is not evidence of time spent reading.
        guard elapsed > 0, elapsed <= 5, abs(now.timeIntervalSince(start) - elapsed) < 2 else { return }
        var cursor = start
        while cursor < now {
            let boundary = calendar.dateInterval(of: .day, for: cursor)!.end
            let end = min(boundary, now)
            pending[calendar.startOfDay(for: cursor), default: 0] += end.timeIntervalSince(cursor)
            cursor = end
        }
        elapsedSinceSave += elapsed
    }

    func flush(language: String, context: ModelContext, force: Bool = false) {
        guard force || elapsedSinceSave >= 15, !pending.isEmpty else { return }
        var staged: [(Date, UserActivityEvent, Double?)] = []
        for (date, seconds) in pending {
            if let event = savedEvents[date] {
                staged.append((date, event, event.seconds))
                event.seconds += seconds
            } else {
                let event = UserActivityEvent(.init(language: SourceLanguage.canonical(language), date: date,
                                                     kind: "time", seconds: seconds))
                context.insert(event)
                staged.append((date, event, nil))
            }
        }
        do {
            try context.save()
            for (date, event, _) in staged { savedEvents[date] = event }
            pending.removeAll(); elapsedSinceSave = 0; error = nil
        } catch {
            for (_, event, oldSeconds) in staged {
                if let oldSeconds { event.seconds = oldSeconds } else { context.delete(event) }
            }
            self.error = error.localizedDescription
        }
    }

    func resetClock() { lastUptime = nil; lastDate = nil; wasEligible = false }
}

private struct ReadingActivityModifier: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    let language: String
    let isPlaying: () -> Bool
    @State private var recorder = ActivityTimeRecorder()
    @State private var saveError: String?

    func body(content: Content) -> some View {
        content
            .task(id: scenePhase) {
                defer {
                    recorder.flush(language: language, context: context, force: true)
                    recorder.resetClock()
                }
                while !Task.isCancelled {
                    recorder.tick(eligible: scenePhase == .active || isPlaying())
                    recorder.flush(language: language, context: context)
                    if let error = recorder.error { saveError = error }
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
            .onChange(of: scenePhase) { _, _ in
                recorder.flush(language: language, context: context, force: true)
                recorder.resetClock()
            }
            .alert("Activity could not be saved", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
    }
}

extension View {
    func readingActivity(language: String, isPlaying: @escaping () -> Bool) -> some View {
        modifier(ReadingActivityModifier(language: language, isPlaying: isPlaying))
    }
}
