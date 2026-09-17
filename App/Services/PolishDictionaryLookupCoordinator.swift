import Foundation
import Observation
import SwiftData

enum PolishDictionaryLookupState: Equatable {
    case idle
    case loading
    case choosingLemma([String])
    case failed(String)
}

@MainActor @Observable
final class PolishDictionaryLookupCoordinator {
    private let provider: any PolishDictionaryProviding
    private var states: [String: PolishDictionaryLookupState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(provider: any PolishDictionaryProviding = PolishWiktionaryClient()) {
        self.provider = provider
    }

    func state(for word: String) -> PolishDictionaryLookupState {
        states[key(for: word)] ?? .idle
    }

    func lookup(_ word: String, lemma: String? = nil, for entry: DictionaryEntry, context: ModelContext) {
        let lookupKey = key(for: word)
        tasks[lookupKey]?.cancel()
        states[lookupKey] = .loading
        tasks[lookupKey] = Task { [provider] in
            do {
                let result = try await provider.lookup(word, preferredLemma: lemma)
                try Task.checkCancellation()
                let originalItems = entry.wordHelpItems
                var items = entry.wordHelpItems
                var changed = false
                for index in items.indices where key(for: items[index].sourceText) == lookupKey {
                    items[index].polishDictionaryResult = result
                    changed = true
                }
                guard changed else { return }
                entry.wordHelpItems = items
                do { try context.save() }
                catch {
                    entry.wordHelpItems = originalItems
                    throw error
                }
                states[lookupKey] = .idle
            } catch is CancellationError {
                states[lookupKey] = .idle
            } catch PolishWiktionaryError.ambiguousLemmas(let lemmas) {
                states[lookupKey] = .choosingLemma(lemmas)
            } catch {
                states[lookupKey] = .failed(error.localizedDescription)
            }
            tasks[lookupKey] = nil
        }
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func key(for word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
    }
}
