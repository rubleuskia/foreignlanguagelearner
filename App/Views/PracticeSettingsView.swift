import SwiftUI

struct PracticeSettingsView: View {
    @State private var cooldownDrafts = ["24", "72", "96"]
    @State private var cooldownMessage: String?

    private var cooldownValues: [Double]? {
        let values = cooldownDrafts.compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard values.count == 3, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return values
    }

    var body: some View {
        Form {
            Section("Phrase cooldown") {
                ForEach(0..<3, id: \.self) { index in
                    HStack {
                        Text(AppLanguage.format("Level %d · hours", index + 1))
                        TextField("Hours", text: $cooldownDrafts[index])
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("settings.cooldown.level.\(index + 1)")
                    }
                }
                Button("Save cooldowns", systemImage: "checkmark") {
                    guard let values = cooldownValues else { return }
                    for (index, hours) in values.enumerated() {
                        UserDefaults.standard.set(hours, forKey: "learning.cooldown.level.\(index + 1)")
                    }
                    cooldownMessage = "Cooldown settings saved."
                }
                .nativeSecondaryAction()
                .disabled(cooldownValues == nil)
                .accessibilityIdentifier("settings.cooldown.save")
                if cooldownValues == nil {
                    Text("Enter a non-negative number of hours for each level.")
                        .font(.caption).foregroundStyle(.red)
                }
                if let cooldownMessage {
                    Text(AppLanguage.text(cooldownMessage)).font(.caption).foregroundStyle(.secondary)
                }
                Text("Global settings for new practice rounds. Set 0 to disable a level’s cooldown. Changes apply after Save cooldowns.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: cooldownDrafts) { _, _ in cooldownMessage = nil }
        }
        .nativeForm()
        .navigationTitle("Practice settings")
        .task {
            cooldownDrafts = (1...3).map { String(LearningCooldown.hours(level: $0)) }
        }
    }
}
