import AppKit

/// The window's sidebar: the project and branch in the titlebar, then the
/// tab list above the git changes. ⌘S focuses the tabs, ⌘⇧E the changes;
/// ⇥ switches between them.
final class SidebarViewController: NSViewController {
    enum Mode { case tabs, changes }

    let tabList: TabListViewController
    let changes: ChangesViewController
    /// The list that has, or last had, keyboard focus.
    private(set) var mode: Mode = .tabs

    private let theme: Theme
    private let projectLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private var tabListHeight: NSLayoutConstraint!

    /// Puts the header in the titlebar, right of the traffic lights
    /// (14pt buttons 9pt from the top, the last ending at x = 69).
    private static let topInset: CGFloat = 4
    private static let leadingInset: CGFloat = 80

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
        changes.onStatusChange = { [weak self] in self?.updateHeader() }

        projectLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        projectLabel.textColor = theme.foreground
        projectLabel.lineBreakMode = .byTruncatingTail
        projectLabel.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        branchLabel.font = .systemFont(ofSize: 11.5)
        branchLabel.textColor = theme.secondaryText
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.setContentCompressionResistancePriority(.init(730), for: .horizontal)

        let header = NSStackView(views: [projectLabel, branchLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        let tabsTitle = SectionHeaderView(theme: theme)
        tabsTitle.configure(title: "Tabs")
        tabsTitle.translatesAutoresizingMaskIntoConstraints = false

        addChild(tabList)
        addChild(changes)
        for view in [header, tabsTitle, tabList.view, changes.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        // The tab list is as tall as its rows, up to half the sidebar.
        tabListHeight = tabList.view.heightAnchor.constraint(equalToConstant: 0)
        tabListHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.topInset),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.leadingInset),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 24),

            tabsTitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            tabsTitle.heightAnchor.constraint(equalToConstant: 22),
            tabList.view.topAnchor.constraint(equalTo: tabsTitle.bottomAnchor),
            tabListHeight,
            tabList.view.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, multiplier: 0.5),
            changes.view.topAnchor.constraint(equalTo: tabList.view.bottomAnchor, constant: 6),
            changes.view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        for view in [tabsTitle, tabList.view, changes.view] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            ])
        }

        view = root
        updateHeader()
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

    private func updateHeader() {
        projectLabel.stringValue = changes.root?.lastPathComponent ?? ""
        projectLabel.toolTip = changes.root.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        guard let status = changes.status else {
            branchLabel.stringValue = ""
            return
        }
        var branch = status.branch
        if status.ahead > 0 { branch += " ↑\(status.ahead)" }
        if status.behind > 0 { branch += " ↓\(status.behind)" }
        branchLabel.stringValue = branch
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
