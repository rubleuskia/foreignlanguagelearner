import SwiftUI
import UIKit

/// Page ranges use the original document's UTF-16 offsets. Replacing subtitle
/// newlines with spaces keeps selections, vocabulary and audio timing aligned.
enum BookTextPagination {
    nonisolated static func readingText(_ document: TranscriptDocument) -> String {
        guard document.segments.contains(where: { $0.start != nil }) else { return document.text }
        return document.text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    nonisolated static func ranges(text: String, size: CGSize, scale: Double,
                                   category: String) throws -> [NSRange] {
        let margin = max(24, (size.width - 680) / 2)
        let available = CGSize(width: size.width - margin * 2, height: size.height - 72)
        guard available.width > 10, available.height > 10 else { return [] }
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(rawValue: category))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ReadingTypography.font(compatibleWith: traits, scale: scale),
            .paragraphStyle: ReadingTypography.paragraph(compatibleWith: traits)
        ]
        let source = text as NSString
        var result: [NSRange] = []
        var offset = 0
        while offset < source.length {
            try Task.checkCancellation()
            // Bound temporary text storage even for an imported full-length book.
            var count = min(8192, source.length - offset)
            var consumed = 0
            repeat {
                let chunk = source.rangeOfComposedCharacterSequences(for:
                    NSRange(location: offset, length: count))
                let storage = NSTextStorage(string: source.substring(with: chunk), attributes: attributes)
                let manager = NSLayoutManager()
                let container = NSTextContainer(size: available)
                storage.addLayoutManager(manager)
                manager.addTextContainer(container)
                manager.ensureLayout(for: container)
                let glyphs = manager.glyphRange(for: container)
                consumed = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).length
                if consumed < chunk.length || NSMaxRange(chunk) == source.length { break }
                count = min(count * 2, source.length - offset)
            } while true
            guard consumed > 0 else { return result }
            result.append(NSRange(location: offset, length: consumed))
            offset += consumed
        }
        return result
    }

    nonisolated static func page(containing offset: Int, ranges: [NSRange]) -> Int {
        ranges.firstIndex(where: { NSLocationInRange(offset, $0) }) ?? max(0, ranges.count - 1)
    }
}

extension TranscriptDocument {
    init(pageOf document: TranscriptDocument, text: String, range: NSRange) {
        self.text = (text as NSString).substring(with: range)
        let indices = document.ranges.indices.filter {
            NSIntersectionRange(document.ranges[$0], range).length > 0
        }
        segments = indices.map { document.segments[$0] }
        sourceIndices = indices.map { document.sourceIndices[$0] }
        ranges = indices.map {
            let overlap = NSIntersectionRange(document.ranges[$0], range)
            return NSRange(location: overlap.location - range.location, length: overlap.length)
        }
        wordTimings = [] // Audio actions resolve against the full source document.
    }
}

struct BookPagedTranscriptView: View {
    let reader: TranscriptTextView
    @Environment(\.sizeCategory) private var sizeCategory
    @State private var pages: [NSRange] = []
    @State private var displayedText = ""
    @State private var page = 0
    @State private var readingOffset = 0
    @State private var sourceText: String?

    private struct LayoutKey: Equatable {
        let text: String
        let timed: Bool
        let size: CGSize
        let scale: Double
        let category: ContentSizeCategory
    }

    var body: some View {
        GeometryReader { geometry in
            let pageSize = CGSize(width: geometry.size.width, height: max(0, geometry.size.height - 36))
            let key = LayoutKey(text: reader.document.text,
                                timed: reader.document.segments.contains { $0.start != nil },
                                size: pageSize, scale: reader.fontScale, category: sizeCategory)
            VStack(spacing: 0) {
                if pages.isEmpty || sourceText != reader.document.text {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TabView(selection: Binding(get: { page }, set: { move(to: $0) })) {
                        ForEach(pages.indices, id: \.self) { index in
                            Group {
                                if abs(index - page) <= 1 { pageView(index) }
                                else { Color.clear }
                            }.tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: pageSize.height)
                    .accessibilityIdentifier("reader.pages")
                    HStack {
                        Button { move(to: page - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(page == 0)
                            .accessibilityLabel("Previous page")
                        Spacer()
                        Text("\(page + 1) / \(pages.count)")
                            .monospacedDigit()
                            .accessibilityIdentifier("reader.page-number")
                        Spacer()
                        Button { move(to: page + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(page >= pages.count - 1)
                            .accessibilityLabel("Next page")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).frame(height: 36)
                }
            }
            .task(id: key) {
                let text = BookTextPagination.readingText(reader.document)
                let category = uiCategory.rawValue
                let work = Task.detached(priority: .userInitiated) {
                    try BookTextPagination.ranges(text: text, size: key.size,
                                                  scale: key.scale, category: category)
                }
                do {
                    let result = try await withTaskCancellationHandler(operation: { try await work.value },
                                                                       onCancel: { work.cancel() })
                    try Task.checkCancellation()
                    if sourceText != key.text { readingOffset = reader.initialReadingOffset ?? 0 }
                    displayedText = text
                    sourceText = key.text
                    pages = result
                    page = BookTextPagination.page(containing: readingOffset, ranges: result)
                    followAudio()
                } catch { /* A newer document or geometry superseded this layout. */ }
            }
            .onChange(of: reader.activeSegment) { _, _ in followAudio() }
            .onChange(of: reader.followGeneration) { _, _ in followAudio(force: true) }
            .onChange(of: reader.following) { _, value in if value { followAudio(force: true) } }
        }
    }

    private func pageView(_ index: Int) -> some View {
        let range = pages[index]
        let document = TranscriptDocument(pageOf: reader.document, text: displayedText, range: range)
        let active = reader.activeSegment.flatMap { segment in
            reader.document.sourceIndices.indices.contains(segment)
                ? document.sourceIndices.firstIndex(of: reader.document.sourceIndices[segment]) : nil
        }
        let unknown = reader.vocabularyIndex?.unknownRanges(in: range, known: reader.knownForms)
            ?? reader.unknownWordRanges
        return TranscriptTextView(document: document, activeSegment: active,
            following: reader.$following, followGeneration: reader.followGeneration,
            onSelectionBegan: reader.onSelectionBegan, fontScale: reader.fontScale, isBookPage: true,
            unknownWordRanges: unknown.compactMap {
                let overlap = NSIntersectionRange($0, range)
                return overlap.length > 0 ? NSRange(location: overlap.location - range.location,
                                                    length: overlap.length) : nil
            }, wordStyleRevision: reader.wordStyleRevision,
            differentiateWithoutColor: reader.differentiateWithoutColor,
            wordStyleLanguage: reader.wordStyleLanguage) { action, text, local, _, _ in
                let full = NSRange(location: local.location + range.location, length: local.length)
                let segment = reader.document.ranges.firstIndex { NSIntersectionRange($0, full).length > 0 }
                reader.handleSelection(action, text, full, segment,
                    TranscriptTextView.Coordinator.context(in: reader.document.text, selection: full))
            }
    }

    private func move(to destination: Int) {
        guard pages.indices.contains(destination), destination != page else { return }
        reader.following = false
        page = destination
        readingOffset = pages[destination].location
        reader.onReadingOffsetChanged?(readingOffset)
    }

    private func followAudio(force: Bool = false) {
        guard reader.following, sourceText == reader.document.text,
              let segment = reader.activeSegment, reader.document.ranges.indices.contains(segment),
              !pages.isEmpty else { return }
        let cue = reader.document.ranges[segment]
        // If a cue spans two pages, allow its continuation to stay on screen.
        if !force, pages.indices.contains(page), NSIntersectionRange(pages[page], cue).length > 0 { return }
        page = BookTextPagination.page(containing: cue.location, ranges: pages)
        readingOffset = cue.location
    }

    private var uiCategory: UIContentSizeCategory {
        switch sizeCategory {
        case .extraSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .extraLarge: .extraLarge
        case .extraExtraLarge: .extraExtraLarge
        case .extraExtraExtraLarge: .extraExtraExtraLarge
        case .accessibilityMedium: .accessibilityMedium
        case .accessibilityLarge: .accessibilityLarge
        case .accessibilityExtraLarge: .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
