import SwiftUI
import UIKit

enum TranscriptSelectionAction {
    case addToDictionary
    case translateInContext
}

enum TranscriptFollowLayout {
    static func targetOffsetY(lineRect: CGRect, boundsHeight: CGFloat,
                              contentHeight: CGFloat, adjustedTop: CGFloat,
                              adjustedBottom: CGFloat) -> CGFloat? {
        let visibleHeight = boundsHeight - adjustedTop - adjustedBottom
        guard visibleHeight > 0, lineRect.midY.isFinite, contentHeight.isFinite else { return nil }
        let minimum = -adjustedTop
        let maximum = max(minimum, contentHeight - boundsHeight + adjustedBottom)
        let target = lineRect.midY - adjustedTop - visibleHeight / 2
        return min(max(target, minimum), maximum)
    }
}

struct TranscriptTextView: UIViewRepresentable {
    let document: TranscriptDocument
    let activeSegment: Int?
    @Binding var following: Bool
    let followGeneration: Int
    let onSelectionBegan: () -> Void
    let handleSelection: (TranscriptSelectionAction, String, NSRange, Int?, SelectionContext?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> LayoutAwareTextView {
        let view = LayoutAwareTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 40, right: 16)
        view.accessibilityIdentifier = "reader.transcript"
        view.delegate = context.coordinator
        context.coordinator.apply(to: view)
        view.didLayout = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.applyFollow(to: view)
        }
        return view
    }

    func updateUIView(_ view: LayoutAwareTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(to: view)
    }

    final class LayoutAwareTextView: UITextView {
        var didLayout: (() -> Void)?
        override func layoutSubviews() {
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

        init(_ parent: TranscriptTextView) {
            self.parent = parent
            self.lastFollowGeneration = parent.followGeneration
        }

        func apply(to view: UITextView) {
            let identity = DocumentIdentity(text: parent.document.text,
                                            ranges: parent.document.ranges,
                                            sourceIndices: parent.document.sourceIndices)
            if identity != documentIdentity {
                isApplyingProgrammaticUpdate = true
                view.text = parent.document.text
                view.selectedRange = NSRange(location: 0, length: 0)
                isApplyingProgrammaticUpdate = false
                hadNonemptySelection = false
                highlighted = nil
                followKey = nil
                documentRevision += 1
                documentIdentity = identity
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
            updateHighlight(in: view)
            applyFollow(to: view)
        }

        func applyFollow(to view: UITextView) {
            guard parent.following, view.selectedRange.length == 0,
                  !view.isDragging, !view.isDecelerating,
                  let active = parent.activeSegment,
                  parent.document.ranges.indices.contains(active) else { return }
            let key = FollowKey(documentRevision: documentRevision,
                                activeSegment: active,
                                followGeneration: parent.followGeneration,
                                boundsSize: view.bounds.size,
                                adjustedInsets: view.adjustedContentInset,
                                contentSizeCategory: view.traitCollection.preferredContentSizeCategory)
            guard key != followKey,
                  let lineRect = Self.firstVisualLineRect(
                    for: parent.document.ranges[active], in: view
                  ),
                  let y = TranscriptFollowLayout.targetOffsetY(
                    lineRect: lineRect, boundsHeight: view.bounds.height,
                    contentHeight: view.contentSize.height,
                    adjustedTop: view.adjustedContentInset.top,
                    adjustedBottom: view.adjustedContentInset.bottom
                  ) else { return }
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
            followKey = key
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent.following = false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            let range = textView.selectedRange
            let isNonempty = range.location != NSNotFound && range.length > 0
                && NSMaxRange(range) <= (textView.text as NSString).length
            if isNonempty && !hadNonemptySelection {
                hadNonemptySelection = true
                parent.following = false
                parent.onSelectionBegan()
            } else if !isNonempty {
                hadNonemptySelection = false
            }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let selection = Self.validatedExpandedSelection(in: textView.text, selection: range) else {
                return UIMenu(children: suggestedActions)
            }
            let segment = parent.document.ranges.firstIndex {
                NSIntersectionRange($0, selection.range).length > 0
            }
            let selectionContext = Self.context(in: textView.text, selection: selection.range)
            let add = UIAction(title: "Add to Dictionary", image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
                self?.parent.handleSelection(.addToDictionary, selection.text, selection.range,
                                             segment, selectionContext)
            }
            let translate = UIAction(title: "Translate in Context", image: UIImage(systemName: "character.book.closed")) { [weak self] _ in
                self?.parent.handleSelection(.translateInContext, selection.text, selection.range,
                                             segment, selectionContext)
            }
            return UIMenu(children: [translate, add] + suggestedActions)
        }

        nonisolated static func validatedExpandedSelection(in text: String, selection: NSRange)
            -> (range: NSRange, text: String)? {
            let source = text as NSString
            guard selection.location != NSNotFound, selection.length > 0,
                  NSMaxRange(selection) <= source.length,
                  Range(selection, in: text) != nil else { return nil }
            let expanded = WordSelectionExpander.expandedRange(in: text, selection: selection)
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
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let firstCharacter = NSRange(location: characterRange.location, length: 1)
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

        private func updateHighlight(in view: UITextView) {
            guard highlighted != parent.activeSegment else { return }
            if let previous = highlighted, parent.document.ranges.indices.contains(previous) {
                view.textStorage.removeAttribute(.backgroundColor,
                                                 range: parent.document.ranges[previous])
            }
            if let active = parent.activeSegment, parent.document.ranges.indices.contains(active) {
                view.textStorage.addAttribute(.backgroundColor,
                                              value: UIColor.systemYellow.withAlphaComponent(0.25),
                                              range: parent.document.ranges[active])
            }
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
