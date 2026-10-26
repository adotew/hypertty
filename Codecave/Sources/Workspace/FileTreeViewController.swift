import AppKit

protocol FileTreeDelegate: AnyObject {
    func fileTree(_ tree: FileTreeViewController, open url: URL, inNewTab: Bool)
    func fileTreeFocusTerminal(_ tree: FileTreeViewController)
}

/// The sidebar's file tree, rooted at the git work tree (or directory) of
/// the focused pane, so it follows `cd` and pane switches. Keys:
///
///   j/k, ↓/↑   next/previous item
///   g/G        first/last item
///   l, →       expand folder / open file
///   h, ←       collapse folder / go to parent
///   ⏎          toggle folder / open file in a split to the right
///   t          open file in a new tab
///   .          show/hide git-ignored files
///   y          copy the path
///   esc        back to the terminal
///   ⇥          switch to the tab list
///
/// Files open in `$EDITOR` (nvim if unset).
final class FileTreeViewController: NSViewController {
    weak var delegate: FileTreeDelegate?
    /// ⇥ switches the sidebar to the tab list.
    var onSwitchMode: (() -> Void)?
    var onRootChange: (() -> Void)?

    let outlineView = FileOutlineView()
    private(set) var root: URL?

    private let theme: Theme
    private var lister = FileLister()
    private var rootNode: FileNode?
    private var watcher: DirectoryWatcher?
    /// Expanded folder paths, per root, so switching between projects keeps them.
    private var expandedByRoot: [String: Set<String>] = [:]
    /// Set while reloading, when expand/collapse notifications aren't the user's.
    private var isRestoring = false
    private var needsReload = false

    /// Hidden trees don't reload on file changes until shown.
    var isShown = false {
        didSet {
            view.isHidden = !isShown
            if isShown && needsReload { reload() }
        }
    }

    init(theme: Theme) {
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = 22
        // No gaps, so the indent guides are continuous.
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.indentationPerLevel = 0
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.focusRingType = .none
        outlineView.allowsTypeSelect = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        view = SidebarScrollView(documentView: outlineView)
    }

    // MARK: Root

    /// Shows the project containing `directory` (the focused pane's pwd).
    func setDirectory(_ directory: String) {
        let newRoot: URL? = ProjectRoot.containing(URL(fileURLWithPath: directory))
        guard newRoot != root else { return }
        root = newRoot
        lister.ignoredPaths = []
        watcher = newRoot.map { url in DirectoryWatcher(url: url) { [weak self] in self?.filesDidChange($0) } }
        // Show the files right away; ignored ones are marked once git answers.
        if isShown { reload() } else { needsReload = true }
        rootDidChange()
        onRootChange?()
    }

    /// Reloads if a changed directory is visible in the tree (or holds a
    /// visible folder), so churn elsewhere, like ~/Library, is ignored.
    private func filesDidChange(_ directories: [String]) {
        guard let root else { return }
        let shown = expanded.union([root.path])
        if directories.contains(where: { shown.contains($0) || shown.contains(($0 as NSString).deletingLastPathComponent) }) {
            rootDidChange()
        }
    }

    /// Re-reads git's ignored files, then the tree.
    private func rootDidChange() {
        guard let root else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ignored = ProjectRoot.ignoredPaths(in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                lister.ignoredPaths = ignored
                if isShown { reload() } else { needsReload = true }
            }
        }
    }

    private var expanded: Set<String> {
        get { root.flatMap { expandedByRoot[$0.path] } ?? [] }
        set { if let root { expandedByRoot[root.path] = newValue } }
    }

    /// Rebuilds the tree from disk, keeping expanded folders and the selection.
    private func reload() {
        needsReload = false
        let selectedPath = selectedNode?.path
        rootNode = root.map { FileNode(url: $0, name: $0.lastPathComponent, isDirectory: true, isIgnored: false) }
        isRestoring = true
        outlineView.reloadData()
        if let rootNode { restoreExpansion(under: rootNode) }
        isRestoring = false

        let row = selectedPath.flatMap(row(forPath:)) ?? 0
        if row < outlineView.numberOfRows {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    private func restoreExpansion(under node: FileNode) {
        let expanded = expanded
        for child in children(of: node) where child.isDirectory && expanded.contains(child.path) {
            outlineView.expandItem(child)
            restoreExpansion(under: child)
        }
    }

    private func row(forPath path: String) -> Int? {
        (0..<outlineView.numberOfRows).first { (outlineView.item(atRow: $0) as? FileNode)?.path == path }
    }

    private func children(of node: FileNode) -> [FileNode] {
        if let children = node.children { return children }
        let children = lister.children(of: node)
        node.children = children
        return children
    }

    // MARK: Focus

    var hasFocus: Bool { view.window?.firstResponder === outlineView }

    func focus() {
        if outlineView.selectedRow < 0 && outlineView.numberOfRows > 0 {
            outlineView.selectRowIndexes([0], byExtendingSelection: false)
        }
        view.window?.makeFirstResponder(outlineView)
    }

    // MARK: Input

    private var selectedNode: FileNode? {
        outlineView.item(atRow: outlineView.selectedRow) as? FileNode
    }

    @objc private func rowClicked() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode, node.isDirectory else { return }
        toggle(node)
    }

    @objc private func rowDoubleClicked() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode, !node.isDirectory else { return }
        delegate?.fileTree(self, open: node.url, inNewTab: false)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Leave command/control shortcuts to the menu.
        if !mods.isDisjoint(with: [.command, .control, .option]) { return false }

        let row = outlineView.selectedRow
        let node = selectedNode
        switch event.keyCode {
        case 36, 76: // return, enter
            if let node { node.isDirectory ? toggle(node) : open(node, inNewTab: false) }
            return true
        case 53: // escape
            delegate?.fileTreeFocusTerminal(self)
            return true
        case 48: // tab
            onSwitchMode?()
            return true
        case 123: // left arrow
            collapseOrGoToParent(node)
            return true
        case 124: // right arrow
            expandOrOpen(node)
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers {
        case "j": select(row + 1)
        case "k": select(row - 1)
        case "g": select(0)
        case "G": select(outlineView.numberOfRows - 1)
        case "l": expandOrOpen(node)
        case "h": collapseOrGoToParent(node)
        case "t": if let node, !node.isDirectory { open(node, inNewTab: true) }
        case ".":
            lister.showsIgnored.toggle()
            reload()
        case "y":
            guard let node else { break }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        default:
            return false
        }
        return true
    }

    private func select(_ row: Int) {
        guard outlineView.numberOfRows > 0 else { return }
        let row = max(0, min(row, outlineView.numberOfRows - 1))
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    private func toggle(_ node: FileNode) {
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    private func expandOrOpen(_ node: FileNode?) {
        guard let node else { return }
        guard node.isDirectory else { return open(node, inNewTab: false) }
        if outlineView.isItemExpanded(node) {
            select(outlineView.selectedRow + 1)
        } else {
            outlineView.expandItem(node)
        }
    }

    private func collapseOrGoToParent(_ node: FileNode?) {
        guard let node else { return }
        if node.isDirectory && outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else if let parent = outlineView.parent(forItem: node) {
            select(outlineView.row(forItem: parent))
        }
    }

    private func open(_ node: FileNode, inNewTab: Bool) {
        delegate?.fileTree(self, open: node.url, inNewTab: inNewTab)
    }
}

// MARK: - Outline

extension FileTreeViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode ?? rootNode else { return 0 }
        return children(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = item as? FileNode ?? rootNode!
        return children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? FileCellView ?? {
            let cell = FileCellView(theme: theme)
            cell.identifier = id
            return cell
        }()
        cell.configure(node: node, level: outlineView.level(forItem: node),
                       expanded: outlineView.isItemExpanded(node))
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView(theme: theme, radius: 5)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        outlineView.reloadItem(node, reloadChildren: false)
        guard !isRestoring else { return }
        expanded.insert(node.path)
        // Reopen folders that were expanded inside it.
        isRestoring = true
        restoreExpansion(under: node)
        isRestoring = false
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        outlineView.reloadItem(node, reloadChildren: false)
        guard !isRestoring else { return }
        expanded.remove(node.path)
    }
}

// MARK: - Views

/// Indentation, chevrons and guides are drawn by the cells, so the outline
/// itself doesn't indent or show disclosure triangles.
final class FileOutlineView: NSOutlineView {
    /// Return true if the key was handled.
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        return NSRect(x: 0, y: frame.minY, width: bounds.width, height: frame.height)
    }
}

/// A row: indent guides, then a chevron (folders) or file icon, then the name.
private final class FileCellView: NSTableCellView {
    static let indent: CGFloat = 14
    static let leading: CGFloat = 6
    static let iconSize: CGFloat = 16

    private let theme: Theme
    private let icon = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private var iconLeading: NSLayoutConstraint!
    private var level = 0

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        textField = nameField
        imageView = icon

        nameField.font = .systemFont(ofSize: 12.5)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyDown

        for view in [icon, nameField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leading)
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            nameField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Keep our own colors instead of AppKit's selected-row text colors.
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set {}
    }

    func configure(node: FileNode, level: Int, expanded: Bool) {
        self.level = level
        iconLeading.constant = Self.leading + CGFloat(level) * Self.indent
        nameField.stringValue = node.name
        nameField.textColor = node.isIgnored ? theme.secondaryText : theme.foreground
        toolTip = node.name.contains(" / ") ? node.path : nil

        if node.isDirectory {
            let symbol = expanded ? "chevron.down" : "chevron.right"
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            icon.contentTintColor = theme.foreground.withAlphaComponent(node.isIgnored ? 0.3 : 0.6)
            icon.alphaValue = 1
        } else {
            icon.image = FileIcons.image(forFileNamed: node.url.lastPathComponent, dark: theme.isDark)
            icon.contentTintColor = nil
            icon.alphaValue = node.isIgnored ? 0.5 : 1
        }
        needsDisplay = true
    }

    /// Guides line up under each ancestor folder's chevron.
    override func draw(_ dirtyRect: NSRect) {
        guard level > 0 else { return }
        theme.foreground.withAlphaComponent(0.12).setFill()
        let scale = window?.backingScaleFactor ?? 2
        for ancestor in 0..<level {
            let x = Self.leading + CGFloat(ancestor) * Self.indent + Self.iconSize / 2
            NSRect(x: x.rounded(.down), y: bounds.minY - 1, width: 1 / scale, height: bounds.height + 2).fill()
        }
    }
}
