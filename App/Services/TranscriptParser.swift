import Foundation

enum TranscriptParser {
    enum ParseError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }

    static func parse(_ input: String, extension ext: String) throws -> TranscriptDocument {
        let text = input.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n[ \t]+\n", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.invalid("The transcript is empty.") }
        if ext.lowercased() == "txt" {
            return TranscriptDocument(segments: [.init(start: nil, end: nil, text: text)])
        }
        guard ["srt", "vtt"].contains(ext.lowercased()) else {
            throw ParseError.invalid("Choose an SRT, WebVTT, or TXT transcript.")
        }
        var segments: [TranscriptSegment] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            if let first = lines.first, first == "WEBVTT" || first.hasPrefix("WEBVTT ") || first.hasPrefix("NOTE") || first == "STYLE" || first == "REGION" { continue }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else {
                if block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                throw ParseError.invalid("A subtitle segment is missing timestamps.")
            }
            let times = lines[timing].components(separatedBy: "-->")
            guard times.count == 2,
                  let start = timestamp(times[0].trimmingCharacters(in: .whitespaces)),
                  let endToken = times[1].split(whereSeparator: \.isWhitespace).first,
                  let end = timestamp(String(endToken)), end > start else {
                throw ParseError.invalid("A subtitle segment has invalid timestamps.")
            }
            let body = lines.dropFirst(timing + 1).joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw ParseError.invalid("A subtitle segment has no text.") }
            segments.append(.init(start: start, end: end, text: body))
        }
        guard !segments.isEmpty else { throw ParseError.invalid("No subtitle segments were found.") }
        return TranscriptDocument(segments: segments.sorted { $0.start! < $1.start! })
    }

    static func timestamp(_ value: String) -> Double? {
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let seconds = Double(parts.last!), seconds.isFinite, seconds >= 0, seconds < 60,
              let minutes = Int(parts[parts.count - 2]), minutes >= 0, minutes < 60 else { return nil }
        let hours = parts.count == 3 ? Int(parts[0]) : 0
        guard let hours, hours >= 0 else { return nil }
        return Double(hours) * 3600 + Double(minutes) * 60 + seconds
    }
}
