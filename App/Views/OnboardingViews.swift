import SwiftUI

enum OnboardingStep: String, CaseIterable {
    case reading, synchronization, dictionary, practice
    var key: String { "onboarding.v1.\(rawValue)" }
    var title: String {
        switch self {
        case .reading: return "Your first phrase"
        case .synchronization: return "Read along with audio"
        case .dictionary: return "Your personal dictionary"
        case .practice: return "Practise your phrases"
        }
    }
    var message: String {
        switch self {
        case .reading: return "Touch and hold a word, adjust the selection, then choose Add to Dictionary or Translate in Context. Text without synchronization works too."
        case .synchronization: return "Text follows the recording. Scrolling or selecting pauses following; tap Follow audio to return to the current passage. Selecting text also pauses playback."
        case .dictionary: return "Phrases you save while reading appear here. Add or check a Russian translation, then start a practice round. Studied words from reading and card learning levels are tracked separately."
        case .practice: return "Preview your phrases, then recall their original text from the translation. Check your answer and choose Right or Wrong. You can undo an answer for three seconds. Cards need a ready translation and may have a waiting period before the next round."
        }
    }
}

enum OnboardingPreferences {
    static let enabledKey = "onboarding.enabled"
    static let skippedKey = "onboarding.skipped"
    static let generationKey = "onboarding.generation"
    static func reset(_ defaults: UserDefaults = .standard) {
        for step in OnboardingStep.allCases { defaults.removeObject(forKey: step.key) }
        defaults.removeObject(forKey: skippedKey)
        defaults.set(defaults.integer(forKey: generationKey) + 1, forKey: generationKey)
    }
}

/// Native anchored popover. A step is completed only by an explicit action.
struct OnboardingTip: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let step: OnboardingStep
    var allowed = true
    @AppStorage(OnboardingPreferences.enabledKey) private var enabled = true
    @AppStorage(OnboardingPreferences.skippedKey) private var skipped = false
    @AppStorage(OnboardingPreferences.generationKey) private var generation = 0
    @State private var presented = false
    @State private var completed = false
    @State private var visible = false
    private var testAllowsTips: Bool {
        !ProcessInfo.processInfo.arguments.contains("--uitesting") || ProcessInfo.processInfo.arguments.contains("--onboarding-fixture")
    }

    var body: some View {
        Group {
            if enabled && !skipped && !completed && allowed && testAllowsTips {
                Button(step.title, systemImage: "lightbulb") { presented = true }
                    .font(.subheadline).padding(8)
                    .accessibilityIdentifier("onboarding.\(step.rawValue)")
                    .popover(isPresented: $presented) {
                        Group {
                            if typeSize.isAccessibilitySize {
                                ScrollView { tipContent }.frame(maxHeight: 500)
                            } else {
                                tipContent
                            }
                        }
                        .frame(idealWidth: 320, maxWidth: 380)
                        .presentationCompactAdaptation(.popover)
                    }
            }
        }
        .onAppear { visible = true; refresh() }
        .onChange(of: generation) { _, _ in refresh() }
        .onChange(of: allowed) { _, value in if !value { presented = false } }
        .onDisappear { visible = false; presented = false }
    }

    private var tipContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(step.title).font(.headline)
            Text(step.message).fixedSize(horizontal: false, vertical: true)
            Button("Got it") {
                UserDefaults.standard.set(true, forKey: step.key)
                completed = true; presented = false
            }
            .accessibilityIdentifier("onboarding.got-it")
            Button("Skip tutorial") { skipped = true; presented = false }
                .foregroundStyle(.secondary)
        }.padding(24)
    }

    private func refresh() {
        completed = UserDefaults.standard.bool(forKey: step.key)
        presented = visible && enabled && !skipped && !completed && allowed && testAllowsTips
    }
}

struct OnboardingHelpSection: View {
    @AppStorage(OnboardingPreferences.enabledKey) private var enabled = true
    @State private var reset = false
    var body: some View {
        Section("Help and tutorial") {
            NavigationLink("Quick guide") { OnboardingGuideView() }
            Toggle("Show tips", isOn: $enabled)
            Button("Reset tips") { OnboardingPreferences.reset(); reset = true }
                .accessibilityIdentifier("settings.reset-tips")
            if reset { Text(enabled ? "Tips will appear next time you open the relevant screens." : "Tips reset. Enable Show tips to see them again.").font(.caption) }
        }
    }
}

struct OnboardingGuideView: View {
    var body: some View {
        List {
            Section("Start with any book") {
                Text("Add TXT, an audio file, audio tracks in a ZIP, or a complete book package. You can read with text alone or listen with audio alone.")
                Text("Use the book’s ⋮ menu to add missing files or replace current ones. Text and audio work independently until you add a compatible synchronization package.")
            }
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in Section(step.title) { Text(step.message) } }
            Section("Translation") {
                Text("Ordinary translation into Russian uses Apple language packs. A first request may require downloading them. Cloud contextual analysis is optional, requires your OpenAI API key and sends the selected phrase and limited context directly to OpenAI.")
            }
            Section("Your data") {
                Text("Your books, dictionary and reading history are stored on this device. Export a dictionary backup to keep your cards and studied word forms. Dictionary backups do not contain book text, recordings or reading positions.")
            }
        }
        .navigationTitle("Quick guide")
    }
}
