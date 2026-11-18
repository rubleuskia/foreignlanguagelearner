import SwiftUI

/// A wrapping row for the source text and its editable inline fields.
struct ExamInlineFlow: Layout {
    var spacing: CGFloat = 2
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = positions(width: proposal.width ?? 600, subviews: subviews)
        return CGSize(width: proposal.width ?? result.width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = positions(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + result.points[index].x, y: bounds.minY + result.points[index].y),
                anchor: .topLeading, proposal: ProposedViewSize(result.sizes[index]))
        }
    }

    private func positions(width proposedWidth: CGFloat, subviews: Subviews) -> FlowResult {
        let width = max(1, proposedWidth)
        var result = FlowResult(points: Array(repeating: .zero, count: subviews.count),
                                sizes: Array(repeating: .zero, count: subviews.count))
        var row: [Int] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        func finishRow() {
            for index in row {
                result.points[index].y = y + (rowHeight - result.sizes[index].height) / 2
            }
            if !row.isEmpty { y += rowHeight + lineSpacing }
            row = []; x = 0; rowHeight = 0
        }
        for index in subviews.indices {
            if subviews[index][ExamLineBreak.self] { finishRow(); result.points[index] = CGPoint(x: 0, y: y); continue }
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width { size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width { finishRow() }
            result.sizes[index] = size
            result.points[index] = CGPoint(x: x, y: y)
            row.append(index)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            result.width = max(result.width, min(width, x - spacing))
        }
        finishRow()
        result.height = max(0, y - (subviews.isEmpty ? 0 : lineSpacing))
        return result
    }

    private struct FlowResult {
        var points: [CGPoint]
        var sizes: [CGSize]
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

private struct ExamLineBreak: LayoutValueKey { static let defaultValue = false }

struct ExamFlowBreak: View {
    var body: some View { Color.clear.frame(width: 0, height: 0).layoutValue(key: ExamLineBreak.self, value: true) }
}

struct ExamSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1) }
    }
}

struct ExamPaperText: View {
    let text: String
    var underlined: String?
    var body: some View { Text(attributed).font(.system(.body, design: .serif)).lineSpacing(5).textSelection(.enabled) }
    private var attributed: AttributedString {
        var value = AttributedString(text)
        if let underlined, let range = value.range(of: underlined) { value[range].underlineStyle = .single }
        return value
    }
}

enum ExamDisplay {
    static func points(_ units: Int) -> String {
        (Double(units) / 100).formatted(.number.precision(.fractionLength(0...2)))
    }
    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    static func title(_ sectionID: String) -> String {
        switch sectionID {
        case "listening": "Rozumienie ze słuchu"
        case "reading": "Rozumienie tekstów pisanych"
        case "grammar": "Poprawność gramatyczna"
        default: sectionID
        }
    }
    static func icon(_ sectionID: String) -> String {
        switch sectionID {
        case "listening": "headphones"
        case "reading": "text.book.closed"
        case "grammar": "character.book.closed"
        default: "doc.text"
        }
    }
}

struct ExamInlinePiece: Identifiable {
    enum Kind { case word(String), field(String), example(String), lineBreak }
    let id: Int
    let kind: Kind
    static func parse(_ text: String) -> [Self] {
        guard let pattern = try? NSRegularExpression(pattern: #"\{\{([^}]+)\}\}|\[PRZYKŁAD:\s*([^\]]+)\]"#) else { return [] }
        let source = text as NSString
        var pieces: [Self] = []
        var cursor = 0
        func append(_ kind: Kind) { pieces.append(Self(id: pieces.count, kind: kind)) }
        func words(_ text: String) {
            let lines = text.components(separatedBy: "\n")
            for (lineIndex, line) in lines.enumerated() {
                if lineIndex > 0 { append(.lineBreak) }
                for word in line.split(whereSeparator: \.isWhitespace) { append(.word(String(word))) }
            }
        }
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            words(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            if match.range(at: 1).location != NSNotFound { append(.field(source.substring(with: match.range(at: 1)))) }
            else { append(.example(source.substring(with: match.range(at: 2)))) }
            cursor = NSMaxRange(match.range)
        }
        words(source.substring(from: cursor))
        return pieces
    }
}
