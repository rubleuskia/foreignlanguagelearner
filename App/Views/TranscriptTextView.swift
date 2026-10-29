import SwiftUI
import UIKit

enum TranscriptSelectionAction {
    case addToDictionary
    case translateInContext
}

enum TranscriptFollowLayout {
    static func targetOffsetY(lineRect: CGRect, boundsHeight: CGFloat,
                              contentHeight: CGFloat, adjustedTop: CGFloat,
                              adjustedBottom: CGFloat, anchor: CGFloat = 0.5) -> CGFloat? {
        let visibleHeight = boundsHeight - adjustedTop - adjustedBottom
        guard visibleHeight > 0, lineRect.midY.isFinite, contentHeight.isFinite else { return nil }
        let minimum = -adjustedTop
        let maximum = max(minimum, contentHeight - boundsHeight + adjustedBottom)
        let target = lineRect.midY - adjustedTop - visibleHeight * anchor
        return min(max(target, minimum), maximum)
    }

    static func followOffsetY(lineRect: CGRect, currentOffset: CGFloat,
                              boundsHeight: CGFloat, contentHeight: CGFloat,
                              adjustedTop: CGFloat, adjustedBottom: CGFloat,
                              force: Bool) -> CGFloat? {
        let visibleHeight = boundsHeight - adjustedTop - adjustedBottom
        guard visibleHeight > 0 else { return nil }
        let relativeY = lineRect.midY - currentOffset - adjustedTop
        if !force, relativeY >= visibleHeight * 0.35, relativeY <= visibleHeight * 0.60 {
            return nil
        }
        return targetOffsetY(lineRect: lineRect, boundsHeight: boundsHeight,
                             contentHeight: contentHeight, adjustedTop: adjustedTop,
                             adjustedBottom: adjustedBottom, anchor: 0.40)
    }

}

struct TranscriptTextView: UIViewRepresentable {
    let document: TranscriptDocument
    let activeSegment: Int?
    @Binding var following: Bool
    let followGeneration: Int
    let onSelectionBegan: () -> Void
    var fontScale = 1.0
    var unknownWordRanges: [NSRange] = []
    var wordStyleRevision: Int = 0
    var differentiateWithoutColor = false
    var vocabularyIndex: VocabularyTextIndex? = nil
    var knownForms: Set<String> = []
    var wordStyleLanguage: String = ""
    var initialReadingOffset: Int? = nil
    var onReadingOffsetChanged: ((Int) -> Void)? = nil
    let handleSelection: (TranscriptSelectionAction, String, NSRange, Int?, SelectionContext?) -> Void

    static func makeTextView(frame: CGRect = .zero) -> LayoutAwareTextView {
        let storage = NSTextStorage()
        let manager = TranscriptLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        return LayoutAwareTextView(frame: frame, textContainer: container)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> LayoutAwareTextView {
        let view = Self.makeTextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        view.font = ReadingTypography.font(compatibleWith: view.traitCollection)
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 24, left: 24, bottom: 48, right: 24)
        view.accessibilityIdentifier = "reader.transcript"
        view.delegate = context.coordinator
        context.coordinator.apply(to: view)
        view.didLayout = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.restoreReadingPosition(in: view)
            coordinator.applyFollow(to: view)
            coordinator.updateWordStyles(in: view)
        }
        return view
    }

    func updateUIView(_ view: LayoutAwareTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(to: view)
    }

    static func dismantleUIView(_ view: LayoutAwareTextView, coordinator: Coordinator) {
        view.didLayout = nil
        view.setContentOffset(view.contentOffset, animated: false)
        view.delegate = nil
    }

    final class LayoutAwareTextView: UITextView {
        #if DEBUG
        // UI-test telemetry only; production accessibility keeps the native transcript value.
        override var accessibilityValue: String? {
            get {
                if ProcessInfo.processInfo.arguments.contains("--paused-scroll-fixture") {
                    return "offset:\(Int(contentOffset.y))"
                }
                return super.accessibilityValue
            }
            set { super.accessibilityValue = newValue }
        }
        #endif
        var didLayout: (() -> Void)?
        override func layoutSubviews() {
            let margin = max(24, (bounds.width - 680) / 2)
            if textContainerInset.left != margin {
                textContainerInset = UIEdgeInsets(top: 24, left: margin, bottom: 48, right: margin)
            }
            super.layoutSubviews()
            didLayout?()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        struct DocumentIdentity: Equatable {
            let text: String
            let ranges: [NSRange]
            let sourceIndices: [Int]
        }

        struct FollowKey: Equatable {
            let documentRevision: Int
            let activeSegment: Int
            let followGeneration: Int
            let boundsSize: CGSize
            let adjustedInsets: UIEdgeInsets
            let textInsets: UIEdgeInsets
            let contentSizeCategory: UIContentSizeCategory
        }

        var parent: TranscriptTextView
        private(set) var highlighted: Int?
        private(set) var hadNonemptySelection = false
        private(set) var isApplyingProgrammaticUpdate = false
        private var documentIdentity: DocumentIdentity?
        private var documentRevision = 0
        private var lastFollowGeneration: Int
        private var followKey: FollowKey?
        private var appliedWordRevision: Int?
        private var appliedWordRanges: [NSRange] = []
        private var appliedWordUnderline = false
        private var appliedWordLanguage = ""
        private var appliedFontScale: Double?
        private var appliedContentSizeCategory: UIContentSizeCategory?
        private var appliedWindow: NSRange?
        private var appliedIndexIdentity: ObjectIdentifier?
        private var applyingWordStyles = false
        private var applyingFollow = false
        private var wasFollowing: Bool
        private var pendingReadingOffset: Int?

        func resetFollow(in view: UITextView) {
            if !view.isDragging && !view.isDecelerating {
                view.setContentOffset(view.contentOffset, animated: false)
            }
            followKey = nil
        }

        init(_ parent: TranscriptTextView) {
            self.parent = parent
            self.lastFollowGeneration = parent.followGeneration
            self.wasFollowing = parent.following
        }

        func apply(to view: UITextView) {
            if wasFollowing != parent.following {
                resetFollow(in: view)
                wasFollowing = parent.following
            }
            let identity = DocumentIdentity(text: parent.document.text,
                                            ranges: parent.document.ranges,
                                            sourceIndices: parent.document.sourceIndices)
            if identity != documentIdentity {
                resetFollow(in: view)
                isApplyingProgrammaticUpdate = true
                (view.layoutManager as? TranscriptLayoutManager)?.clearDecorations()
                view.text = parent.document.text
                view.selectedRange = NSRange(location: 0, length: 0)
                view.setContentOffset(CGPoint(x: 0, y: -view.adjustedContentInset.top), animated: false)
                isApplyingProgrammaticUpdate = false
                hadNonemptySelection = false
                highlighted = nil
                appliedWordRevision = nil
                appliedContentSizeCategory = nil
                appliedWordRanges = []
                followKey = nil
                documentRevision += 1
                documentIdentity = identity
                pendingReadingOffset = parent.initialReadingOffset
            }

            if parent.followGeneration != lastFollowGeneration {
                isApplyingProgrammaticUpdate = true
                view.setContentOffset(view.contentOffset, animated: false)
                view.selectedRange = NSRange(location: 0, length: 0)
                isApplyingProgrammaticUpdate = false
                hadNonemptySelection = false
                followKey = nil
                lastFollowGeneration = parent.followGeneration
            }

            guard view.selectedRange.length == 0 else { return }
            updateWordStyles(in: view)
            updateHighlight(in: view)
            view.setNeedsLayout()
        }

        func applyFollow(to view: UITextView) {
            guard parent.following, view.selectedRange.length == 0,
                  !view.isDragging, !view.isDecelerating,
                  let active = parent.activeSegment,
                  parent.document.ranges.indices.contains(active) else { return }
            guard !applyingFollow,
                  view.bounds.height > view.adjustedContentInset.top + view.adjustedContentInset.bottom
            else { return }
            applyingFollow = true
            defer { applyingFollow = false }
            let key = FollowKey(documentRevision: documentRevision,
                                activeSegment: active,
                                followGeneration: parent.followGeneration,
                                boundsSize: view.bounds.size,
                                adjustedInsets: view.adjustedContentInset,
                                textInsets: view.textContainerInset,
                                contentSizeCategory: view.traitCollection.preferredContentSizeCategory)
            guard key != followKey else { return }
            guard let lineRect = Self.firstVisualLineRect(
                for: parent.document.ranges[active], in: view
            ) else { return }
            // Measuring a distant cue can extend TextKit's layout before UITextView
            // publishes its new contentSize. Resolve the destination viewport and use
            // that measured extent before clamping or UIKit will stop at the old end.
            let targetViewport = CGRect(x: 0, y: max(0, lineRect.minY - view.textContainerInset.top),
                                        width: view.textContainer.size.width, height: view.bounds.height)
            view.layoutManager.ensureLayout(forBoundingRect: targetViewport, in: view.textContainer)
            let measuredHeight = view.layoutManager.usedRect(for: view.textContainer).maxY
                + view.textContainerInset.top + view.textContainerInset.bottom
            if measuredHeight > view.contentSize.height {
                view.contentSize.height = measuredHeight
            }
            let previous = followKey
            let geometryChanged = previous.map {
                $0.boundsSize != key.boundsSize || $0.adjustedInsets != key.adjustedInsets
                    || $0.textInsets != key.textInsets || $0.contentSizeCategory != key.contentSizeCategory
            } ?? false
            guard let y = TranscriptFollowLayout.followOffsetY(
                lineRect: lineRect, currentOffset: view.contentOffset.y,
                boundsHeight: view.bounds.height, contentHeight: view.contentSize.height,
                adjustedTop: view.adjustedContentInset.top,
                adjustedBottom: view.adjustedContentInset.bottom,
                force: previous == nil || geometryChanged
            ) else {
                followKey = key
                // A newer cue already in the reading zone must not be carried away
                // by an animation still travelling toward the previous cue.
                view.setContentOffset(view.contentOffset, animated: false)
                return
            }
            // Store before scrolling: changing the offset can trigger another layout pass.
            followKey = key
            guard abs(view.contentOffset.y - y) > 1 else { return }
            // UIKit replaces the current scrolling destination rather than queueing moves.
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y),
                                  animated: !UIAccessibility.isReduceMotionEnabled && !geometryChanged)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if let view = scrollView as? UITextView {
                updateWordStyles(in: view)
                guard !isApplyingProgrammaticUpdate, pendingReadingOffset == nil,
                      view.isDragging || view.isDecelerating else { return }
                let point = CGPoint(x: view.textContainerInset.left + 1,
                                    y: view.contentOffset.y + view.adjustedContentInset.top + view.textContainerInset.top + 1)
                if let position = view.closestPosition(to: point) {
                    parent.onReadingOffsetChanged?(view.offset(from: view.beginningOfDocument, to: position))
                }
            }
        }

        func restoreReadingPosition(in view: UITextView) {
            guard let offset = pendingReadingOffset, view.bounds.width > 0, view.bounds.height > 0 else { return }
            pendingReadingOffset = nil
            guard offset > 0, offset < view.textStorage.length,
                  let rect = Self.firstVisualLineRect(for: NSRange(location: offset, length: 1), in: view) else { return }
            isApplyingProgrammaticUpdate = true
            view.layoutManager.ensureLayout(forBoundingRect: CGRect(x: 0, y: rect.minY, width: view.bounds.width, height: view.bounds.height), in: view.textContainer)
            let height = view.layoutManager.usedRect(for: view.textContainer).maxY + view.textContainerInset.top + view.textContainerInset.bottom
            view.contentSize.height = max(view.contentSize.height, height)
            view.setContentOffset(CGPoint(x: 0, y: min(max(0, rect.minY - view.textContainerInset.top), max(0, view.contentSize.height - view.bounds.height))), animated: false)
            isApplyingProgrammaticUpdate = false
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // A drag interrupts UIKit's scroll animation; preserve the user's inertia.
            followKey = nil
            parent.following = false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            let range = textView.selectedRange
            let isNonempty = range.location != NSNotFound && range.length > 0
                && NSMaxRange(range) <= (textView.text as NSString).length
            if isNonempty && !hadNonemptySelection {
                resetFollow(in: textView)
                hadNonemptySelection = true
                parent.following = false
                parent.onSelectionBegan()
            } else if !isNonempty {
                hadNonemptySelection = false
                apply(to: textView)
            }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let selection = Self.validatedExpandedSelection(in: textView.text, selection: range, language: parent.wordStyleLanguage) else {
                return UIMenu(children: suggestedActions)
            }
            let segment = parent.document.ranges.firstIndex {
                NSIntersectionRange($0, selection.range).length > 0
            }
            let selectionContext = Self.context(in: textView.text, selection: selection.range)
            let add = UIAction(title: AppLanguage.text("Add to Dictionary"), image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
                self?.parent.handleSelection(.addToDictionary, selection.text, selection.range,
                                             segment, selectionContext)
            }
            let translate = UIAction(title: AppLanguage.text("Translate in Context"), image: UIImage(systemName: "character.book.closed")) { [weak self] _ in
                self?.parent.handleSelection(.translateInContext, selection.text, selection.range,
                                             segment, selectionContext)
            }
            let copiedText = (textView.text as NSString).substring(with: range)
            let copy = UIAction(title: AppLanguage.text("Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = copiedText
            }
            return UIMenu(children: [translate, add, copy])
        }

        nonisolated static func validatedExpandedSelection(in text: String, selection: NSRange, language: String? = nil)
            -> (range: NSRange, text: String)? {
            let source = text as NSString
            guard selection.location != NSNotFound, selection.length > 0,
                  NSMaxRange(selection) <= source.length,
                  Range(selection, in: text) != nil else { return nil }
            let expanded = WordSelectionExpander.expandedRange(in: text, selection: selection, language: language)
            guard expanded.location != NSNotFound, expanded.length > 0,
                  NSMaxRange(expanded) <= source.length,
                  Range(expanded, in: text) != nil else { return nil }
            return (expanded, source.substring(with: expanded))
        }

        static func firstVisualLineRect(for characterRange: NSRange,
                                        in textView: UITextView) -> CGRect? {
            let textLength = (textView.text as NSString).length
            guard characterRange.location != NSNotFound, characterRange.length > 0,
                  NSMaxRange(characterRange) <= textLength else { return nil }
            let firstCharacter = NSRange(location: characterRange.location, length: 1)
            // Establish real vertical positions through the destination even when
            // noncontiguous layout was enabled by UIKit for a long transcript.
            textView.layoutManager.ensureLayout(forCharacterRange:
                NSRange(location: 0, length: NSMaxRange(firstCharacter)))
            let glyphRange = textView.layoutManager.glyphRange(
                forCharacterRange: firstCharacter, actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return nil }
            var rect = textView.layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphRange.location, effectiveRange: nil
            )
            rect.origin.x += textView.textContainerInset.left
            rect.origin.y += textView.textContainerInset.top
            return rect
        }

        nonisolated static func context(in text: String, selection: NSRange) -> SelectionContext? {
            let source = text as NSString
            guard selection.location != NSNotFound, selection.length > 0,
                  NSMaxRange(selection) <= source.length else { return nil }
            let pattern = #"\.(?:\s+)(?=[\p{Lu}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let separators = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            let previousBoundary = separators.last { $0.range.location < selection.location }
            let nextBoundary = separators.first { $0.range.location >= NSMaxRange(selection) }
            let currentStart = previousBoundary.map { NSMaxRange($0.range) } ?? 0
            let currentEnd = nextBoundary.map { $0.range.location + 1 } ?? source.length
            let earlierBoundary = previousBoundary.flatMap { boundary in
                separators.last { $0.range.location < boundary.range.location }
            }
            let laterBoundary = nextBoundary.flatMap { boundary in
                separators.first { $0.range.location > boundary.range.location }
            }
            let beforeStart = earlierBoundary.map { NSMaxRange($0.range) } ?? 0
            let before = limitedSentence(source.substring(with: NSRange(
                location: beforeStart, length: max(0, currentStart - beforeStart)
            )), fromEnd: true)
            let currentRaw = source.substring(with: NSRange(
                location: currentStart, length: currentEnd - currentStart
            ))
            let leadingWhitespace = (currentRaw as NSString).rangeOfCharacter(
                from: .whitespacesAndNewlines.inverted
            ).location
            let current = currentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let afterStart = nextBoundary.map { NSMaxRange($0.range) } ?? source.length
            let afterEnd = laterBoundary?.range.location ?? source.length
            let after = limitedSentence(source.substring(with: NSRange(
                location: afterStart, length: max(0, afterEnd - afterStart)
            )), fromEnd: false)
            let excerpt = [before, current, after].filter { !$0.isEmpty }.joined(separator: " ")
            let prefixLength = before.isEmpty ? 0 : (before as NSString).length + 1
            let leading = leadingWhitespace == NSNotFound ? 0 : leadingWhitespace
            let relative = NSRange(location: prefixLength + selection.location - currentStart - leading,
                                   length: selection.length)
            guard relative.location >= 0,
                  NSMaxRange(relative) <= (excerpt as NSString).length else { return nil }
            return SelectionContext(text: excerpt, selection: relative)
        }

        func updateWordStyles(in view: UITextView) {
            guard !applyingWordStyles, !isApplyingProgrammaticUpdate, view.selectedRange.length == 0 else { return }
            applyingWordStyles = true
            defer { applyingWordStyles = false }
            let length = view.textStorage.length
            let window: NSRange
            if parent.vocabularyIndex != nil, view.bounds.height > 0 {
                var visible = view.bounds.insetBy(dx: 0, dy: -view.bounds.height * 0.5)
                visible.origin.x -= view.textContainerInset.left
                visible.origin.y -= view.textContainerInset.top
                let glyphs = view.layoutManager.glyphRange(forBoundingRect: visible, in: view.textContainer)
                window = view.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            } else { window = NSRange(location: 0, length: min(length, 8192)) }
            let identity = parent.vocabularyIndex.map(ObjectIdentifier.init)
            let category = view.traitCollection.preferredContentSizeCategory
            guard appliedWordRevision != parent.wordStyleRevision
                    || appliedWordUnderline != parent.differentiateWithoutColor
                    || appliedContentSizeCategory != category || appliedFontScale != parent.fontScale || appliedWindow != window
                    || appliedIndexIdentity != identity || appliedWordLanguage != parent.wordStyleLanguage else { return }
            let ranges = parent.vocabularyIndex?.unknownRanges(in: window, known: parent.knownForms)
                ?? parent.unknownWordRanges
            appliedWindow = window
            appliedIndexIdentity = identity
            isApplyingProgrammaticUpdate = true
            if appliedContentSizeCategory != category || appliedFontScale != parent.fontScale {
                if appliedFontScale != nil, !parent.following, pendingReadingOffset == nil {
                    let point = CGPoint(x: view.textContainerInset.left + 1,
                                        y: view.contentOffset.y + view.adjustedContentInset.top + 1)
                    if let position = view.closestPosition(to: point) {
                        pendingReadingOffset = view.offset(from: view.beginningOfDocument, to: position)
                    }
                }
                followKey = nil
                view.textStorage.addAttributes([
                    .font: ReadingTypography.font(compatibleWith: view.traitCollection, scale: parent.fontScale),
                    .paragraphStyle: ReadingTypography.paragraph(compatibleWith: view.traitCollection)
                ], range: NSRange(location: 0, length: length))
            }
            (view.layoutManager as? TranscriptLayoutManager)?.setWords(ranges, underline: parent.differentiateWithoutColor)
            isApplyingProgrammaticUpdate = false
            appliedWordRanges = ranges
            appliedWordRevision = parent.wordStyleRevision
            appliedWordUnderline = parent.differentiateWithoutColor
            appliedWordLanguage = parent.wordStyleLanguage
            appliedContentSizeCategory = category
            appliedFontScale = parent.fontScale
        }

        private func updateHighlight(in view: UITextView) {
            guard highlighted != parent.activeSegment else { return }
            let range = parent.activeSegment.flatMap { parent.document.ranges.indices.contains($0) ? parent.document.ranges[$0] : nil }
            (view.layoutManager as? TranscriptLayoutManager)?.setActiveRange(range)
            highlighted = parent.activeSegment
        }

        nonisolated private static func limitedSentence(_ sentence: String, fromEnd: Bool) -> String {
            let words = sentence.split(whereSeparator: { $0.isWhitespace })
            guard words.count > 15 else {
                return sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let limited = fromEnd ? words.suffix(15) : words.prefix(15)
            return limited.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
