import SwiftUI

struct ContextualTranslationSettingsView: View {
    @AppStorage(ContextAnalysisSettings.cloudAnalysisEnabledKey)
    private var cloudAnalysisEnabled = false
    @AppStorage(ContextAnalysisSettings.modelKey)
    private var selectedModelRawValue = OpenAITranslationModel.mini.rawValue
    @State private var apiKey = ""
    @State private var hasSavedAPIKey = false
    @State private var keyMessage: String?
    @State private var prompt = OpenAIContextAnalysisProvider.defaultPrompt
    @State private var hasCustomPrompt = false
    @State private var promptMessage: String?
    @State private var promptMessageIsError = false

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
                        Text("Level \(index + 1) · hours")
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
                .disabled(cooldownValues == nil)
                .accessibilityIdentifier("settings.cooldown.save")
                if cooldownValues == nil {
                    Text("Enter a non-negative number of hours for each level.")
                        .font(.caption).foregroundStyle(.red)
                }
                if let cooldownMessage {
                    Text(cooldownMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("Global settings for new practice rounds. Set 0 to disable a level’s cooldown. Changes apply after Save cooldowns.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: cooldownDrafts) { _, _ in cooldownMessage = nil }
            Section("Contextual translation") {
                Toggle("Enable cloud analysis", isOn: $cloudAnalysisEnabled)
                Picker("Model", selection: selectedModelBinding) {
                    ForEach(OpenAITranslationModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                LabeledContent("Configuration") {
                    Text(hasSavedAPIKey ? "API key saved" : "API key required")
                        .foregroundStyle(hasSavedAPIKey ? Color.secondary : Color.orange)
                }
                SecureField("OpenAI API key", text: $apiKey)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(hasSavedAPIKey ? "Replace API Key" : "Save API Key") { saveAPIKey() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasSavedAPIKey {
                    Button("Delete API Key", role: .destructive) { deleteAPIKey() }
                }
                if let keyMessage {
                    Text(keyMessage).font(.caption).foregroundStyle(.red)
                }
                Text("The key is stored in this device's Keychain. When enabled, the selected phrase and limited surrounding context are sent directly to OpenAI. API usage is billed to the account that owns this key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Diagnostics") { ExportLogsButton() }
            Section("Translation prompt") {
                TextEditor(text: $prompt)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Text("\(prompt.utf16.count) / \(ContextAnalysisSettings.maximumPromptUTF16)")
                        .font(.caption)
                        .foregroundStyle(promptIsValid ? Color.secondary : Color.red)
                    Spacer()
                    if hasCustomPrompt {
                        Text("Customized").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Save Prompt", systemImage: "checkmark") { savePrompt() }
                    .disabled(!promptIsValid)
                Button("Reset to Default", systemImage: "arrow.counterclockwise") {
                    resetPrompt()
                }
                if let promptMessage {
                    Text(promptMessage)
                        .font(.caption)
                        .foregroundStyle(promptMessageIsError ? Color.red : Color.secondary)
                }
                Text("Changes apply to new requests. The structured-output and prompt-injection safety rules remain enforced by the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task {
            cooldownDrafts = (1...3).map { String(LearningCooldown.hours(level: $0)) }
            refreshKeyStatus()
            refreshPrompt()
        }
    }

    private var selectedModelBinding: Binding<OpenAITranslationModel> {
        Binding(
            get: { OpenAITranslationModel(rawValue: selectedModelRawValue) ?? .mini },
            set: { selectedModelRawValue = $0.rawValue }
        )
    }

    private var promptIsValid: Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf16.count <= ContextAnalysisSettings.maximumPromptUTF16
    }

    private func saveAPIKey() {
        do {
            try OpenAIAPIKeyStore.save(apiKey)
            apiKey = ""
            keyMessage = nil
            hasSavedAPIKey = true
        } catch {
            keyMessage = "The API key could not be saved."
        }
    }

    private func deleteAPIKey() {
        do {
            try OpenAIAPIKeyStore.delete()
            apiKey = ""
            keyMessage = nil
            hasSavedAPIKey = false
            cloudAnalysisEnabled = false
        } catch {
            keyMessage = "The API key could not be deleted."
        }
    }

    private func refreshKeyStatus() {
        do {
            hasSavedAPIKey = try OpenAIAPIKeyStore.load() != nil
            keyMessage = nil
        } catch {
            hasSavedAPIKey = false
            keyMessage = "The Keychain is unavailable."
        }
    }

    private func refreshPrompt() {
        prompt = ContextAnalysisSettings.prompt()
        hasCustomPrompt = ContextAnalysisSettings.promptOverride() != nil
        promptMessage = nil
        promptMessageIsError = false
    }

    private func savePrompt() {
        do {
            try ContextAnalysisSettings.setPrompt(prompt)
            prompt = ContextAnalysisSettings.prompt()
            hasCustomPrompt = ContextAnalysisSettings.promptOverride() != nil
            promptMessage = hasCustomPrompt ? "Custom prompt saved." : "Default prompt is active."
            promptMessageIsError = false
        } catch {
            promptMessage = "Prompt must contain 1–\(ContextAnalysisSettings.maximumPromptUTF16) characters."
            promptMessageIsError = true
        }
    }

    private func resetPrompt() {
        ContextAnalysisSettings.resetPrompt()
        prompt = OpenAIContextAnalysisProvider.defaultPrompt
        hasCustomPrompt = false
        promptMessage = "Default prompt restored."
        promptMessageIsError = false
    }
}
