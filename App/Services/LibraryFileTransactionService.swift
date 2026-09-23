import Foundation
import SwiftData

struct LibraryDeleteTransaction: Codable, Sendable {
    let transactionID: UUID
    let itemID: UUID

    static var trashRoot: URL { URL.applicationSupportDirectory.appending(path: "LibraryTrash", directoryHint: .isDirectory) }
    static var journalRoot: URL { URL.applicationSupportDirectory.appending(path: "DeleteJournals", directoryHint: .isDirectory) }
    var trashURL: URL { Self.trashRoot.appending(path: transactionID.uuidString, directoryHint: .isDirectory) }
    var journalURL: URL { Self.journalRoot.appending(path: "\(transactionID.uuidString).json") }
}
enum LibraryFileTransactionService {
    static func beginDelete(itemID: UUID, fileManager: FileManager = .default) throws -> LibraryDeleteTransaction {
        let transaction = LibraryDeleteTransaction(transactionID: UUID(), itemID: itemID)
        try fileManager.createDirectory(at: LibraryDeleteTransaction.trashRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: LibraryDeleteTransaction.journalRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transaction).write(to: transaction.journalURL, options: [.atomic, .completeFileProtection])
        let source = MediaImportService.directory(for: itemID)
        if fileManager.fileExists(atPath: source.path) {
            try fileManager.moveItem(at: source, to: transaction.trashURL)
        }
        return transaction
    }

    static func rollback(_ transaction: LibraryDeleteTransaction, fileManager: FileManager = .default) {
        let destination = MediaImportService.directory(for: transaction.itemID)
        if fileManager.fileExists(atPath: transaction.trashURL.path),
           !fileManager.fileExists(atPath: destination.path) {
            try? fileManager.moveItem(at: transaction.trashURL, to: destination)
        }
        try? fileManager.removeItem(at: transaction.journalURL)
    }

    static func complete(_ transaction: LibraryDeleteTransaction, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: transaction.trashURL)
        try? fileManager.removeItem(at: transaction.journalURL)
    }
}

@MainActor
enum LibraryRecoveryService {
    static func recover(context: ModelContext, fileManager: FileManager = .default) throws {
        try recoverImports(context: context, fileManager: fileManager)
        try recoverDeletes(context: context, fileManager: fileManager)
    }

    private static func recoverImports(context: ModelContext, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: ImportJournal.root.path) else { return }
        let decoder = JSONDecoder()
        for url in try fileManager.contentsOfDirectory(at: ImportJournal.root,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) where url.pathExtension == "json" {
            guard let filenameID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let journal = try? decoder.decode(ImportJournal.self, from: Data(contentsOf: url)),
                  journal.transactionID == filenameID else { continue }
            let itemID = journal.itemID
            let exists = try context.fetchCount(FetchDescriptor<LearningItem>(predicate: #Predicate { $0.id == itemID })) > 0
            let final = MediaImportService.directory(for: itemID)
            let staging = BookImportService.stagingRoot.appending(path: journal.transactionID.uuidString)
            if exists {
                guard fileManager.fileExists(atPath: final.path) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "A recovered library record is missing its book files. Keep the database for repair."])
                }
            } else if fileManager.fileExists(atPath: final.path) {
                try fileManager.removeItem(at: final)
            }
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: url)
        }
    }

    private static func recoverDeletes(context: ModelContext, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: LibraryDeleteTransaction.journalRoot.path) else { return }
        let decoder = JSONDecoder()
        for url in try fileManager.contentsOfDirectory(at: LibraryDeleteTransaction.journalRoot,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) where url.pathExtension == "json" {
            guard let filenameID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let transaction = try? decoder.decode(LibraryDeleteTransaction.self, from: Data(contentsOf: url)),
                  transaction.transactionID == filenameID else { continue }
            let itemID = transaction.itemID
            let exists = try context.fetchCount(FetchDescriptor<LearningItem>(predicate: #Predicate { $0.id == itemID })) > 0
            if exists { LibraryFileTransactionService.rollback(transaction, fileManager: fileManager) }
            else { LibraryFileTransactionService.complete(transaction, fileManager: fileManager) }
        }
    }
}
