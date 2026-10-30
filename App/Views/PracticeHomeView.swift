import SwiftData
import SwiftUI

struct PracticeHomeView: View {
    @Query private var allEntries: [DictionaryEntry]
    @Query private var books: [LearningItem]
    @AppStorage(LearningRoundCheckpoint.key) private var savedRoundData = Data()
    @AppStorage(SourceLanguage.activeKey) private var activeLanguage = "pl"
    private var entries: [DictionaryEntry] {
        SourceLanguage.entries(allEntries, language: activeLanguage)
    }
    private var languages: [SourceLanguage] {
        SourceLanguage.filterGroups(bookCodes: books.map(\.sourceLanguageCode), entryCodes: allEntries.map(\.sourceLanguageCode))
    }
    @State private var launch: Launch?

    private enum Launch: String, Identifiable {
        case quick, setup, listening
        var id: Self { self }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            List {
                Section {
                    if languages.count > 1 {
                        Picker("Source language", selection: $activeLanguage) {
                            ForEach(languages) { Text($0.flaggedName).tag($0.code) }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("source-language.picker")
                    } else {
                        HStack {
                            Text("Source language")
                            Spacer()
                            Text(languages.first?.flaggedName ?? SourceLanguage.polish.flaggedName)
                                .foregroundStyle(.secondary)
                        }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("source-language.current")
                    }
                }
                OnboardingTip(step: .practice, allowed: !entries.isEmpty && launch == nil)
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                        Text("A little practice, every day").font(.title2.weight(.semibold))
                        Text("Revisit expressions from your books at your own pace.")
                            .foregroundStyle(.secondary)
                        let count = entries.count(where: \.isReadyForReview)
                        Text(AppLanguage.format("%d ready to repeat", count)).font(.headline)
                            .accessibilityIdentifier("practice.ready-count")
                        if count == 0 {
                            Text(AppLanguage.text(entries.isEmpty
                                ? "Save a phrase from a book and add a Russian translation to start."
                                : "Cards need a ready Russian translation and an expired waiting period. Check each card in Dictionary for its remaining time."))
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let next = entries.filter(\.isLearningEligible).compactMap({ LearningCooldown.remainingTime($0) }).filter({ $0 > 0 }).min() {
                                Text(AppLanguage.format("Next phrase ready in %@", LearningCooldown.remainingDescription(seconds: next)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button { launch = .quick } label: {
                            Text("Quick start")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                            .nativePrimaryAction()
                            .disabled(count == 0)
                            .accessibilityIdentifier("practice.quick-start")
                    }
                    .padding(.vertical, 12)
                }
                Section {
                    Button("Listening practice", systemImage: "headphones") { launch = .listening }
                        .frame(minHeight: 44)
                        .disabled(entries.isEmpty)
                        .accessibilityIdentifier("practice.listening")
                } footer: {
                    Text("Listen and choose a translation. Up to 10 random phrases; progress is not saved.")
                }
                if !savedRoundData.isEmpty, LearningRoundCheckpoint.peek(language: activeLanguage, entries: allEntries) != nil {
                    Section {
                        Button("Continue unfinished training", systemImage: "arrow.clockwise") { launch = .setup }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("practice.resume")
                    }
                }
                Section {
                    Button("Set up a round", systemImage: "slider.horizontal.3") { launch = .setup }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("practice.setup")
                    NavigationLink { PracticeSettingsView() } label: {
                        Label("Practice settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("practice.settings")
                } footer: {
                    Text("Preview expressions first, then practise recalling them. Your progress is saved after every answer.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(NativeDesign.page)
        }
        .navigationTitle("Practice")
        .task { activeLanguage = SourceLanguage.resolvedActive(activeLanguage, available: languages) }
        .onChange(of: languages.map(\.code)) { _, _ in
            activeLanguage = SourceLanguage.resolvedActive(activeLanguage, available: languages)
        }
        .sheet(item: $launch) { destination in
            if destination == .listening {
                ListeningPracticeView(entries: entries, books: books)
            } else {
                LearningSessionView(sourceLanguage: activeLanguage, quickStart: destination == .quick)
            }
        }
    }
}
