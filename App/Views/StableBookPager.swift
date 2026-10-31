import SwiftUI
import UIKit

/// Retains native page controllers across gestures. Playback/style updates wait
/// until a transition finishes; page content is never replaced mid-swipe.
struct StableBookPager: UIViewControllerRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    struct Revision: Equatable {
        let active: Int?
        let words: Int
        let index: ObjectIdentifier?
        let follow: Int
        let following: Bool
        let underline: Bool
    }

    let count: Int
    let selection: Int
    let revision: Revision
    let makePage: (Int) -> TranscriptTextView
    let onManualStart: () -> Void
    let onSelection: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.view.backgroundColor = .systemBackground
        controller.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        controller.view.clipsToBounds = true
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        context.coordinator.showInitialPage()
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        controller.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        context.coordinator.parent = self
        context.coordinator.update()
    }

    static func dismantleUIViewController(_ controller: UIPageViewController, coordinator: Coordinator) {
        controller.delegate = nil
        controller.dataSource = nil
        coordinator.controller = nil
    }

    final class Page: UIViewController {
        let index: Int
        var revision: Revision
        let textCoordinator: TranscriptTextView.Coordinator
        let textView: TranscriptTextView.LayoutAwareTextView

        init(index: Int, revision: Revision, content: TranscriptTextView) {
            self.index = index
            self.revision = revision
            textCoordinator = TranscriptTextView.Coordinator(content)
            textView = content.makeConfiguredTextView(coordinator: textCoordinator)
            super.init(nibName: nil, bundle: nil)
            view = textView
            view.backgroundColor = .systemBackground
            view.clipsToBounds = true
        }
        @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

        func update(_ content: TranscriptTextView) {
            textCoordinator.parent = content
            textCoordinator.apply(to: textView)
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: StableBookPager
        weak var controller: UIPageViewController?
        private(set) var cached: [Int: Page] = [:]
        private(set) var visible = 0
        private(set) var transitioning = false
        private var interactive = false

        init(_ parent: StableBookPager) { self.parent = parent }

        func page(_ index: Int) -> Page? {
            guard (0..<parent.count).contains(index) else { return nil }
            if let page = cached[index] { return page }
            let page = Page(index: index, revision: parent.revision, content: parent.makePage(index))
            cached[index] = page
            return page
        }

        func showInitialPage() {
            guard let first = page(parent.selection) else { return }
            visible = first.index
            controller?.setViewControllers([first], direction: .forward, animated: false)
            prepareNeighbors()
        }

        func update() {
            guard !transitioning, let controller else { return }
            refreshContent()
            guard parent.selection != visible, let target = page(parent.selection) else { return }
            transitioning = true
            let direction: UIPageViewController.NavigationDirection = target.index > visible ? .forward : .reverse
            controller.setViewControllers([target], direction: direction,
                animated: !UIAccessibility.isReduceMotionEnabled && controller.view.window != nil) { [weak self] _ in
                    guard let self else { return }
                    self.visible = target.index
                    self.transitioning = false
                    self.prepareNeighbors()
                    // Coalesce audio jumps received during the animation to the latest target.
                    self.update()
                }
        }

        private func refreshContent() {
            for page in cached.values where page.revision != parent.revision {
                page.update(parent.makePage(page.index))
                page.revision = parent.revision
            }
        }

        private func prepareNeighbors() {
            guard !transitioning else { return }
            _ = page(visible - 1)
            _ = page(visible + 1)
            cached = cached.filter { abs($0.key - visible) <= 1 }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? Page else { return nil }
            return self.page(page.index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? Page else { return nil }
            return self.page(page.index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true
            interactive = true
            parent.onManualStart()
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard interactive else { return }
            interactive = false
            transitioning = false
            if let current = pageViewController.viewControllers?.first as? Page { visible = current.index }
            // A cancelled gesture also reports the actual visible page, without
            // re-installing controllers or snapping back through a second animation.
            parent.onSelection(visible)
            prepareNeighbors()
            refreshContent()
        }
    }
}
