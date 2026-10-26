import SwiftData
import SwiftUI

struct PracticeHomeView: View {
    @Query private var entries: [DictionaryEntry]
    @AppStorage(LearningRoundCheckpoint.key) private var savedRoundData = Data()
    @State private var launch: Launch?

    private enum Launch: String, Identifiable {
        case quick, setup
        var id: Self { self }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                        Text("A little practice, every day").font(.title2.weight(.semibold))
                        Text("Revisit expressions from your books at your own pace.")
                            .foregroundStyle(.secondary)
                        let count = entries.count(where: \.isReadyForReview)
                        Text("\(count) ready to repeat").font(.headline)
                            .accessibilityIdentifier("practice.ready-count")
                        Button { launch = .quick } label: {
                            Label("Quick start", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                            .nativePrimaryAction()
                            .disabled(count == 0)
                            .accessibilityIdentifier("practice.quick-start")
                    }
                    .padding(.vertical, 12)
                }
                if !savedRoundData.isEmpty, LearningRoundCheckpoint.load() != nil {
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
        .sheet(item: $launch) { LearningSessionView(quickStart: $0 == .quick) }
    }
}
