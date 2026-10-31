import SwiftUI

struct ContextualTranslationSettingsView: View {
    @AppStorage(AppLanguage.key) private var interfaceLanguage = "ru"
    @AppStorage(ContextAnalysisSettings.cloudAnalysisEnabledKey)
    private var cloudAnalysisEnabled = false
    @AppStorage(ContextAnalysisSettings.modelKey)
    private var selectedModelRawValue = OpenAITranslationModel.mini.rawValue
    @AppStorage(ContextAnalysisSettings.reasoningEffortKey) private var reasoningEffortRawValue = ""
    @State private var apiKey = ""
    @State private var hasSavedAPIKey = false
    @State private var keyMessage: String?
    @State private var checkingKey = false
    @State private var keyCheckMessage: String?
    @State private var keyCheckFailed = false
    @State private var prompt = OpenAIContextAnalysisProvider.defaultPrompt
    @State private var hasCustomPrompt = false
    @State private var promptMessage: String?
    @State private var promptMessageIsError = false

    @State private var wordPrompt = OpenAIWordExplanationProvider.defaultPrompt
    @State private var hasCustomWordPrompt = false
    @State private var wordPromptMessage: String?

    var body: some View {
        Form {
            Section("Interface language") {
                Picker("Interface language", selection: $interfaceLanguage) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
                .accessibilityIdentifier("settings.interface-language")
            }
            OnboardingHelpSection()
            Section("Contextual translation") {
                Toggle("Enable cloud analysis", isOn: $cloudAnalysisEnabled)
                Picker("Model", selection: selectedModelBinding) {
                    ForEach(OpenAITranslationModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .disabled(checkingKey)
                .onChange(of: selectedModelRawValue) { _, _ in keyCheckMessage = nil }
                Picker("Reasoning effort", selection: reasoningBinding) {
                    ForEach(currentModel.supportedReasoningEfforts, id: \.self) { effort in
                        Text(AppLanguage.text(reasoningTitle(effort))).tag(effort)
                    }
                }
                .disabled(checkingKey)
                .accessibilityIdentifier("settings.reasoning-effort")
                .onChange(of: reasoningEffortRawValue) { _, _ in keyCheckMessage = nil }
                Text("More reasoning can improve complex answers, but takes longer and uses more tokens.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Configuration") {
                    Text(AppLanguage.text(hasSavedAPIKey ? "API key saved" : "API key required"))
                        .foregroundStyle(hasSavedAPIKey ? Color.secondary : Color.orange)
                }
                SecureField("OpenAI API key", text: $apiKey)
                    .disabled(checkingKey)
                    .onChange(of: apiKey) { _, _ in keyCheckMessage = nil }
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(AppLanguage.text(hasSavedAPIKey ? "Replace API Key" : "Save API Key")) { saveAPIKey() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(AppLanguage.text(checkingKey ? "Checking…" : "Check API Key")) {
                    Task { await checkAPIKey() }
                }
                .disabled(checkingKey || (!hasSavedAPIKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .accessibilityIdentifier("settings.check-api-key")
                if let keyCheckMessage {
                    Text(AppLanguage.text(keyCheckMessage)).font(.caption)
                        .foregroundStyle(keyCheckFailed ? Color.red : Color.green)
                }
                Text("Checks the entered key, or the saved key if the field is empty, with a small API request using the selected model.")
                    .font(.caption).foregroundStyle(.secondary)
                if hasSavedAPIKey {
                    Button("Delete API Key", role: .destructive) { deleteAPIKey() }.disabled(checkingKey)
                }
                if let keyMessage {
                    Text(AppLanguage.text(keyMessage)).font(.caption).foregroundStyle(.red)
                }
                Text("The key is stored in this device's Keychain. When enabled, the selected phrase and limited surrounding context are sent directly to OpenAI. API usage is billed to the account that owns this key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section { DisclosureGroup("Diagnostics") { ExportLogsButton() } }
            Section {
                DisclosureGroup("Translation prompt") {
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
                        Text(AppLanguage.text(promptMessage))
                            .font(.caption)
                            .foregroundStyle(promptMessageIsError ? Color.red : Color.secondary)
                    }
                    Text("Changes apply to new requests. The structured-output and prompt-injection safety rules remain enforced by the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            wordPromptSection
        }
        .nativeForm()
        .navigationTitle(AppLanguage.text("Settings"))
        .task {
            refreshKeyStatus()
            refreshPrompt()
            refreshWordPrompt()
        }
    }

    private var wordPromptSection: some View {
        Section {
            DisclosureGroup("Word explanation prompt") {
                Text("Used when you tap a word in Meaning in context.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $wordPrompt)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.word-prompt.editor")
                    .onChange(of: wordPrompt) { _, _ in wordPromptMessage = nil }
                HStack {
                    Text("\(wordPrompt.utf16.count) / \(ContextAnalysisSettings.maximumPromptUTF16)")
                        .font(.caption)
                        .foregroundStyle(wordPromptIsValid ? Color.secondary : Color.red)
                    Spacer()
                    if hasCustomWordPrompt {
                        Text("Customized").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Save Prompt", systemImage: "checkmark") {
                    do {
                        try ContextAnalysisSettings.setWordExplanationPrompt(wordPrompt)
                        refreshWordPrompt()
                        wordPromptMessage = hasCustomWordPrompt ? "Custom prompt saved." : "Default prompt is active."
                    } catch {
                        wordPromptMessage = "Prompt must contain 1–\(ContextAnalysisSettings.maximumPromptUTF16) characters."
                    }
                }
                .disabled(!wordPromptIsValid)
                .accessibilityIdentifier("settings.word-prompt.save")
                Button("Reset to Default", systemImage: "arrow.counterclockwise") {
                    ContextAnalysisSettings.resetWordExplanationPrompt()
                    refreshWordPrompt()
                    wordPromptMessage = "Default prompt restored."
                }
                .accessibilityIdentifier("settings.word-prompt.reset")
                if let wordPromptMessage {
                    Text(AppLanguage.text(wordPromptMessage)).font(.caption).foregroundStyle(.secondary)
                }
                Text("Save to use this prompt for new word explanations. Reset to Default restores the original prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var currentModel: OpenAITranslationModel {
        OpenAITranslationModel(rawValue: selectedModelRawValue) ?? .mini
    }

    private var reasoningBinding: Binding<String> {
        Binding(get: { currentModel.resolvedReasoningEffort(reasoningEffortRawValue) },
                set: { reasoningEffortRawValue = $0 })
    }

    private func reasoningTitle(_ value: String) -> String {
        switch value {
        case "none": "Off"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra high"
        default: "Maximum"
        }
    }

    private var selectedModelBinding: Binding<OpenAITranslationModel> {
        Binding(
            get: { OpenAITranslationModel(rawValue: selectedModelRawValue) ?? .mini },
            set: { selectedModelRawValue = $0.rawValue }
        )
    }

    private var wordPromptIsValid: Bool {
        let trimmed = wordPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf16.count <= ContextAnalysisSettings.maximumPromptUTF16
    }

    private func refreshWordPrompt() {
        wordPrompt = ContextAnalysisSettings.wordExplanationPrompt()
        hasCustomWordPrompt = ContextAnalysisSettings.wordExplanationPromptOverride() != nil
        wordPromptMessage = nil
    }

    private var promptIsValid: Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf16.count <= ContextAnalysisSettings.maximumPromptUTF16
    }

    @MainActor private func checkAPIKey() async {
        checkingKey = true
        keyCheckMessage = nil
        defer { checkingKey = false }
        do {
            let draft = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = try draft.isEmpty ? OpenAIAPIKeyStore.load() : draft
            guard let key else { throw ContextAnalysisError.missingConfiguration }
            let provider = OpenAIContextAnalysisProvider(apiKey: key,
                model: currentModel, reasoningEffort: currentModel.resolvedReasoningEffort(reasoningEffortRawValue))
            try await provider.validateAPIKey()
            keyCheckFailed = false
            keyCheckMessage = "OK — API key and selected model are available."
        } catch {
            keyCheckFailed = true
            keyCheckMessage = (error as? ContextAnalysisError)?.userMessage ?? error.localizedDescription
        }
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
        keyCheckMessage = nil
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
