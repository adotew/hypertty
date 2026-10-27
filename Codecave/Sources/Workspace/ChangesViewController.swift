import AppKit

protocol ChangesDelegate: AnyObject {
    func changes(_ changes: ChangesViewController, open url: URL, inNewTab: Bool)
    func changesFocusTerminal(_ changes: ChangesViewController)
}

/// The sidebar's list of changed files in the git work tree of the focused
/// pane, so it follows `cd` and pane switches. Keys:
///
///   j/k, ↓/↑   next/previous file
///   g/G        first/last file
///   l, ⏎       open in a split to the right
///   t          open in a new tab
///   s          stage / unstage
///   y          copy the path
///   esc        back to the terminal
///   ⇥          switch to the tab list
///
/// Files open in `$EDITOR` (nvim if unset).
final class ChangesViewController: NSViewController {
    weak var delegate: ChangesDelegate?
    /// ⇥ switches to the tab list.
    var onSwitchMode: (() -> Void)?
    /// The branch or the project changed.
    var onStatusChange: (() -> Void)?

    let tableView = SidebarTableView()
    private(set) var root: URL?
    /// Nil outside a git work tree.
    private(set) var status: GitStatus?

    private enum Row {
        case header(String, count: Int)
        case change(GitChange)
    }

    private let theme: Theme
    private let placeholder = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var watcher: DirectoryWatcher?
    private var isLoading = false
    private var needsLoad = false

    init(theme: Theme) {
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("change"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.focusRingType = .none
        tableView.allowsTypeSelect = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = theme.secondaryText
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = SidebarScrollView(documentView: tableView)
        scrollView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 4),
            placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 10),
        ])
        view = scrollView
    }

    // MARK: Status

    /// Shows the project containing `directory` (the focused pane's pwd).
    func setDirectory(_ directory: String) {
        let newRoot = ProjectRoot.containing(URL(fileURLWithPath: directory))
        guard newRoot != root else { return }
        root = newRoot
        watcher = DirectoryWatcher(url: newRoot) { [weak self] in self?.load() }
        load()
    }

    /// Runs `git status` in the background, at most once at a time.
    private func load() {
        guard let root else { return }
        guard !isLoading else {
            needsLoad = true
            return
        }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = Git.status(in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isLoading = false
                if self.root == root { show(status) }
                if needsLoad {
                    needsLoad = false
                    load()
                }
            }
        }
    }

    private func show(_ newStatus: GitStatus?) {
        guard newStatus != status || rows.isEmpty else { return }
        let selected = selectedChange
        status = newStatus

        rows = []
        if let status {
            for (title, changes) in [("Staged", status.staged), ("Changes", status.unstaged)] where !changes.isEmpty {
                rows.append(.header(title, count: changes.count))
                rows += changes.map(Row.change)
            }
        }
        placeholder.stringValue = status == nil ? "Not a git repository" : "No changes"
        placeholder.isHidden = !rows.isEmpty
        tableView.reloadData()

        let row = selected.flatMap { selected in rows.firstIndex { change(in: $0) == selected } }
        if let row { tableView.selectRowIndexes([row], byExtendingSelection: false) }
        if hasFocus && tableView.selectedRow < 0 { select(0, step: 1) }
        onStatusChange?()
    }

    // MARK: Focus

    var hasFocus: Bool { view.window?.firstResponder === tableView }

    func focus() {
        if tableView.selectedRow < 0 { select(0, step: 1) }
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: Input

    private func change(in row: Row) -> GitChange? {
        if case .change(let change) = row { return change }
        return nil
    }

    private var selectedChange: GitChange? {
        rows.indices.contains(tableView.selectedRow) ? change(in: rows[tableView.selectedRow]) : nil
    }

    @objc private func rowDoubleClicked() {
        guard rows.indices.contains(tableView.clickedRow),
              let change = change(in: rows[tableView.clickedRow]) else { return }
        open(change, inNewTab: false)
    }

    /// Keys handled by key code, as the characters they act like.
    private static let keyCodes: [UInt16: String] = [
        36: "\r", 76: "\r", 53: "\u{1b}", 48: "\t", 125: "j", 126: "k",
    ]

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Leave command/control shortcuts to the menu.
        if !mods.isDisjoint(with: [.command, .control, .option]) { return false }
        guard let key = Self.keyCodes[event.keyCode] ?? event.charactersIgnoringModifiers else { return false }
        return navigate(key) || act(key)
    }

    private func navigate(_ key: String) -> Bool {
        let row = tableView.selectedRow
        switch key {
        case "j": select(row + 1, step: 1)
        case "k": select(row - 1, step: -1)
        case "g": select(0, step: 1)
        case "G": select(rows.count - 1, step: -1)
        case "\u{1b}": delegate?.changesFocusTerminal(self)
        case "\t": onSwitchMode?()
        default: return false
        }
        return true
    }

    /// Keys that act on the selected file.
    private func act(_ key: String) -> Bool {
        guard ["\r", "l", "t", "s", "y"].contains(key) else { return false }
        guard let change = selectedChange, let root else { return true }
        switch key {
        case "t": open(change, inNewTab: true)
        case "s": toggleStaged(change)
        case "y":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(root.appendingPathComponent(change.path).path, forType: .string)
        default: open(change, inNewTab: false)
        }
        return true
    }

    /// Selects `row`, or the nearest file from it in the `step` direction,
    /// skipping headers.
    private func select(_ row: Int, step: Int) {
        var row = max(0, min(row, rows.count - 1))
        while rows.indices.contains(row), change(in: rows[row]) == nil { row += step }
        guard rows.indices.contains(row) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func open(_ change: GitChange, inNewTab: Bool) {
        guard let root else { return }
        delegate?.changes(self, open: root.appendingPathComponent(change.path), inNewTab: inNewTab)
    }

    private func toggleStaged(_ change: GitChange) {
        guard let root else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if change.staged {
                Git.unstage(change.path, in: root)
            } else {
                Git.stage(change.path, in: root)
            }
            DispatchQueue.main.async { self?.load() }
        }
    }
}

// MARK: - Table

extension ChangesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title, let count):
            let id = NSUserInterfaceItemIdentifier("SectionHeader")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? SectionHeaderView ?? {
                let cell = SectionHeaderView(theme: theme)
                cell.identifier = id
                return cell
            }()
            cell.configure(title: title, count: count)
            return cell
        case .change(let change):
            let id = NSUserInterfaceItemIdentifier("ChangeCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? ChangeCellView ?? {
                let cell = ChangeCellView(theme: theme)
                cell.identifier = id
                return cell
            }()
            cell.configure(change: change)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return row == 0 ? 22 : 30 }
        return 24
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        change(in: rows[row]) != nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView(theme: theme, radius: 5)
    }
}

// MARK: - Views

/// "Staged 2": a section title in the sidebar.
final class SectionHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(theme: Theme) {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = theme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, count: Int? = nil) {
        label.stringValue = count.map { "\(title)  \($0)" } ?? title
    }
}

/// A file icon, the file name, its directory, and the status letter.
private final class ChangeCellView: NSTableCellView {
    private let theme: Theme
    private let icon = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let directoryField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)

        nameField.font = .systemFont(ofSize: 12.5)
        nameField.textColor = theme.foreground
        nameField.lineBreakMode = .byTruncatingMiddle
        directoryField.font = .systemFont(ofSize: 11)
        directoryField.textColor = theme.secondaryText
        directoryField.lineBreakMode = .byTruncatingHead
        statusField.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        icon.imageScaling = .scaleProportionallyDown

        // The name gives way last, the directory first.
        nameField.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        directoryField.setContentCompressionResistancePriority(.init(730), for: .horizontal)
        directoryField.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [icon, nameField, directoryField, statusField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.setCustomSpacing(5, after: nameField)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
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

    func configure(change: GitChange) {
        let path = change.path.hasSuffix("/") ? String(change.path.dropLast()) : change.path
        let name = (path as NSString).lastPathComponent
        directoryField.stringValue = (path as NSString).deletingLastPathComponent
        toolTip = change.path

        icon.image = change.path.hasSuffix("/")
            ? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            : FileIcons.image(forFileNamed: name, dark: theme.isDark)
        icon.contentTintColor = theme.secondaryText

        statusField.stringValue = change.status == "?" ? "U" : String(change.status)
        statusField.toolTip = change.status == "?" ? "Untracked" : nil
        switch change.status {
        case "A", "?": statusField.textColor = theme.added
        case "D", "U": statusField.textColor = theme.deleted
        case "M": statusField.textColor = theme.modified
        default: statusField.textColor = theme.accent
        }
        // Deleted files are struck through, like in most git UIs.
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        nameField.attributedStringValue = NSAttributedString(string: name, attributes: [
            .strikethroughStyle: change.status == "D" ? NSUnderlineStyle.single.rawValue : 0,
            .foregroundColor: change.status == "D" ? theme.secondaryText : theme.foreground,
            .font: nameField.font as Any,
            .paragraphStyle: style,
        ])
    }
}
