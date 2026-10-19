import Foundation

/// Immutable, compact occurrence index. Repeated words share a single string; range lookup is
/// logarithmic and only visible occurrences are tested against the current knowledge snapshot.
final class VocabularyTextIndex: Sendable {
    struct Position: Sendable {
        let start: Int
        let length: Int
        let formID: Int
    }
    let forms: [String]
    let positions: [Position]
    let uniqueForms: Set<String>
    let utf16Length: Int

    init(forms: [String], positions: [Position], utf16Length: Int) {
        self.forms = forms; self.positions = positions; self.utf16Length = utf16Length
        uniqueForms = Set(forms)
    }

    func unknownRanges(in range: NSRange, known: Set<String>, limit: Int = 4096) -> [NSRange] {
        guard range.length > 0 else { return [] }
        var lower = 0, upper = positions.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if positions[mid].start + positions[mid].length <= range.location { lower = mid + 1 }
            else { upper = mid }
        }
        var result: [NSRange] = []
        var cursor = lower
        while cursor < positions.count, positions[cursor].start < NSMaxRange(range), result.count < limit {
            let position = positions[cursor]
            if !known.contains(forms[position.formID]) { result.append(.init(location: position.start, length: position.length)) }
            cursor += 1
        }
        return result
    }

    private struct Cache: Codable {
        let forms: [String]
        let positions: Data
        let length: Int
    }

    /// Cache failures are disposable: tokenization still succeeds if disk is full or cache was purged.
    static func load(text: String, directory: URL? = defaultDirectory) throws -> VocabularyTextIndex {
        try Task.checkCancellation()
        let key = VocabularyIndex.digest("positions-v1-tokenizer\(VocabularyTokenizer.version):" + text)
        let url = directory?.appending(path: key + ".plist")
        if let url, let bytes = try? Data(contentsOf: url),
           let cache = try? PropertyListDecoder().decode(Cache.self, from: bytes),
           cache.length == text.utf16.count, cache.positions.count % 12 == 0 {
            let raw = [UInt8](cache.positions)
            func number(_ offset: Int) -> Int {
                Int(raw[offset]) | Int(raw[offset + 1]) << 8 | Int(raw[offset + 2]) << 16 | Int(raw[offset + 3]) << 24
            }
            var positions: [Position] = []
            var previousEnd = 0
            var valid = true
            for offset in stride(from: 0, to: raw.count, by: 12) {
                if offset % 12288 == 0 { try Task.checkCancellation() }
                let start = number(offset), length = number(offset + 4), id = number(offset + 8)
                guard start >= previousEnd, length > 0, start + length <= cache.length, cache.forms.indices.contains(id) else { valid = false; break }
                positions.append(.init(start: start, length: length, formID: id)); previousEnd = start + length
            }
            if valid { return .init(forms: cache.forms, positions: positions, utf16Length: cache.length) }
        }
        let result = try VocabularyTokenizer.textIndex(in: text)
        try Task.checkCancellation()
        if let url, let directory {
            var bytes = Data(capacity: result.positions.count * 12)
            for position in result.positions {
                for value in [position.start, position.length, position.formID] {
                    var little = UInt32(value).littleEndian
                    withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
                }
            }
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            if let data = try? encoder.encode(Cache(forms: result.forms, positions: bytes, length: result.utf16Length)) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
                prune(directory, keeping: url)
            }
        }
        return result
    }

    static var defaultDirectory: URL { URL.cachesDirectory.appending(path: "VocabularyPositions-v1") }

    private static func prune(_ directory: URL, keeping: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(0) { $0 + $1.1 }
        for (url, count, _) in entries where size > 128 * 1024 * 1024 && url != keeping {
            if (try? FileManager.default.removeItem(at: url)) != nil { size -= count }
        }
    }
}
