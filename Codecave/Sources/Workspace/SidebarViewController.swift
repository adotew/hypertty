import AppKit

/// The window's sidebar: a Tabs / Files header above either the tab list
/// or the file tree. ⌘S shows tabs, ⌘⇧E files; ⇥ switches between them
/// while the sidebar has focus.
final class SidebarViewController: NSViewController {
    enum Mode { case tabs, files }

    let tabList: TabListViewController
    let fileTree: FileTreeViewController
    private(set) var mode: Mode = .tabs

    private let theme: Theme
    private let tabsButton: ModeButton
    private let filesButton: ModeButton
    private let rootLabel = NSTextField(labelWithString: "")

    /// Puts the header in the titlebar, right of the traffic lights
    /// (14pt buttons 9pt from the top, the last ending at x = 69).
    private static let topInset: CGFloat = 4
    private static let leadingInset: CGFloat = 78

    init(theme: Theme) {
        self.theme = theme
        tabList = TabListViewController(theme: theme)
        fileTree = FileTreeViewController(theme: theme)
        tabsButton = ModeButton(title: "Tabs", theme: theme)
        filesButton = ModeButton(title: "Files", theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        // Transparent: the window paints the background, so the sidebar and
        // the area around the panes are exactly the same color.
        let root = NSView()
        root.frame = NSRect(x: 0, y: 0, width: 220, height: 600)

        tabsButton.onClick = { [weak self] in self?.show(.tabs) }
        filesButton.onClick = { [weak self] in self?.show(.files) }
        tabList.onSwitchMode = { [weak self] in self?.show(.files) }
        fileTree.onSwitchMode = { [weak self] in self?.show(.tabs) }
        fileTree.onRootChange = { [weak self] in self?.updateHeader() }

        rootLabel.font = .systemFont(ofSize: 11)
        rootLabel.textColor = theme.secondaryText
        rootLabel.lineBreakMode = .byTruncatingHead
        rootLabel.alignment = .right
        rootLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rootLabel.setContentHuggingPriority(.init(1), for: .horizontal)

        let header = NSStackView(views: [tabsButton, filesButton, rootLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        addChild(tabList)
        addChild(fileTree)
        var constraints = [
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.topInset),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.leadingInset),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 24),
        ]
        for child in [tabList.view, fileTree.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
            constraints += [
                child.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
                child.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
                child.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                child.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        view = root
        show(.tabs)
    }

    /// Switches lists. Keyboard focus follows if the sidebar had it.
    func show(_ mode: Mode) {
        let hadFocus = hasFocus
        self.mode = mode
        tabList.view.isHidden = mode != .tabs
        fileTree.isShown = mode == .files
        updateHeader()
        if hadFocus { focus() }
    }

    // MARK: Tabs

    func update(tabs: [Tab], selectedIndex: Int?) {
        tabList.update(tabs: tabs, selectedIndex: selectedIndex)
        updateHeader()
    }

    func refresh(tab: Tab) {
        tabList.refresh(tab: tab)
        updateHeader()
    }

    func beginRename(at row: Int) {
        show(.tabs)
        tabList.beginRename(at: row)
    }

    // MARK: Focus

    var hasFocus: Bool { tabList.hasFocus || fileTree.hasFocus }

    func focus() {
        switch mode {
        case .tabs: tabList.focus()
        case .files: fileTree.focus()
        }
    }

    private func updateHeader() {
        tabsButton.isSelected = mode == .tabs
        filesButton.isSelected = mode == .files
        // A bell in some tab shows on the Tabs button while it's out of view.
        tabsButton.showsDot = mode != .tabs && tabList.tabs.contains { $0.hasBell }
        rootLabel.stringValue = mode == .files ? fileTree.root?.lastPathComponent ?? "" : ""
        rootLabel.toolTip = fileTree.root.map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }
}

// MARK: - Views shared by the tab list and the file tree

/// A transparent, overlay-scrolling container for a sidebar list.
final class SidebarScrollView: NSScrollView {
    init(documentView: NSView) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
        self.documentView = documentView
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

final class SidebarTableView: NSTableView {
    /// Return true if the key was handled.
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }
}

/// Rounded selection; outlined in the accent color while the list has
/// keyboard focus.
final class SidebarRowView: NSTableRowView {
    private let theme: Theme
    private let radius: CGFloat

    init(theme: Theme, radius: CGFloat = 6) {
        self.theme = theme
        self.radius = radius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isEmphasized: Bool {
        didSet { needsDisplay = true }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        theme.selection.setFill()
        path.fill()
        if isEmphasized {
            theme.accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}

/// "Tabs" / "Files" in the sidebar header.
private final class ModeButton: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { update() } }
    var showsDot = false { didSet { dot.isHidden = !showsDot } }

    private let theme: Theme
    private let label: NSTextField
    private let dot: FillView

    init(title: String, theme: Theme) {
        self.theme = theme
        label = NSTextField(labelWithString: title)
        dot = FillView(color: theme.accent)
        super.init(frame: .zero)

        label.font = .systemFont(ofSize: 12, weight: .semibold)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.layer?.masksToBounds = true
        dot.isHidden = true

        for view in [label, dot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 2),
            dot.topAnchor.constraint(equalTo: label.topAnchor, constant: 1),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func update() {
        label.textColor = isSelected ? theme.foreground : theme.secondaryText
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        theme.selection.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
