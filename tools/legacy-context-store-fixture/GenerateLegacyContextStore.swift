import Darwin
import Foundation
import SwiftData

private enum Fixture {
    static let learningItemID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let dictionaryEntryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let generatedAt = Date(timeIntervalSince1970: 1_700_000_100)
}

@main
enum GenerateLegacyContextStore {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: generator OUTPUT_DIRECTORY\n".utf8))
            exit(64)
        }

        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "fll-legacy-context-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceStore = temporaryDirectory.appending(path: "LegacyContext.store")

        try autoreleasepool {
            let container = try ModelContainer(
                for: LearningItem.self, DictionaryEntry.self,
                configurations: ModelConfiguration(url: sourceStore)
            )
            let item = LearningItem(
                id: Fixture.learningItemID,
                title: "Legacy fixture story",
                mediaKind: "audio",
                mediaFilename: "legacy.m4a",
                transcriptFilename: "legacy.srt",
                duration: 90,
                segments: [.init(start: 12, end: 16, text: "Zepsuł się zamek w kurtce.")],
                parts: [.init(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                              start: 0, end: 90, isCompleted: false, lastPosition: 37)],
                sourceLanguageCode: "pl",
                tracks: [.init(id: "chapter-1", title: "Chapter 1", mediaFilename: "audio/chapter-1.m4a",
                               subtitleFilename: "text/chapter-1.srt", duration: 90,
                               alignmentStatus: .aligned, lastPosition: 37, isCompleted: false)],
                lastTrackID: "chapter-1"
            )
            item.createdAt = Fixture.createdAt
            item.lastPosition = 37

            let entry = DictionaryEntry(
                text: "zamek", item: item, segmentIndex: 0,
                context: SelectionContext(text: "Zepsuł się zamek w kurtce.",
                                          selection: NSRange(location: 11, length: 5)),
                audioStart: 12, audioEnd: 16, sourceTrackID: "chapter-1"
            )
            entry.id = Fixture.dictionaryEntryID
            entry.createdAt = Fixture.createdAt
            entry.translationText = "молния"
            entry.translationOrigin = .manual
            entry.translationStatus = .ready
            entry.translationUpdatedAt = Fixture.generatedAt
            entry.translationRevision = 4
            entry.learningLevel = 3
            entry.contextSelectedTranslationText = "молния"
            entry.contextTranslationText = "На куртке сломалась молния."
            entry.contextAnalysisUpdatedAt = Fixture.generatedAt
            entry.contextAnalysisRevision = 6
            entry.wordHelpItems = [
                .init(sourceText: "kurtce", translationText: "куртке", isGrammarWord: false,
                      polishDictionaryResult: .init(
                        requestedWord: "kurtce", headword: "kurtka", resolvedFromForm: "kurtce",
                        partOfSpeech: "rzeczownik",
                        meanings: [.init(id: "1.1", definition: "część ubrania",
                                         examples: ["Założyła kurtkę."], usageLabels: [])],
                        sourceURL: "https://pl.wiktionary.org/wiki/kurtka", revisionID: 42,
                        fetchedAt: Fixture.generatedAt
                      ))
            ]
            entry.wordHelpUpdatedAt = Fixture.generatedAt
            entry.selectedSenseText = "молния на одежде"
            entry.userNote = "Не замок-здание."

            container.mainContext.insert(item)
            container.mainContext.insert(entry)
            try container.mainContext.save()
        }

        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("LegacyContext.store") }
        guard !sourceFiles.isEmpty else { throw CocoaError(.fileNoSuchFile) }

        if FileManager.default.fileExists(atPath: outputDirectory.path) {
            try FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for source in sourceFiles {
            try FileManager.default.copyItem(at: source,
                                             to: outputDirectory.appending(path: source.lastPathComponent))
        }
    }
}
