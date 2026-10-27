import AppKit

/// A pane drawn as a Liquid Glass card with the terminal filling it.
/// The card is filled with the terminal background so the two are one
/// color; the glass provides the edge. Unfocused panes are dimmed per
/// Ghostty's `unfocused-split-opacity` / `unfocused-split-fill`.
final class PaneView: NSView {
    static let cornerRadius: CGFloat = 12

    let terminal: TerminalView
    private let glass = NSGlassEffectView()
    private let card: CardContent
    private let overlay: DimOverlay

    /// Dims the card (unfocused pane in a split tab).
    var dimmed = false {
        didSet { overlay.isHidden = !dimmed }
    }

    var dimColor: NSColor { overlay.color }

    init(terminal: TerminalView, theme: Theme) {
        self.terminal = terminal
        card = CardContent(color: theme.background, radius: Self.cornerRadius)
        overlay = DimOverlay(color: theme.unfocusedSplitFill, cornerRadius: Self.cornerRadius)
        super.init(frame: .zero)

        glass.cornerRadius = Self.cornerRadius
        glass.tintColor = theme.background
        glass.contentView = card
        addSubview(glass)

        // Sized in layout().
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = []
        card.addSubview(terminal)

        overlay.isHidden = true
        addSubview(overlay)
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
        terminal.frame = card.bounds
    }

    // MARK: Mouse

    /// Clicking the card's margin focuses the pane.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminal)
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

/// Two children laid out at `ratio`, separated by a gap that can be
/// dragged to resize.
final class SplitContainerView: NSView {
    static let gap: CGFloat = 8

    let axis: SplitAxis
    var ratio: CGFloat { didSet { needsLayout = true } }
    /// Called while dragging the gap.
    var onRatioChange: ((CGFloat) -> Void)?

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

    // Top-left origin, matching SplitNode.frames.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let (a, b) = childFrames
        first.frame = a
        second.frame = b
        window?.invalidateCursorRects(for: self)
    }

    private var childFrames: (CGRect, CGRect) {
        let gap = Self.gap
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
        switch axis {
        case .horizontal: return CGRect(x: firstFrame.maxX, y: 0, width: Self.gap, height: bounds.height)
        case .vertical: return CGRect(x: 0, y: firstFrame.maxY, width: bounds.width, height: Self.gap)
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
