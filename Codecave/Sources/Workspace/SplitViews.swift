import AppKit

/// Wraps a terminal and dims it when it isn't the tab's focused pane
/// (Ghostty's `unfocused-split-opacity` / `unfocused-split-fill`).
final class PaneView: NSView {
    let terminal: TerminalView
    private let overlay: DimOverlay

    var dimmed = false {
        didSet { overlay.isHidden = !dimmed }
    }

    var dimColor: NSColor { overlay.color }

    init(terminal: TerminalView, theme: Theme) {
        self.terminal = terminal
        overlay = DimOverlay(color: theme.unfocusedSplitFill)
        super.init(frame: .zero)

        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        terminal.translatesAutoresizingMaskIntoConstraints = true
        addSubview(terminal)

        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.isHidden = true
        addSubview(overlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// A translucent layer above the terminal's Metal layer that ignores the mouse.
private final class DimOverlay: NSView {
    let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Two children laid out at `ratio` with a draggable divider between them.
final class SplitContainerView: NSView {
    static let dividerThickness: CGFloat = 1
    /// Extra grab area on each side of the divider.
    private static let dividerSlop: CGFloat = 3

    let axis: SplitAxis
    var ratio: CGFloat { didSet { needsLayout = true } }
    /// Called while dragging the divider.
    var onRatioChange: ((CGFloat) -> Void)?

    private let first: NSView
    private let second: NSView
    private let dividerColor: NSColor

    init(axis: SplitAxis, ratio: CGFloat, first: NSView, second: NSView, dividerColor: NSColor) {
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
        self.dividerColor = dividerColor
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
        let t = Self.dividerThickness
        switch axis {
        case .horizontal:
            let firstWidth = ((bounds.width - t) * ratio).rounded()
            return (CGRect(x: 0, y: 0, width: firstWidth, height: bounds.height),
                    CGRect(x: firstWidth + t, y: 0, width: bounds.width - firstWidth - t, height: bounds.height))
        case .vertical:
            let firstHeight = ((bounds.height - t) * ratio).rounded()
            return (CGRect(x: 0, y: 0, width: bounds.width, height: firstHeight),
                    CGRect(x: 0, y: firstHeight + t, width: bounds.width, height: bounds.height - firstHeight - t))
        }
    }

    private var dividerRect: CGRect {
        let firstFrame = childFrames.0
        switch axis {
        case .horizontal:
            return CGRect(x: firstFrame.maxX, y: 0, width: Self.dividerThickness, height: bounds.height)
        case .vertical:
            return CGRect(x: 0, y: firstFrame.maxY, width: bounds.width, height: Self.dividerThickness)
        }
    }

    private var dividerHitRect: CGRect {
        switch axis {
        case .horizontal: dividerRect.insetBy(dx: -Self.dividerSlop, dy: 0)
        case .vertical: dividerRect.insetBy(dx: 0, dy: -Self.dividerSlop)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        dividerColor.setFill()
        dividerRect.fill()
    }

    // MARK: Divider dragging

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if dividerHitRect.contains(local) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        addCursorRect(dividerHitRect, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {}

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
