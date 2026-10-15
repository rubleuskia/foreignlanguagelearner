import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticLogFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ExportLogsButton: View {
    @State private var document: DiagnosticLogFile?
    @State private var exporting = false
    @State private var preparing = false
    @State private var errorMessage: String?

    var body: some View {
        Button("Export logs", systemImage: "square.and.arrow.up") {
            preparing = true
            Task {
                defer { preparing = false }
                do {
                    document = DiagnosticLogFile(data: try await DiagnosticLog.shared.export())
                    exporting = true
                } catch { errorMessage = error.localizedDescription }
            }
        }
        .disabled(preparing)
        .accessibilityIdentifier("diagnostics.export-logs")
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "language-learner-logs.json") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            document = nil
        }
        .alert("Could not export logs", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }
}
