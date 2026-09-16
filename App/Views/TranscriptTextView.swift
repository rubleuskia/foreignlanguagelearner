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
            let capacity = 2_000
            guard selection.location != NSNotFound, selection.length <= capacity,
                  NSMaxRange(selection) <= ns.length else { return nil }
            var start = max(0, selection.location - max(0, (capacity - selection.length) / 2))
            let length = min(ns.length - start, capacity)
            if NSMaxRange(selection) > start + length { start = max(0, NSMaxRange(selection) - length) }
            let range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(length, ns.length - start)))
            guard range.length <= capacity else { return nil }
            let excerpt = ns.substring(with: range)
            let relative = NSRange(location: selection.location - range.location, length: selection.length)
            guard relative.location >= 0, NSMaxRange(relative) <= (excerpt as NSString).length,
                  DictionaryEntry.normalized((excerpt as NSString).substring(with: relative)) == DictionaryEntry.normalized(ns.substring(with: selection)) else { return nil }
            return SelectionContext(text: excerpt, selection: relative)
        }
    }
}
