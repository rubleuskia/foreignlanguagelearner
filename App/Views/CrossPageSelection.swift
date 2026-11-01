import UIKit

/// Selection belongs to the chapter, not to any one page's text view.
struct CrossPageSelection {
    enum Endpoint { case start, end }
    private(set) var range: NSRange
    private var anchor: Int

    init(range: NSRange) { self.range = range; anchor = range.location }

    mutating func beginDragging(_ endpoint: Endpoint) {
        anchor = endpoint == .start ? NSMaxRange(range) : range.location
    }

    mutating func extend(to offset: Int, text: String, language: String) {
        let length = (text as NSString).length
        let target = min(max(0, offset), length)
        let lower = min(anchor, target)
        let upper = max(anchor, target)
        guard upper > lower else { return }
        // Only tokenize near the moving handle, never the entire selected
        // chapter on every drag frame. The fixed anchor is already a word edge.
        let word = Self.word(at: target > anchor ? target - 1 : target, text: text, language: language)
        let edge = target > anchor ? NSMaxRange(word) : word.location
        range = NSRange(location: min(anchor, edge), length: abs(edge - anchor))
    }

    static func word(at offset: Int, text: String, language: String) -> NSRange {
        let source = text as NSString
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        let point = min(max(0, offset), source.length - 1)
        let window = source.rangeOfComposedCharacterSequences(for:
            NSRange(location: max(0, point - 256), length: min(source.length, point + 257) - max(0, point - 256)))
        let snippet = source.substring(with: window)
        let character = (snippet as NSString).rangeOfComposedCharacterSequence(at: point - window.location)
        let word = WordSelectionExpander.expandedRange(in: snippet, selection: character, language: language)
        return NSRange(location: word.location + window.location, length: word.length)
    }
}

@MainActor final class BookSelectionOverlay: UIView {
    final class Handle: UIView {
        var adjust: ((Int) -> Void)?
        override func accessibilityIncrement() { adjust?(1) }
        override func accessibilityDecrement() { adjust?(-1) }
        override func draw(_ rect: CGRect) {
            tintColor.setFill()
            UIBezierPath(roundedRect: CGRect(x: 20, y: 3, width: 3, height: 27), cornerRadius: 1.5).fill()
            UIBezierPath(ovalIn: CGRect(x: 15, y: 27, width: 13, height: 13)).fill()
        }
    }
    let startHandle = Handle()
    let endHandle = Handle()
    let actions = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    var rectangles: [CGRect] = [] { didSet { setNeedsDisplay() } }
    var active = false {
        didSet { startHandle.isHidden = !active; endHandle.isHidden = !active; setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        actions.layer.cornerRadius = 12
        actions.clipsToBounds = true
        actions.isHidden = true
        addSubview(actions)
        for (handle, name, identifier) in [(startHandle, "Selection start", "reader.selection.start"),
                                          (endHandle, "Selection end", "reader.selection.end")] {
            handle.backgroundColor = .clear
            handle.isOpaque = false
            handle.contentMode = .redraw
            handle.isAccessibilityElement = true
            handle.accessibilityLabel = AppLanguage.text(name)
            handle.accessibilityIdentifier = identifier
            handle.accessibilityTraits = .adjustable
            addSubview(handle)
        }
        active = false
        startHandle.isHidden = true; endHandle.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard active else { return nil }
        for handle in [startHandle, endHandle] where handle.frame.insetBy(dx: -8, dy: -8).contains(point) {
            return handle
        }
        if !actions.isHidden, actions.frame.contains(point) {
            return actions.hitTest(convert(point, to: actions), with: event)
        }
        return nil
    }
    override func draw(_ rect: CGRect) {
        guard active else { return }
        tintColor.withAlphaComponent(0.24).setFill()
        for rectangle in rectangles { UIBezierPath(rect: rectangle).fill() }
    }
}

@MainActor final class BookSelectionController: NSObject, UIGestureRecognizerDelegate {
    weak var host: StableBookPager.Coordinator?
    let overlay = BookSelectionOverlay()
    private(set) var selection: CrossPageSelection?
    private(set) var isDragging = false
    private var finger = CGPoint.zero
    private var edgeTimer: Timer?
    private var edgeEntered: Date?
    private var edgeDirection = 0
    private var longPress: UILongPressGestureRecognizer?
    private var tap: UITapGestureRecognizer?

    init(host: StableBookPager.Coordinator, view: UIView) {
        self.host = host
        super.init()
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        for (title, icon, action) in [
            ("Translate in Context", "character.book.closed", TranscriptSelectionAction.translateInContext),
            ("Add to Dictionary", "text.badge.plus", TranscriptSelectionAction.addToDictionary)
        ] {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: icon), for: .normal)
            button.accessibilityLabel = AppLanguage.text(title)
            button.addAction(UIAction { [weak self] _ in
                guard let self, let range = self.selection?.range else { return }
                self.perform(action, range: range)
            }, for: .touchUpInside)
            buttons.addArrangedSubview(button)
        }
        let copy = UIButton(type: .system)
        copy.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        copy.accessibilityLabel = AppLanguage.text("Copy")
        copy.addAction(UIAction { [weak self] _ in
            guard let self, let range = self.selection?.range else { return }
            UIPasteboard.general.string = (self.text as NSString).substring(with: range)
        }, for: .touchUpInside)
        buttons.addArrangedSubview(copy)
        buttons.frame = CGRect(x: 0, y: 0, width: 144, height: 44)
        overlay.actions.contentView.addSubview(buttons)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(beginSelection(_:)))
        press.minimumPressDuration = 0.45
        press.delegate = self
        view.addGestureRecognizer(press)
        longPress = press
        let tap = UITapGestureRecognizer(target: self, action: #selector(clearSelection))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
        self.tap = tap
        for handle in [overlay.startHandle, overlay.endHandle] {
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragHandle(_:))))
        }
        overlay.startHandle.adjust = { [weak self] delta in self?.adjust(.start, delta: delta) }
        overlay.endHandle.adjust = { [weak self] delta in self?.adjust(.end, delta: delta) }
    }

    func configure(_ page: StableBookPager.Page) {
        page.textView.isSelectable = false
        let previous = page.textView.didLayout
        page.textView.didLayout = { [weak self] in previous?(); self?.refresh() }
    }

    private var text: String { host?.parent.selectionDisplayText ?? "" }
    private var language: String { currentPage?.textCoordinator.parent.wordStyleLanguage ?? "" }
    private var currentPage: StableBookPager.Page? {
        guard let host else { return nil }
        return host.cached[host.visible]
    }
    private var pageRange: NSRange? {
        guard let host, host.parent.pageRanges.indices.contains(host.visible) else { return nil }
        return host.parent.pageRanges[host.visible]
    }

    private func offset(at point: CGPoint) -> Int? {
        guard let page = currentPage, let range = pageRange else { return nil }
        let local = overlay.convert(point, to: page.textView)
        guard let position = page.textView.closestPosition(to: local) else { return nil }
        return range.location + page.textView.offset(from: page.textView.beginningOfDocument, to: position)
    }

    @objc private func beginSelection(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let offset = offset(at: gesture.location(in: overlay)), !text.isEmpty,
                  (text as NSString).length > 0
            else { return }
            selection = CrossPageSelection(range: CrossPageSelection.word(at: offset, text: text, language: language))
            currentPage?.textCoordinator.parent.onSelectionBegan()
            host?.parent.onManualStart()
            refresh()
        case .ended: presentMenu()
        default: break
        }
    }

    @objc private func clearSelection() { clear() }
    func invalidate() {
        clear()
        if let longPress { longPress.view?.removeGestureRecognizer(longPress) }
        if let tap { tap.view?.removeGestureRecognizer(tap) }
        longPress = nil; tap = nil
        for handle in [overlay.startHandle, overlay.endHandle] {
            for recognizer in handle.gestureRecognizers ?? [] { handle.removeGestureRecognizer(recognizer) }
            handle.adjust = nil
        }
        overlay.removeFromSuperview()
    }

    func clear() {
        guard selection != nil || isDragging || overlay.active else { return }
        edgeTimer?.invalidate(); edgeTimer = nil
        edgeEntered = nil; edgeDirection = 0
        selection = nil; isDragging = false
        overlay.actions.isHidden = true
        overlay.active = false
        overlay.rectangles = []
    }

    @objc private func dragHandle(_ gesture: UIPanGestureRecognizer) {
        guard selection != nil else { return }
        finger = gesture.location(in: overlay)
        switch gesture.state {
        case .began:
            overlay.actions.isHidden = true
            isDragging = true
            selection?.beginDragging(gesture.view === overlay.startHandle ? .start : .end)
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkEdge() }
            }
            edgeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            fallthrough
        case .changed:
            if host?.transitioning == false, let value = offset(at: finger) {
                selection?.extend(to: value, text: text, language: language)
                refresh()
            }
            checkEdge()
        case .ended, .cancelled, .failed:
            isDragging = false
            edgeTimer?.invalidate(); edgeTimer = nil
            edgeEntered = nil; edgeDirection = 0
            if host?.transitioning == false { presentMenu() }
            host?.update()
        default: break
        }
    }

    private func checkEdge() {
        guard isDragging, let host, !host.transitioning else { return }
        let direction = finger.x < 30 ? -1 : (finger.x > overlay.bounds.width - 30 ? 1 : 0)
        if direction != edgeDirection {
            edgeDirection = direction
            edgeEntered = direction == 0 ? nil : Date()
        }
        guard direction != 0, let entered = edgeEntered, Date().timeIntervalSince(entered) >= 0.55 else { return }
        edgeEntered = Date()
        host.turnForSelection(to: host.visible + direction) { [weak self] in
            guard let self else { return }
            if let value = self.offset(at: self.finger) {
                self.selection?.extend(to: value, text: self.text, language: self.language)
            }
            self.refresh()
            if !self.isDragging { self.presentMenu() }
        }
    }

    func refresh() {
        guard let selection, let page = currentPage, let visibleRange = pageRange,
              host?.transitioning == false else { return }
        overlay.superview?.bringSubviewToFront(overlay)
        let intersection = NSIntersectionRange(selection.range, visibleRange)
        let view = page.textView
        overlay.active = true
        if intersection.length > 0,
           let start = view.position(from: view.beginningOfDocument, offset: intersection.location - visibleRange.location),
           let end = view.position(from: start, offset: intersection.length),
           let range = view.textRange(from: start, to: end) {
            overlay.rectangles = view.selectionRects(for: range).map { view.convert($0.rect, to: overlay) }
        } else { overlay.rectangles = [] }
        for (handle, value, isEnd) in [(overlay.startHandle, selection.range.location, false),
                                      (overlay.endHandle, NSMaxRange(selection.range), true)] {
            let local = min(max(0, value - visibleRange.location), visibleRange.length)
            guard let position = view.position(from: view.beginningOfDocument, offset: local) else { continue }
            let caret = view.convert(view.caretRect(for: position), to: overlay)
            let x = min(max(22, caret.minX), max(22, overlay.bounds.width - 22))
            let y = min(max(22, isEnd ? caret.maxY : caret.minY), max(22, overlay.bounds.height - 22))
            handle.frame = CGRect(x: x - 22, y: y - 22, width: 44, height: 44)
            handle.setNeedsDisplay()
        }
        let source = text as NSString
        let excerpt = source.rangeOfComposedCharacterSequences(for:
            NSRange(location: selection.range.location, length: min(160, selection.range.length)))
        let value = source.substring(with: excerpt)
        overlay.startHandle.accessibilityValue = value
        overlay.endHandle.accessibilityValue = value
    }

    func presentMenu() {
        guard selection != nil else { return }
        refresh()
        overlay.actions.frame = CGRect(x: max(0, (overlay.bounds.width - 144) / 2),
            y: max(0, overlay.bounds.height - 48), width: 144, height: 44)
        overlay.actions.isHidden = false
    }

    private func adjust(_ endpoint: CrossPageSelection.Endpoint, delta: Int) {
        guard var selection, let host else { return }
        selection.beginDragging(endpoint)
        let value = endpoint == .start ? selection.range.location : NSMaxRange(selection.range)
        let source = text as NSString
        var probe = delta > 0 ? value : value - 1
        while probe >= 0, probe < source.length,
              (CharacterSet.whitespacesAndNewlines as NSCharacterSet).characterIsMember(source.character(at: probe)) {
            probe += delta
        }
        let word = CrossPageSelection.word(at: probe, text: text, language: language)
        selection.extend(to: delta > 0 ? NSMaxRange(word) : word.location, text: text, language: language)
        self.selection = selection
        let destination = BookTextPagination.page(containing: min((text as NSString).length - 1,
            endpoint == .start ? selection.range.location : NSMaxRange(selection.range) - 1), ranges: host.parent.pageRanges)
        if destination != host.visible { host.turnForSelection(to: destination) { [weak self] in self?.refresh() } }
        else { refresh() }
    }

    private func perform(_ action: TranscriptSelectionAction, range: NSRange) {
        let callback = host?.parent.onTextSelection
        clear()
        callback?(action, range)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view is BookSelectionOverlay.Handle { return false }
        if touch.view?.isDescendant(of: overlay.actions) == true { return false }
        if gestureRecognizer === tap { return selection != nil }
        return true
    }
}
