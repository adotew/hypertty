import AppKit

protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelectTabAt index: Int, focusTerminal: Bool)
    func sidebarNewTab(_ sidebar: SidebarViewController)
    func sidebar(_ sidebar: SidebarViewController, closeTabAt index: Int)
    func sidebar(_ sidebar: SidebarViewController, moveTabAt index: Int, by offset: Int)
    /// `title` is nil if renaming was cancelled, empty to reset to the shell's title.
    func sidebar(_ sidebar: SidebarViewController, didRenameTabAt index: Int, to title: String?)
    func sidebarFocusTerminal(_ sidebar: SidebarViewController)
}

/// The vertical tab list. When it has keyboard focus it works like a
/// small vim buffer:
///
///   j/k, ↓/↑   select next/previous tab (shows it without leaving the sidebar)
///   g/G        first/last tab
///   1-9        go to tab N
///   J/K        move the tab down/up
///   n          new tab
///   x          close tab
///   r          rename tab (empty name resets it)
///   l, ⏎, esc  back to the terminal
final class SidebarViewController: NSViewController {
    weak var delegate: SidebarDelegate?
    let tableView = SidebarTableView()

    private let theme: Theme
    private var tabs: [Tab] = []
    /// Set while we change the selection programmatically.
    private var isUpdating = false
    private var renamingRow: Int?
    private var renameCancelled = false

    /// Room for the window's traffic lights above the list.
    private static let topInset: CGFloat = 40

    init(theme: Theme) {
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = FillView(color: theme.sidebarBackground)
        root.frame = NSRect(x: 0, y: 0, width: 220, height: 600)

        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = false
        tableView.allowsTypeSelect = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.topInset),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
        ])

        view = root
    }

    // MARK: Updates from the window controller

    func update(tabs: [Tab], selectedIndex: Int?) {
        self.tabs = tabs
        // Reloading would end an in-progress rename; it reloads when done.
        guard renamingRow == nil else { return }

        isUpdating = true
        defer { isUpdating = false }
        tableView.reloadData()
        if let selectedIndex {
            tableView.selectRowIndexes([selectedIndex], byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    func refresh(tab: Tab) {
        guard renamingRow == nil, let row = tabs.firstIndex(where: { $0 === tab }) else { return }
        tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
    }

    var hasFocus: Bool {
        guard let responder = view.window?.firstResponder else { return false }
        if responder === tableView { return true }
        // The field editor while renaming.
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSView,
           field.isDescendant(of: tableView) { return true }
        return false
    }

    func focus() {
        view.window?.makeFirstResponder(tableView)
    }

    func beginRename(at row: Int) {
        guard row >= 0, row < tabs.count,
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabCellView
        else { return }
        renamingRow = row
        renameCancelled = false
        cell.titleField.isEditable = true
        cell.titleField.delegate = self
        cell.titleField.stringValue = tabs[row].title
        view.window?.makeFirstResponder(cell.titleField)
        cell.titleField.currentEditor()?.selectAll(nil)
    }

    // MARK: Input

    @objc private func rowClicked() {
        guard tableView.clickedRow >= 0 else { return }
        delegate?.sidebar(self, didSelectTabAt: tableView.clickedRow, focusTerminal: true)
    }

    @objc private func rowDoubleClicked() {
        beginRename(at: tableView.clickedRow)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Leave command/control shortcuts to the menu.
        if !mods.isDisjoint(with: [.command, .control, .option]) { return false }

        let row = tableView.selectedRow
        switch event.keyCode {
        case 36, 76, 53: // return, enter, escape
            delegate?.sidebarFocusTerminal(self)
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers {
        case "j": select(row + 1)
        case "k": select(row - 1)
        case "g": select(0)
        case "G": select(tabs.count - 1)
        case "J": delegate?.sidebar(self, moveTabAt: row, by: 1)
        case "K": delegate?.sidebar(self, moveTabAt: row, by: -1)
        case "l": delegate?.sidebarFocusTerminal(self)
        case "n": delegate?.sidebarNewTab(self)
        case "x": delegate?.sidebar(self, closeTabAt: row)
        case "r": beginRename(at: row)
        case let digit? where digit.count == 1 && ("1"..."9").contains(digit):
            let index = min(Int(digit)! - 1, tabs.count - 1)
            delegate?.sidebar(self, didSelectTabAt: index, focusTerminal: true)
        default:
            return false
        }
        return true
    }

    private func select(_ row: Int) {
        guard !tabs.isEmpty else { return }
        let row = max(0, min(row, tabs.count - 1))
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }
}

// MARK: - Table

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tabs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("TabCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? TabCellView ?? {
            let cell = TabCellView(theme: theme)
            cell.identifier = id
            return cell
        }()
        cell.configure(tab: tabs[row], index: row, selected: tableView.selectedRow == row)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TabRowView(theme: theme)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Selected/unselected cells style differently (bell dot).
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tabs.count), columnIndexes: [0])
        guard !isUpdating, tableView.selectedRow >= 0 else { return }
        delegate?.sidebar(self, didSelectTabAt: tableView.selectedRow, focusTerminal: false)
    }
}

// MARK: - Renaming

extension SidebarViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            renameCancelled = true
            view.window?.makeFirstResponder(tableView)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            view.window?.makeFirstResponder(tableView)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let row = renamingRow else { return }
        field.isEditable = false
        renamingRow = nil
        let title = renameCancelled ? nil : field.stringValue.trimmingCharacters(in: .whitespaces)
        renameCancelled = false
        // We're inside makeFirstResponder(tableView) here; let it finish so
        // the delegate can move focus elsewhere (e.g. back to the terminal).
        DispatchQueue.main.async {
            self.delegate?.sidebar(self, didRenameTabAt: row, to: title)
        }
    }
}

// MARK: - Views

final class SidebarTableView: NSTableView {
    /// Return true if the key was handled.
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }
}

/// Rounded selection; outlined in the accent color while the sidebar
/// has keyboard focus.
private final class TabRowView: NSTableRowView {
    private let theme: Theme

    init(theme: Theme) {
        self.theme = theme
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
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        theme.selection.setFill()
        path.fill()
        if isEmphasized {
            theme.accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}

final class TabCellView: NSTableCellView {
    let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")
    private let bellDot = FillView(color: .clear)
    private let theme: Theme

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        textField = titleField

        titleField.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleField.textColor = theme.foreground
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.focusRingType = .none

        subtitleField.font = .systemFont(ofSize: 10.5)
        subtitleField.textColor = theme.secondaryText
        subtitleField.lineBreakMode = .byTruncatingHead

        shortcutField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        shortcutField.textColor = theme.secondaryText

        bellDot.color = theme.accent
        bellDot.wantsLayer = true
        bellDot.layer?.cornerRadius = 3
        bellDot.layer?.masksToBounds = true

        for field in [titleField, subtitleField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let text = NSStackView(views: [titleField, subtitleField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        // The title block takes all spare width so the shortcut sits at the right edge.
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutField.setContentHuggingPriority(.required, for: .horizontal)
        shortcutField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [text, bellDot, shortcutField])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            bellDot.widthAnchor.constraint(equalToConstant: 6),
            bellDot.heightAnchor.constraint(equalToConstant: 6),
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

    func configure(tab: Tab, index: Int, selected: Bool) {
        titleField.stringValue = tab.title
        subtitleField.stringValue = tab.subtitle ?? ""
        subtitleField.isHidden = tab.subtitle == nil
        bellDot.isHidden = !tab.hasBell || selected
        shortcutField.stringValue = index < 9 ? "⌘\(index + 1)" : ""
    }
}
