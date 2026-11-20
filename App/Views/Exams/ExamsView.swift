import SwiftUI

private enum ExamScreen: Hashable { case overview, runner }

@MainActor
struct ExamsNavigationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = ExamStore()
    @State private var path: [ExamScreen] = []
    @State private var search = ""
    @State private var openingID: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 22) {
                Text(AppLanguage.text("Original exam papers with interactive tasks and recordings."))
                    .font(.subheadline).foregroundStyle(.secondary)
                if store.isLoading && store.catalog.isEmpty { ProgressView(AppLanguage.text("Loading exams…")) }
                if let error = store.errorMessage { Text(AppLanguage.text(error)).foregroundStyle(.red) }
                if !store.isLoading && store.catalog.isEmpty {
                    ContentUnavailableView {
                        Label(AppLanguage.text("No exams available"), systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text(AppLanguage.text("Sign in to your cloud library in Settings, then refresh the exam catalog."))
                    } actions: {
                        Button(AppLanguage.text("Refresh")) { Task { await store.loadCatalog() } }
                    }
                }
                let groups = ExamCatalogGroup.groups(store.catalog, search: search)
                if groups.isEmpty && !store.catalog.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Text(group.level).font(.title2.bold()).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Label(AppLanguage.text(group.audience == "adults" ? "Adults" : "Children and teenagers"),
                                      systemImage: group.audience == "adults" ? "person" : "figure.2.and.child.holdinghands")
                                    .font(.headline)
                                Text(AppLanguage.format("%d exams", group.exams.count)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityElement(children: .combine)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), alignment: .top)], spacing: 14) {
                            ForEach(group.exams) { entry in catalogCard(entry) }
                        }
                    }.accessibilityIdentifier("exams.group.\(group.id)")
                }
                if let message = store.syncMessage { Text(AppLanguage.text(message)).font(.caption).foregroundStyle(.secondary) }
              }.padding().frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(AppLanguage.text("Exams"))
            .searchable(text: $search, prompt: AppLanguage.text("Search exams"))
            .refreshable { await store.loadCatalog(); await store.synchronize() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { ContextualTranslationSettingsView() } label: { Label(AppLanguage.text("Settings"), systemImage: "gearshape") }
                        .accessibilityIdentifier("exams.settings")
                }
            }
            .navigationDestination(for: ExamScreen.self) { screen in
                switch screen {
                case .overview: ExamOverviewView(store: store) { path.append(.runner) }
                case .runner: ExamRunnerView(store: store)
                }
            }
        }
        .task { await store.loadCatalog() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            store.tick()
            await store.synchronize()
            while !Task.isCancelled {
                store.tick()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .accessibilityIdentifier("exams.root")
    }

    private func catalogCard(_ entry: ExamCatalogEntry) -> some View {
        Button {
            openingID = entry.id
            Task {
                await store.openExam(entry)
                openingID = nil
                if store.package?.id == entry.id { path.append(.overview) }
            }
        } label: {
            ExamSurface {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(entry.level).font(.title.bold()).foregroundStyle(.tint)
                        Spacer()
                        if openingID == entry.id { ProgressView() }
                        else { Image(systemName: "arrow.up.right").foregroundStyle(.secondary) }
                    }
                    Text(entry.sessionLabel).font(.headline).foregroundStyle(.primary)
                    Text(entry.title).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    ForEach(entry.availableSectionIDs, id: \.self) { id in
                        Label(ExamDisplay.title(id), systemImage: ExamDisplay.icon(id))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.buttonStyle(.plain).disabled(openingID != nil)
            .accessibilityIdentifier("exams.open.\(entry.id)")
    }
}

@MainActor
private struct ExamOverviewView: View {
    @ObservedObject var store: ExamStore
    let openRunner: () -> Void
    @State private var selectedSection: ExamSection?

    var body: some View {
        Group {
            if let package = store.package {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(package.title).font(.title2.weight(.semibold))
                            Text(AppLanguage.text("Choose a part of the original exam. Training allows pauses and seeking; exam mode follows the original time limit."))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                    Section(AppLanguage.text("Exam parts")) {
                        ForEach(interactiveSections(package), id: \.id) { section in
                            Button { selectedSection = section } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: ExamDisplay.icon(section.id)).font(.title3).frame(width: 28).foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(section.title).font(.headline).foregroundStyle(.primary)
                                        Text(sectionMetadata(section)).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "plus.circle").foregroundStyle(.tint)
                                }.padding(.vertical, 8)
                            }.buttonStyle(.plain).accessibilityIdentifier("exams.section.\(section.id)")
                        }
                    }
                    let saved = store.attempts.filter { $0.examID == package.id && $0.revision == package.revision && ["listening", "reading", "grammar"].contains($0.sectionID) }.sorted { $0.startedAt > $1.startedAt }
                    if !saved.isEmpty {
                        Section(AppLanguage.text("Your attempts")) {
                            ForEach(saved, id: \.id) { attempt in
                                Button {
                                    Task { await store.resume(attempt); if store.currentAttempt?.id == attempt.id { openRunner() } }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(ExamDisplay.title(attempt.sectionID)).font(.subheadline).foregroundStyle(.primary)
                                            Text(attempt.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                            Text(AppLanguage.text(attempt.mode == .training ? "Training" : "Exam")).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.right.circle").foregroundStyle(.tint)
                                    }.padding(.vertical, 5)
                                }.buttonStyle(.plain).accessibilityIdentifier("exams.attempt.\(attempt.id)")
                            }
                        }
                    }
                    if let error = store.errorMessage { Section { Text(AppLanguage.text(error)).foregroundStyle(.red) } }
                    if let message = store.syncMessage { Section { Text(AppLanguage.text(message)).font(.caption).foregroundStyle(.secondary) } }
                }
            } else { ContentUnavailableView(AppLanguage.text("Exam unavailable"), systemImage: "doc.text", description: Text(AppLanguage.text("Return to the catalog and reopen this exam."))) }
        }
        .navigationTitle(AppLanguage.text("Exam")).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedSection) { section in
            ExamStartView(store: store, section: section) { selectedSection = nil; openRunner() }
        }
        .toolbar { Button(AppLanguage.text("Sync"), systemImage: "arrow.triangle.2.circlepath") { Task { await store.synchronize() } }.disabled(store.isLoading) }
    }

    private func interactiveSections(_ package: ExamPackage) -> [ExamSection] {
        package.interactiveSections.sorted { $0.position < $1.position }
    }
    private func sectionMetadata(_ section: ExamSection) -> String {
        var values = [AppLanguage.format("%d tasks", section.tasks.count), AppLanguage.format("%@ points", ExamDisplay.points(section.maxScoreUnits))]
        if let seconds = section.timeLimitSeconds { values.append(AppLanguage.format("%d min", seconds / 60)) }
        return values.joined(separator: " · ")
    }
}

@MainActor
private struct ExamStartView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ExamStore
    let section: ExamSection
    let openRunner: () -> Void
    @State private var mode: ExamMode = .training
    @State private var starting = false

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(section.title).font(.headline) }
                Section(AppLanguage.text("Choose a mode")) {
                    Picker(AppLanguage.text("Mode"), selection: $mode) {
                        Text(AppLanguage.text("Training")).tag(ExamMode.training)
                        Text(AppLanguage.text("Exam")).tag(ExamMode.exam)
                    }.pickerStyle(.segmented)
                    if mode == .training {
                        Label(AppLanguage.text("Pause, seek and repeat the recording for each task."), systemImage: "play.circle")
                        Text(AppLanguage.text("Answers are saved as you work. You can pause and continue later.")).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Label(AppLanguage.text("The original recording plays once, without pause or seeking."), systemImage: "headphones")
                        Text(AppLanguage.text("The time limit continues while the app is closed. Your part is submitted when its deadline is reached. An interrupted recording resumes from the saved position.")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(AppLanguage.text("The mode cannot be changed after starting this attempt.")).font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.errorMessage { Text(AppLanguage.text(error)).foregroundStyle(.red) }
                Section {
                    Button {
                        starting = true
                        Task {
                            await store.start(sectionID: section.id, mode: mode)
                            starting = false
                            if store.errorMessage == nil, store.currentAttempt?.sectionID == section.id {
                                dismiss(); openRunner()
                            }
                        }
                    } label: {
                        HStack { Text(AppLanguage.text("Start attempt")); Spacer(); if starting { ProgressView() } else { Image(systemName: "arrow.right") } }
                    }.disabled(starting).accessibilityIdentifier("exams.start")
                }
            }
            .navigationTitle(AppLanguage.text("Start exam")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppLanguage.text("Cancel")) { dismiss() }.disabled(starting) } }
        }
    }
}
