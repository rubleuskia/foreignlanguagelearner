import SwiftUI
import UIKit

struct TranscriptTextView: UIViewRepresentable {
    let document: TranscriptDocument
    let activeSegment: Int?
    @Binding var following: Bool
    let saveSelection: (String, Int?, SelectionContext?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 40, right: 16)
        view.text = document.text
        view.accessibilityIdentifier = "reader.transcript"
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard view.selectedRange.length == 0 else { return }
        let coordinator = context.coordinator
        if coordinator.highlighted != activeSegment {
            if let previous = coordinator.highlighted, document.ranges.indices.contains(previous) {
                view.textStorage.removeAttribute(.backgroundColor, range: document.ranges[previous])
            }
            if let activeSegment {
                view.textStorage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.25), range: document.ranges[activeSegment])
            }
            coordinator.highlighted = activeSegment
        }
        if following, let activeSegment, coordinator.scrolled != activeSegment || !coordinator.wasFollowing {
            view.scrollRangeToVisible(document.ranges[activeSegment])
            coordinator.scrolled = activeSegment
        }
        coordinator.wasFollowing = following
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TranscriptTextView
        var highlighted: Int?
        var scrolled: Int?
        var wasFollowing = true
        init(_ parent: TranscriptTextView) { self.parent = parent }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { parent.following = false }
        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 { parent.following = false }
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return UIMenu(children: suggestedActions) }
            let selected = (textView.text as NSString).substring(with: range)
            let segment = parent.document.ranges.firstIndex { NSIntersectionRange($0, range).length > 0 }
            let selectionContext = Self.context(in: textView.text, selection: range)
            let action = UIAction(title: "Add to Dictionary", image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
                self?.parent.saveSelection(selected, segment, selectionContext)
            }
            return UIMenu(children: [action] + suggestedActions)
        }

        private static func context(in text: String, selection: NSRange) -> SelectionContext? {
            let ns = text as NSString
            guard selection.location != NSNotFound, selection.length > 0,
                  NSMaxRange(selection) <= ns.length else { return nil }

            // A sentence boundary is a dot followed by whitespace and an uppercase letter.
            let pattern = #"\.(?:\s+)(?=[\p{Lu}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let separators = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

            let previousBoundary = separators.last { $0.range.location < selection.location }
            let nextBoundary = separators.first { $0.range.location >= NSMaxRange(selection) }
            let currentStart = previousBoundary.map(NSMaxRange) ?? 0
            let currentEnd = nextBoundary.map { $0.range.location + 1 } ?? ns.length

            let earlierBoundary = previousBoundary.flatMap { boundary in
                separators.last { $0.range.location < boundary.range.location }
            }
            let laterBoundary = nextBoundary.flatMap { boundary in
                separators.first { $0.range.location > boundary.range.location }
            }

            let beforeStart = earlierBoundary.map(NSMaxRange) ?? 0
            let before = limitedSentence(ns.substring(with: NSRange(location: beforeStart,
                                                                       length: max(0, currentStart - beforeStart))),
                                         fromEnd: true)
            let current = ns.substring(with: NSRange(location: currentStart,
                                                      length: currentEnd - currentStart)).trimmingCharacters(in: .whitespacesAndNewlines)
            let afterStart = nextBoundary.map(NSMaxRange) ?? ns.length
            let afterEnd = laterBoundary?.range.location ?? ns.length
            let after = limitedSentence(ns.substring(with: NSRange(location: afterStart,
                                                                      length: max(0, afterEnd - afterStart))),
                                        fromEnd: false)
            let excerpt = [before, current, after].filter { !$0.isEmpty }.joined(separator: " ")
            let relative = (excerpt as NSString).range(of: ns.substring(with: selection))
            guard relative.location != NSNotFound else { return nil }
            return SelectionContext(text: excerpt, selection: relative)
        }

        private static func limitedSentence(_ sentence: String, fromEnd: Bool) -> String {
            let words = sentence.split(whereSeparator: { $0.isWhitespace })
            guard words.count > 15 else { return sentence.trimmingCharacters(in: .whitespacesAndNewlines) }
            let limited = fromEnd ? words.suffix(15) : words.prefix(15)
            return limited.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
