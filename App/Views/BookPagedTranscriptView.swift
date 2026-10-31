import SwiftUI
import UIKit
import NaturalLanguage

/// Page ranges use the original document's UTF-16 offsets. Replacing subtitle
/// newlines with spaces keeps selections, vocabulary and audio timing aligned.
enum BookTextPagination {
    nonisolated static func phrases(in document: TranscriptDocument) -> [NSRange] {
        if document.segments.contains(where: { $0.start != nil }) { return document.ranges }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = document.text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: document.text.startIndex..<document.text.endIndex) { range, _ in
            ranges.append(NSRange(range, in: document.text))
            return true
        }
        return ranges
    }
    nonisolated static func readingText(_ document: TranscriptDocument) -> String {
        guard document.segments.contains(where: { $0.start != nil }) else { return document.text }
        return document.text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    nonisolated static func ranges(text: String, size: CGSize, scale: Double,
                                   category: String, phrases: [NSRange] = []) throws -> [NSRange] {
        let margin = max(24, (size.width - 680) / 2)
        let available = CGSize(width: size.width - margin * 2, height: size.height - 32)
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
            if consumed == 0 {
                // At very large accessibility sizes even one line may exceed
                // the viewport. Keep the next phrase accessible via overflow.
                consumed = phrases.first(where: { NSMaxRange($0) > offset })
                    .map { NSMaxRange($0) - offset } ?? (source.length - offset)
            }
            let proposedEnd = offset + consumed
            if let phrase = phrases.first(where: {
                $0.location < proposedEnd && NSMaxRange($0) > proposedEnd
            }) {
                // Move a whole cue to the next page. An oversized cue gets its
                // own scrollable page rather than losing its audio ownership.
                let prefix = source.substring(with: NSRange(location: offset,
                    length: max(0, phrase.location - offset)))
                consumed = phrase.location > offset && !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? phrase.location - offset : NSMaxRange(phrase) - offset
            }
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
    var onFollowAudio: (() -> Void)? = nil
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var pages: [NSRange] = []
    @State private var displayedText = ""
    @State private var page = 0
    @State private var readingOffset = 0
    @State private var sourceText: String?
    @State private var layoutRevision = 0

    private struct LayoutKey: Equatable {
        let text: String
        let timed: Bool
        let size: CGSize
        let scale: Double
        let category: ContentSizeCategory
    }

    var body: some View {
        GeometryReader { geometry in
            let showsFollow = onFollowAudio != nil && reader.document.segments.contains { $0.start != nil }
            let footerHeight: CGFloat = showsFollow && verticalSizeClass != .compact ? 68 : 24
            let pageSize = CGSize(width: geometry.size.width, height: max(0, geometry.size.height - footerHeight))
            let key = LayoutKey(text: reader.document.text,
                                timed: reader.document.segments.contains { $0.start != nil },
                                size: pageSize, scale: reader.fontScale, category: sizeCategory)
            VStack(spacing: 0) {
                if pages.isEmpty || sourceText != reader.document.text {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    StableBookPager(count: pages.count, selection: page,
                        revision: .init(active: reader.activeSegment, words: reader.wordStyleRevision,
                            index: reader.vocabularyIndex.map(ObjectIdentifier.init),
                            follow: reader.followGeneration, following: reader.following,
                            underline: reader.differentiateWithoutColor),
                        makePage: { pageView($0) },
                        onManualStart: { reader.following = false },
                        onSelection: { move(to: $0) })
                    .id(layoutRevision)
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
                        if showsFollow, verticalSizeClass == .compact {
                            Spacer()
                            followButton
                        }
                        Spacer()
                        Button { move(to: page + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(page >= pages.count - 1)
                            .accessibilityLabel("Next page")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).frame(height: 24)
                    if showsFollow, verticalSizeClass != .compact {
                        followButton.frame(height: 44)
                    }
                }
            }
            .task(id: key) {
                let text = BookTextPagination.readingText(reader.document)
                let category = uiCategory.rawValue
                let document = reader.document
                let work = Task.detached(priority: .userInitiated) {
                    try BookTextPagination.ranges(text: text, size: key.size,
                                                  scale: key.scale, category: category,
                                                  phrases: BookTextPagination.phrases(in: document))
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
                    layoutRevision += 1
                } catch { /* A newer document or geometry superseded this layout. */ }
            }
            .onChange(of: reader.activeSegment) { _, _ in followAudio() }
            .onChange(of: reader.followGeneration) { _, _ in followAudio(force: true) }
            .onChange(of: reader.following) { _, value in if value { followAudio(force: true) } }
        }
    }

    private var followButton: some View {
        Button("Follow audio", systemImage: "arrow.down.to.line") { onFollowAudio?() }
            .nativeSecondaryAction()
            .opacity(reader.following ? 0 : 1)
            .allowsHitTesting(!reader.following)
            .accessibilityHidden(reader.following)
    }

    private func pageView(_ index: Int) -> TranscriptTextView {
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
            allowsPageOverflow: true,
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
        let destination = BookTextPagination.page(containing: cue.location, ranges: pages)
        if !force, page == destination { return }
        page = destination
        readingOffset = cue.location
        reader.onReadingOffsetChanged?(readingOffset)
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
