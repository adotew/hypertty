import AppKit

/// A pane drawn as a Liquid Glass card with the terminal or web page
/// filling it. The card is filled with the terminal background so the two
/// are one color; the glass provides the edge. Unfocused panes are dimmed per
/// Ghostty's `unfocused-split-opacity` / `unfocused-split-fill`.
final class PaneView: NSView {
    static let cornerRadius: CGFloat = 12

    let pane: any Pane
    private let glass = NSGlassEffectView()
    private let card: CardContent
    private let overlay: DimOverlay
    private let outline: OutlineView

    /// Dims the card (unfocused pane in a split tab).
    var dimmed = false {
        didSet { overlay.isHidden = !dimmed }
    }

    /// Outlines the card (focused pane in a split tab).
    var outlined = false {
        didSet { outline.isHidden = !outlined }
    }

    var dimColor: NSColor { overlay.color }

    var freezesPane = false {
        didSet { needsLayout = true }
    }

    private let blankIcon = NSImageView()
    private var urlObservation: NSKeyValueObservation?

    init(pane: any Pane, theme: Theme) {
        self.pane = pane
        card = CardContent(color: theme.background, radius: Self.cornerRadius)
        overlay = DimOverlay(color: theme.unfocusedSplitFill, cornerRadius: Self.cornerRadius)
        outline = OutlineView(color: theme.foreground.withAlphaComponent(0.15), cornerRadius: Self.cornerRadius)
        super.init(frame: .zero)

        glass.cornerRadius = Self.cornerRadius
        glass.tintColor = theme.background
        glass.contentView = card
        addSubview(glass)

        // Sized in layout().
        pane.translatesAutoresizingMaskIntoConstraints = true
        pane.autoresizingMask = []
        card.clipsToBounds = true
        card.addSubview(pane)

        if let web = pane as? WebPaneView {
            blankIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            blankIcon.symbolConfiguration = .init(pointSize: 48, weight: .light)
            blankIcon.contentTintColor = .tertiaryLabelColor
            blankIcon.isHidden = true
            card.addSubview(blankIcon)
            urlObservation = web.observe(\.url, options: [.initial, .new]) { [weak self] web, _ in
                guard let self else { return }
                let blank = web.url == WebPaneView.blank
                // Hide the page's white background; alpha keeps it focusable.
                web.alphaValue = blank ? 0 : 1
                blankIcon.isHidden = !blank
            }
        }

        overlay.isHidden = true
        addSubview(overlay)

        // In the card: siblings of the glass view don't show above web panes.
        outline.isHidden = true
        card.addSubview(outline)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Layout

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        glass.frame = bounds
        card.frame = glass.bounds
        overlay.frame = bounds
        outline.frame = card.bounds
        if !freezesPane { pane.frame = card.bounds }
        blankIcon.sizeToFit()
        blankIcon.frame.origin = NSPoint(x: card.bounds.midX - blankIcon.frame.width / 2,
                                         y: card.bounds.midY - blankIcon.frame.height / 2)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        freezesPane = false
    }

    // MARK: Mouse

    /// Clicking the card's margin focuses the pane.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(pane)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// The glass's content: a rounded, solid fill behind the terminal.
private final class CardContent: NSView {
    private let color: NSColor
    private let radius: CGFloat

    init(color: NSColor, radius: CGFloat) {
        self.color = color
        self.radius = radius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }
}

/// A translucent layer above the terminal's Metal layer that ignores the mouse.
private final class DimOverlay: NSView {
    let color: NSColor

    init(color: NSColor, cornerRadius: CGFloat) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = cornerRadius
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class OutlineView: NSView {
    private static let width: CGFloat = 2

    private let color: NSColor
    private let radius: CGFloat

    init(color: NSColor, cornerRadius: CGFloat) {
        self.color = color
        radius = cornerRadius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: Self.width / 2, dy: Self.width / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = Self.width
        color.setStroke()
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct Transition {
    let start: CFTimeInterval
    let from: CGFloat
    let to: CGFloat
    let completion: (() -> Void)?
}

/// Two children laid out at `ratio`, separated by a gap that can be
/// dragged to resize.
final class SplitContainerView: NSView {
    static let gap: CGFloat = 8

    let axis: SplitAxis
    var ratio: CGFloat { didSet { needsLayout = true } }
    /// Called while dragging the gap.
    var onRatioChange: ((CGFloat) -> Void)?
    private var collapsed: CGFloat = 0 { didSet { needsLayout = true } }
    private var collapsingSecond = true
    private var transition: Transition?
    private var displayLink: CADisplayLink?

    private let first: NSView
    private let second: NSView

    init(axis: SplitAxis, ratio: CGFloat, first: NSView, second: NSView) {
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
        super.init(frame: .zero)
        for child in [first, second] {
            child.translatesAutoresizingMaskIntoConstraints = true
            child.autoresizingMask = []
            addSubview(child)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func animate(_ child: NSView, appearing: Bool, completion: (() -> Void)? = nil) {
        collapsingSecond = child === second
        collapsed = appearing ? 0 : 1
        layoutSubtreeIfNeeded()
        setPanesFrozen(true)
        collapsed = appearing ? 1 : 0
        transition = Transition(start: CACurrentMediaTime(), from: collapsed, to: appearing ? 0 : 1,
                                completion: completion)
        displayLink?.invalidate()
        displayLink = displayLink(target: self, selector: #selector(step))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let transition else { return }
        let progress = min(1, (link.targetTimestamp - transition.start) / 0.15)
        let eased = progress < 0.5 ? 4 * pow(progress, 3) : 1 - pow(2 - 2 * progress, 3) / 2
        collapsed = transition.from + (transition.to - transition.from) * eased
        layoutSubtreeIfNeeded()
        guard progress == 1 else { return }
        link.invalidate()
        displayLink = nil
        self.transition = nil
        setPanesFrozen(false)
        transition.completion?()
    }

    private func setPanesFrozen(_ frozen: Bool) {
        var views: [NSView] = [self]
        while let view = views.popLast() {
            if let paneView = view as? PaneView {
                paneView.freezesPane = frozen
            } else {
                views += view.subviews
            }
        }
    }

    // Top-left origin, matching SplitNode.frames.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        (first.frame, second.frame) = childFrames
        (collapsingSecond ? second : first).alphaValue = 1 - collapsed
        window?.invalidateCursorRects(for: self)
    }

    private var childFrames: (CGRect, CGRect) {
        let gap = Self.gap * (1 - collapsed)
        let ratio = ratio + ((collapsingSecond ? 1 : 0) - ratio) * collapsed
        switch axis {
        case .horizontal:
            let firstWidth = ((bounds.width - gap) * ratio).rounded()
            return (CGRect(x: 0, y: 0, width: firstWidth, height: bounds.height),
                    CGRect(x: firstWidth + gap, y: 0, width: bounds.width - firstWidth - gap, height: bounds.height))
        case .vertical:
            let firstHeight = ((bounds.height - gap) * ratio).rounded()
            return (CGRect(x: 0, y: 0, width: bounds.width, height: firstHeight),
                    CGRect(x: 0, y: firstHeight + gap, width: bounds.width, height: bounds.height - firstHeight - gap))
        }
    }

    private var gapRect: CGRect {
        let firstFrame = childFrames.0
        let gap = Self.gap * (1 - collapsed)
        switch axis {
        case .horizontal: return CGRect(x: firstFrame.maxX, y: 0, width: gap, height: bounds.height)
        case .vertical: return CGRect(x: 0, y: firstFrame.maxY, width: bounds.width, height: gap)
        }
    }

    // MARK: Dragging the gap

    override func hitTest(_ point: NSPoint) -> NSView? {
        if gapRect.contains(convert(point, from: superview)) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        addCursorRect(gapRect, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {}

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newRatio: CGFloat
        switch axis {
        case .horizontal: newRatio = point.x / max(bounds.width, 1)
        case .vertical: newRatio = point.y / max(bounds.height, 1)
        }
        ratio = min(0.9, max(0.1, newRatio))
        onRatioChange?(ratio)
    }
}
