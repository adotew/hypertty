import AppKit

/// The window's sidebar: the tab list above the git changes. ⌘S focuses the tabs, ⌘⇧E the changes;
/// ⇥ switches between them.
final class SidebarViewController: NSViewController {
    enum Mode { case tabs, changes }

    let tabList: TabListViewController
    let changes: ChangesViewController
    /// The list that has, or last had, keyboard focus.
    private(set) var mode: Mode = .tabs

    private let theme: Theme
    private var tabListHeight: NSLayoutConstraint!

    /// Clears the traffic lights (14pt buttons 9pt from the top).
    private static let topInset: CGFloat = 34

    init(theme: Theme) {
        self.theme = theme
        tabList = TabListViewController(theme: theme)
        changes = ChangesViewController(theme: theme)
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

        tabList.onSwitchMode = { [weak self] in self?.focus(.changes) }
        changes.onSwitchMode = { [weak self] in self?.focus(.tabs) }

        addChild(tabList)
        addChild(changes)
        for view in [tabList.view, changes.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            ])
        }
        // The tab list is as tall as its rows, up to half the sidebar.
        tabListHeight = tabList.view.heightAnchor.constraint(equalToConstant: 0)
        tabListHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            tabList.view.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.topInset),
            tabListHeight,
            tabList.view.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, multiplier: 0.5),
            changes.view.topAnchor.constraint(equalTo: tabList.view.bottomAnchor, constant: 6),
            changes.view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])

        view = root
    }

    // MARK: Tabs

    func update(tabs: [Tab], selectedIndex: Int?) {
        tabList.update(tabs: tabs, selectedIndex: selectedIndex)
        let table = tabList.tableView
        tabListHeight.constant = CGFloat(tabs.count) * (table.rowHeight + table.intercellSpacing.height)
    }

    func refresh(tab: Tab) {
        tabList.refresh(tab: tab)
    }

    func beginRename(at row: Int) {
        mode = .tabs
        tabList.beginRename(at: row)
    }

    // MARK: Focus

    var hasFocus: Bool { tabList.hasFocus || changes.hasFocus }

    func focus(_ mode: Mode) {
        self.mode = mode
        switch mode {
        case .tabs: tabList.focus()
        case .changes: changes.focus()
        }
    }
}

// MARK: - Views shared by the tab list and the changes

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

    /// Keeps a table's single column as wide as the sidebar.
    override func tile() {
        super.tile()
        (documentView as? NSTableView)?.sizeLastColumnToFit()
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
