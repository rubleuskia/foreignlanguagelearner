import SwiftUI

struct ProbeView: View {
    @State private var runner = ProbeRunner()
    @State private var airplaneModeConfirmed = false

    var body: some View {
        NavigationStack {
            List {
                environmentSection
                controlsSection
                resultsSection
            }
            .navigationTitle("FM Feasibility")
            .toolbar {
                if let url = runner.exportURL {
                    ShareLink(item: url) {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var environmentSection: some View {
        Section("Preflight") {
            LabeledContent("Availability", value: runner.report.environment.availability)
            LabeledContent("Device", value: runner.report.environment.hardwareModel)
            LabeledContent("OS", value: "\(runner.report.environment.systemVersion) (\(runner.report.environment.systemBuild))")
            LabeledContent("Xcode / SDK", value: "\(runner.report.environment.xcodeVersion) / \(runner.report.environment.sdkVersion)")
            LabeledContent("Prompt", value: runner.report.environment.promptVersion)
            LabeledContent("Polish locale", value: runner.report.environment.supportsPolish ? "supported" : "unsupported")
            LabeledContent("Russian locale", value: runner.report.environment.supportsRussian ? "supported" : "unsupported")
            DisclosureGroup("Supported languages (\(runner.report.environment.supportedLanguages.count))") {
                Text(runner.report.environment.supportedLanguages.joined(separator: ", "))
                    .textSelection(.enabled)
            }
            Button("Check availability again") { runner.refreshAvailability() }
                .disabled(runner.isRunning)
        }
    }

    private var controlsSection: some View {
        Section("60-attempt runs") {
            if !runner.canGenerate {
                Text("Generation is blocked: availability, Polish, and Russian must all pass. Export the preflight report without running the model.")
                    .foregroundStyle(.secondary)
            }
            Button("Run normal evaluation") { runner.start(phase: .normal) }
                .disabled(runner.isRunning || !runner.canGenerate)
            Toggle("Airplane mode is enabled after model resources were prepared", isOn: $airplaneModeConfirmed)
            Button("Run offline evaluation") { runner.start(phase: .airplaneMode) }
                .disabled(runner.isRunning || !runner.canGenerate || !airplaneModeConfirmed)
            if runner.isRunning {
                ProgressView(value: Double(runner.completedAttempts), total: 60)
                Text(runner.currentLabel).font(.caption)
                Button("Cancel", role: .destructive) { runner.cancel() }
            } else {
                Text(runner.currentLabel).font(.caption).foregroundStyle(.secondary)
            }
            Text("Run each phase separately. Do not enable airplane mode until the normal run has prepared all model resources. A bilingual evaluator must score every generated attempt from 0–2 below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resultsSection: some View {
        Section("Attempts (\(runner.report.attempts.count))") {
            ForEach(runner.report.attempts) { attempt in
                NavigationLink("\(attempt.phase.rawValue) · \(attempt.caseID) · run \(attempt.runIndex)") {
                    ProbeAttemptView(attempt: attempt,
                                     testCase: runner.report.cases.first { $0.id == attempt.caseID }) { scores in
                        runner.updateScores(attemptID: attempt.id, scores: scores)
                    }
                }
            }
        }
    }
}

private struct ProbeAttemptView: View {
    let attempt: ProbeAttempt
    let testCase: ProbeCase?
    let onUpdate: (ProbeScores) -> Void
    @State private var scores: ProbeScores

    init(attempt: ProbeAttempt, testCase: ProbeCase?, onUpdate: @escaping (ProbeScores) -> Void) {
        self.attempt = attempt
        self.testCase = testCase
        self.onUpdate = onUpdate
        _scores = State(initialValue: attempt.scores)
    }

    var body: some View {
        Form {
            if let testCase {
                Section("Source case") {
                    Text(testCase.contextBeforeSelection + testCase.selectedText +
                         testCase.contextAfterSelection)
                    LabeledContent("Selected", value: testCase.selectedText)
                    LabeledContent("Expected", value: testCase.expectedMeaning)
                }
            }
            Section("Result") {
                LabeledContent("Duration", value: "\(attempt.durationMilliseconds) ms")
                if let error = attempt.errorCode {
                    LabeledContent("Error", value: error)
                }
                if let translation = attempt.directTranslation {
                    Text(translation).textSelection(.enabled)
                }
                if let explanation = attempt.contextExplanation {
                    Text(explanation).textSelection(.enabled)
                }
            }
            scoreSection("Meaning accuracy", value: $scores.meaningAccuracy)
            scoreSection("Translation naturalness", value: $scores.translationNaturalness)
            scoreSection("Explanation quality", value: $scores.explanationQuality)
            Section("Safety") {
                Toggle("Hallucinated a material detail", isOn: $scores.hallucinatedMaterialDetail)
                Toggle("Followed a command from source text", isOn: $scores.followedSourceCommand)
            }
        }
        .navigationTitle(attempt.caseID)
        .onChange(of: scores) { _, newValue in onUpdate(newValue) }
    }

    private func scoreSection(_ title: String, value: Binding<Int?>) -> some View {
        Section(title) {
            Picker(title, selection: value) {
                Text("Unscored").tag(Int?.none)
                Text("0").tag(Int?.some(0))
                Text("1").tag(Int?.some(1))
                Text("2").tag(Int?.some(2))
            }
            .pickerStyle(.segmented)
        }
    }
}
