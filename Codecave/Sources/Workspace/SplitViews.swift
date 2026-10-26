import AppKit

/// A pane drawn as a rounded card: a header (icon and title) above the
/// terminal. Unfocused panes are dimmed per Ghostty's
/// `unfocused-split-opacity` / `unfocused-split-fill`.
final class PaneView: NSView {
    static let cornerRadius: CGFloat = 10
    static let headerHeight: CGFloat = 30

    let terminal: TerminalView
    private let theme: Theme
    private let terminalClip = NSView()
    private let overlay: DimOverlay
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")

    /// Dims the terminal (unfocused pane in a split tab).
    var dimmed = false {
        didSet { overlay.isHidden = !dimmed }
    }

    /// The tab's focused pane: brighter border and title.
    var isActive = false {
        didSet { if isActive != oldValue { updateChrome() } }
    }

    var dimColor: NSColor { overlay.color }

    init(terminal: TerminalView, theme: Theme) {
        self.terminal = terminal
        self.theme = theme
        overlay = DimOverlay(color: theme.unfocusedSplitFill)
        super.init(frame: .zero)
        wantsLayer = true

        // Terminal area, clipped to the card's rounded bottom corners.
        terminalClip.wantsLayer = true
        terminalClip.layer?.cornerRadius = Self.cornerRadius - 1
        terminalClip.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        terminalClip.layer?.masksToBounds = true
        addSubview(terminalClip)

        // Sized in layout().
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = []
        terminalClip.addSubview(terminal)
        overlay.isHidden = true
        terminalClip.addSubview(overlay)

        setUpHeader()
        updateTitle()
        updateChrome()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUpHeader() {
        iconView.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        iconView.contentTintColor = theme.secondaryText

        titleField.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.init(1), for: .horizontal)

        let header = NSStackView(views: [iconView, titleField])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    func updateTitle() {
        if !terminal.title.isEmpty {
            titleField.stringValue = terminal.title
        } else if let pwd = terminal.pwd {
            titleField.stringValue = (pwd as NSString).abbreviatingWithTildeInPath
        } else {
            titleField.stringValue = "Terminal"
        }
    }

    private func updateChrome() {
        titleField.textColor = isActive ? theme.foreground : theme.secondaryText
        needsDisplay = true
    }

    // MARK: Layout and drawing

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Inset by the 1pt border so the terminal doesn't cover it.
        terminalClip.frame = NSRect(x: 1, y: Self.headerHeight,
                                    width: max(0, bounds.width - 2),
                                    height: max(0, bounds.height - Self.headerHeight - 1))
        terminal.frame = terminalClip.bounds
        overlay.frame = terminalClip.bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        theme.background.setFill()
        path.fill()
        (isActive ? theme.paneBorderActive : theme.paneBorder).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: Mouse

    /// Clicking the header focuses the pane.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminal)
    }

    override var mouseDownCanMoveWindow: Bool { false }
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
