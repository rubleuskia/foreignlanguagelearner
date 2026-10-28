import Charts
import SwiftData
import SwiftUI

struct ActivityDashboardView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(SourceLanguage.activeKey) private var activeLanguage = "pl"
    @State private var period = ActivityPeriod.week
    @State private var anchor = Date.now
    @State private var report = ActivityDashboardReport.empty
    @State private var languageCodes: [String] = []
    @State private var preparedRequest: ActivityReportRequest?
    @State private var refreshing = false
    @State private var loading = true
    @State private var error: String?
    @State private var selectedDate: Date?

    private let green = Color(red: 0.36, green: 0.86, blue: 0.60)
    private let surface = Color(white: 0.085)
    private var calendar: Calendar {
        var result = Calendar.current
        result.locale = Locale(identifier: AppLanguage.current)
        result.firstWeekday = 2
        result.minimumDaysInFirstWeek = 4
        return result
    }
    private var interval: DateInterval { period.interval(containing: anchor, calendar: calendar) }
    private var request: ActivityReportRequest {
        .init(language: activeLanguage, period: period, anchor: anchor, calendar: calendar)
    }
    private var now: Date { report.updatedAt }

    private var languages: [SourceLanguage] {
        SourceLanguage.filterGroups(bookCodes: [], entryCodes: languageCodes)
    }
    private var language: String { SourceLanguage.resolvedActive(activeLanguage, available: languages) }
    private var dateLocale: Locale { Locale(identifier: AppLanguage.current) }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 800 && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    controls
                    if loading || (preparedRequest != request && error == nil) { ProgressView().frame(maxWidth: .infinity) }
                    if let error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Activity could not be loaded").font(.headline)
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("Try again") { Task { await refresh() } }
                        }.activityCard(surface)
                    }
                    if preparedRequest == request {
                        metrics(wide: wide)
                        if wide {
                            HStack(alignment: .top, spacing: 20) {
                                wordChart.frame(maxWidth: .infinity)
                                phraseProgress.frame(maxWidth: .infinity)
                            }
                            HStack(alignment: .top, spacing: 20) {
                                regularity.frame(maxWidth: .infinity)
                                phraseList.frame(maxWidth: .infinity)
                            }
                        } else {
                            wordChart
                            phraseProgress
                            regularity
                            phraseList
                        }
                    }
                    Text("Reading words and phrase learning are counted separately. Phrase and time history starts with this update. Backups preserve recorded history.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Time includes an open reader in the foreground and actual audio playback in the background. Reading and listening together count once.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20).frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }
            .background(Color.black)
            .accessibilityIdentifier("activity.scroll")
            .refreshable { await refresh() }
        }
        .preferredColorScheme(.dark)
        .tint(green)
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if languages.count > 1 {
                    Picker("Source language", selection: $activeLanguage) {
                        ForEach(languages) { Text($0.flaggedName).tag($0.code) }
                    }.accessibilityIdentifier("activity.language")
                } else {
                    Text(SourceLanguage(code: language, name: SourceLanguage.name(for: language)).flaggedName)
                        .font(.subheadline)
                }
            }
        }
        .task(id: request) { await loadCached(request) }
        .onChange(of: period) { _, _ in selectedDate = nil }
        .onChange(of: anchor) { _, _ in selectedDate = nil }
        .onChange(of: activeLanguage) { _, _ in selectedDate = nil }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            Picker("Period", selection: $period) {
                ForEach(ActivityPeriod.allCases) { Text(AppLanguage.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("activity.period")
            if preparedRequest != nil {
                HStack {
                    Text(AppLanguage.format("Updated: %@", report.updatedAt.formatted(.dateTime.day().month().hour().minute().locale(dateLocale))))
                    Spacer()
                    Text("Pull down to refresh")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Previous period").accessibilityIdentifier("activity.previous")
                Spacer(minLength: 4)
                VStack(spacing: 4) {
                    Text(periodTitle).font(.headline).multilineTextAlignment(.center)
                        .accessibilityIdentifier("activity.dates")
                    if interval.contains(.now) {
                        Text("Current period").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Today") { anchor = .now }.font(.caption)
                    }
                }
                Spacer(minLength: 4)
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(interval.end > .now).accessibilityLabel("Next period")
                    .accessibilityIdentifier("activity.next")
            }
        }
    }

    @ViewBuilder private func metrics(wide: Bool) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 16) {
                wordMetric
                metric("Phrases advanced", value: "\(report.phraseCount)", icon: "bubble.left.and.bubble.right", color: .blue, subtitle: "Different phrases in this period", id: "advanced")
                metric("Phrases learned", value: "\(report.learned)", icon: "graduationcap", color: .purple, subtitle: "Reached level 4", id: "learned")
                timeMetric
            }
        } else {
            wordMetric
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 150))], spacing: 12) {
                metric("Phrases advanced", value: "\(report.phraseCount)", icon: "bubble.left.and.bubble.right", color: .blue, subtitle: "Different phrases in this period", id: "advanced", compact: true)
                metric("Phrases learned", value: "\(report.learned)", icon: "graduationcap", color: .purple, subtitle: "Reached level 4", id: "learned", compact: true)
            }
            HStack {
                Label("Time with books", systemImage: "clock").font(.subheadline)
                Spacer()
                Text(duration(report.seconds)).font(.title3.weight(.semibold)).monospacedDigit()
            }.activityCard(surface).accessibilityElement(children: .combine).accessibilityIdentifier("activity.card.time")
        }
    }

    private var wordMetric: some View {
        metric("New reading words", value: "\(report.words)", icon: "book.fill", color: green,
               subtitle: comparison, id: "words")
    }
    private var timeMetric: some View {
        metric("Time with books", value: duration(report.seconds), icon: "clock", color: .white,
               subtitle: "Reading and audio", id: "time")
    }
    private func metric(_ title: String, value: String, icon: String, color: Color, subtitle: String, id: String, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(color).accessibilityHidden(true)
                Text(value).font(.system(size: compact ? 30 : 36, weight: .semibold, design: .rounded)).foregroundStyle(color)
                    .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                    .accessibilityIdentifier("activity.metric.\(id)")
            }
            Text(AppLanguage.text(title)).font(.subheadline.weight(.medium))
                .frame(minHeight: compact ? 40 : 0, alignment: .topLeading)
            if !compact { Text(AppLanguage.text(subtitle)).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .activityCard(surface).accessibilityElement(children: .combine)
            .accessibilityIdentifier("activity.card.\(id)")
    }

    private var wordChart: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(period == .day ? "Daily rhythm" : "New words by day").font(.headline)
            Label("Reading words", systemImage: "circle.fill").font(.caption).foregroundStyle(green)
            Chart(report.buckets) { bucket in
                BarMark(x: .value(AppLanguage.text("Date"), bucket.start, unit: period == .day ? .hour : .day),
                        y: .value(AppLanguage.text("Words"), bucket.value))
                    .foregroundStyle(green.gradient).cornerRadius(4)
                    .opacity(bucket.future ? 0.15 : 1)
                    .accessibilityLabel(bucket.start.formatted(.dateTime.locale(dateLocale).day().month().hour()))
                    .accessibilityValue(bucket.future ? AppLanguage.text("Future day") : AppLanguage.format("Words: %d", bucket.value))
                if let selectedDate, selectedDate >= bucket.start, selectedDate < bucket.end, !bucket.future {
                    RuleMark(x: .value(AppLanguage.text("Date"), bucket.start)).foregroundStyle(.gray.opacity(0.5))
                        .annotation(position: .top, alignment: .leading) {
                            Text(AppLanguage.format("Words: %d", bucket.value)).font(.caption.bold())
                                .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                }
            }
            .chartXScale(domain: interval.start...interval.end)
            .chartYScale(domain: 0...report.chartMaximum)
            .chartXAxis {
                AxisMarks(values: .stride(by: period == .day ? .hour : .day, count: period == .day ? 4 : period == .week ? 1 : 7)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: period == .day ? .dateTime.hour(.defaultDigits(amPM: .omitted)).locale(dateLocale)
                                 : period == .week ? .dateTime.weekday(.abbreviated).locale(dateLocale)
                                 : .dateTime.day().locale(dateLocale))
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .frame(height: 210).accessibilityIdentifier("activity.chart")
            if report.words == 0 {
                Text("No new reading words in this period. Complete a chapter to add its new words.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.activityCard(surface)
    }

    private var phraseProgress: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Phrase progress").font(.headline)
            ForEach(2...4, id: \.self) { target in
                let count = report.levelCounts[target, default: 0]
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(AppLanguage.format("Level %d", target)).font(.subheadline.bold()).foregroundStyle(levelColor(target))
                        Spacer()
                        Text(AppLanguage.format("Phrases: %d", count)).font(.subheadline).monospacedDigit()
                    }
                    Text(AppLanguage.text(LearningLevel.title(target))).font(.caption).foregroundStyle(.secondary)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10))
                            Capsule().fill(levelColor(target)).frame(width: proxy.size.width * Double(count) / Double(max(1, report.phraseCount)))
                        }
                    }.frame(height: 6)
                }
            }
            Text(AppLanguage.format("Different phrases: %d · promotions: %d", report.phraseCount, report.promotions))
                .font(.caption).foregroundStyle(.secondary)
            Text("Each phrase appears once, at its highest reached level. Manual changes are included.")
                .font(.caption).foregroundStyle(.secondary)
        }.activityCard(surface)
    }

    private var regularity: some View {
        let month = calendar.dateInterval(of: .month, for: anchor)!
        let days = calendar.range(of: .day, in: .month, for: anchor)!
        let offset = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        let active = report.activeDays
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Consistency").font(.headline)
                Spacer()
                Label(AppLanguage.format("%d day streak", report.streak), systemImage: "flame.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(anchor, format: .dateTime.month(.wide).year().locale(dateLocale)).font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(0..<7) { index in
                    let weekday = calendar.date(byAdding: .day, value: index, to: calendar.dateInterval(of: .weekOfYear, for: month.start)!.start)!
                    Text(weekday, format: .dateTime.weekday(.narrow).locale(dateLocale))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(0..<(offset + days.count), id: \.self) { index in
                    if index < offset { Color.clear.frame(height: 32).accessibilityHidden(true) }
                    else {
                        let date = calendar.date(byAdding: .day, value: index - offset, to: month.start)!
                        let hasActivity = active.contains(date)
                        Text("\(index - offset + 1)").font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(hasActivity ? green.opacity(0.65) : .white.opacity(date > now ? 0.025 : 0.075), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(calendar.isDateInToday(date) ? .white : .clear, lineWidth: 1))
                            .foregroundStyle(date > now ? .secondary : .primary)
                            .accessibilityLabel(date.formatted(.dateTime.locale(dateLocale).day().month()))
                            .accessibilityValue(AppLanguage.text(date > now ? "Future day" : hasActivity ? "Active day" : "No activity"))
                    }
                }
            }.accessibilityIdentifier("activity.calendar")
            Text("Green marks days with reading, listening or phrase practice.").font(.caption).foregroundStyle(.secondary)
        }.activityCard(surface)
    }

    private var phraseList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What moved forward").font(.headline)
            if report.phraseCount == 0 {
                Label("Practice phrases to see their progress here.", systemImage: "rectangle.on.rectangle")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(Array(report.recentPhrases)) { record in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.phrase).font(.subheadline.weight(.medium))
                        Text(record.translation).font(.caption).foregroundStyle(.secondary)
                        if record.origin == "manual" { Text("Manual change").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    Text("\(record.fromLevel) → \(record.toLevel)").font(.caption.bold()).monospacedDigit()
                        .foregroundStyle(levelColor(record.toLevel)).padding(7)
                        .background(levelColor(record.toLevel).opacity(0.12), in: Capsule())
                }
                if record.id != report.recentPhrases.last?.id { Divider() }
            }
            if report.phraseCount > 10 { Text("Showing the 10 most recent phrases").font(.caption).foregroundStyle(.secondary) }
        }.activityCard(surface)
    }

    private var periodTitle: String {
        switch period {
        case .day: anchor.formatted(.dateTime.day().month(.wide).year().locale(dateLocale))
        case .month: anchor.formatted(.dateTime.month(.wide).year().locale(dateLocale))
        case .week: interval.start.formatted(.dateTime.day().month(.abbreviated).locale(dateLocale)) + " — "
            + calendar.date(byAdding: .day, value: -1, to: interval.end)!.formatted(.dateTime.day().month(.abbreviated).year().locale(dateLocale))
        }
    }
    private var comparison: String {
        let previous = report.previousWords
        guard previous > 0 else { return AppLanguage.text("First encounters in completed chapters") }
        let delta = Int((Double(report.words - previous) / Double(previous) * 100).rounded())
        return AppLanguage.format("%+d%% vs. the same part of the previous period", delta)
    }
    private func move(_ direction: Int) {
        anchor = calendar.date(byAdding: period.component, value: direction, to: interval.start)!
    }
    private func levelColor(_ level: Int) -> Color {
        switch level { case 1: .orange; case 2: .blue; case 3: .purple; default: green }
    }
    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? AppLanguage.format("%d h %d min", minutes / 60, minutes % 60)
            : AppLanguage.format("%d min", minutes)
    }
    @MainActor private func loadCached(_ selection: ActivityReportRequest) async {
        do {
            let loaded = try await ActivityStatisticsCache.shared.report(container: context.container, request: selection)
            let codes = await ActivityStatisticsCache.shared.languages()
            try Task.checkCancellation()
            guard selection == request else { return }
            report = loaded; languageCodes = codes; preparedRequest = selection
            error = nil; loading = false
        } catch is CancellationError { } catch {
            guard selection == request else { return }
            self.error = error.localizedDescription; loading = false
        }
    }

    @MainActor private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let selection = request
            let loaded = try await ActivityStatisticsCache.shared.report(container: context.container, request: selection, refresh: true)
            let codes = await ActivityStatisticsCache.shared.languages()
            // UIKit may cancel the refresh task as its gesture/control finishes. A successful
            // explicit load still replaces the cache and the visible results for this selection.
            if selection == request {
                report = loaded; languageCodes = codes; preparedRequest = selection
                error = nil; loading = false
            } else { await loadCached(request) }
        } catch is CancellationError { } catch { self.error = error.localizedDescription; loading = false }
    }
}

private extension View {
    func activityCard(_ color: Color) -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(color, in: RoundedRectangle(cornerRadius: 22))
    }
}
