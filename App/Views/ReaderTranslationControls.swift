import SwiftUI

struct ReaderTranslationControls: View {
    @Bindable var coordinator: BookAutoTranslationCoordinator
    @AppStorage("reader.highlight-new-words") private var highlights = true
    @AppStorage("reader.text-layout") private var layout = ReaderTextLayout.pages.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text("Auto translate").accessibilityHidden(true)
                    Toggle("Auto translate", isOn: Binding(get: { coordinator.enabled }, set: { coordinator.setEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).fixedSize()
                        .disabled(layout != ReaderTextLayout.pages.rawValue)
                        .accessibilityIdentifier("reader.auto-translate")
                }
                Spacer(minLength: 0)
                if coordinator.pendingCount > 0 {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Translating page…")
                }
                Button { highlights.toggle() } label: {
                    Image(systemName: "highlighter")
                        .foregroundStyle(highlights ? Color.accentColor : Color.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("New words")
                .accessibilityValue(highlights ? "On" : "Off")
                .accessibilityIdentifier("reader.new-words")
                Menu {
                    Picker("Text layout", selection: $layout) {
                        ForEach(ReaderTextLayout.allCases, id: \.rawValue) { value in
                            Text(AppLanguage.text(value.title)).tag(value.rawValue)
                                .accessibilityIdentifier("reader.layout.\(value.rawValue)")
                        }
                    }
                } label: {
                    Image(systemName: layout == ReaderTextLayout.pages.rawValue ? "book.pages" : "text.alignleft")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Reading layout")
                .accessibilityIdentifier("reader.text-layout")
            }
            .font(.caption).padding(.horizontal, 16).frame(minHeight: 44)
            if let error = coordinator.errorMessage {
                HStack {
                    Text(AppLanguage.text(error)).font(.caption).lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Retry", systemImage: "arrow.clockwise") { coordinator.retry() }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("reader.retry-auto-translation")
                }.padding(.horizontal, 16)
            }
            Divider()
        }
        .onChange(of: layout) { _, value in
            if value != ReaderTextLayout.pages.rawValue { coordinator.leavePages() }
        }
        .onAppear {
            if layout != ReaderTextLayout.pages.rawValue { coordinator.leavePages() }
        }
        .alert("Translations in progress", isPresented: $coordinator.showBlockedPopup) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Translations are still running. Wait until they finish or turn off Auto translate to turn the page.")
        }
    }
}
