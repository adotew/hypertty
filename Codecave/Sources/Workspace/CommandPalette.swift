import AppKit

/// Cmd+Shift+P: a floating list of the app's menu commands, filtered as you
/// type. Return runs the selected command; Escape or clicking away dismisses.
final class CommandPalette: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let width: CGFloat = 500
    private static let fieldHeight: CGFloat = 48
    private static let rowHeight: CGFloat = 44
    private static let listPadding: CGFloat = 10
    private static let maxListHeight: CGFloat = 200

    struct Command {
        let title: String
        let group: String
        let symbols: [String]
        let path: String
        let item: NSMenuItem
    }

    /// Every enabled menu item with an action, grouped by its menu path.
    static func menuCommands(in menu: NSMenu?, group: String = "") -> [Command] {
        guard let menu else { return [] }
        return menu.items.flatMap { item -> [Command] in
            guard !item.isSeparatorItem, !item.title.isEmpty else { return [] }
            if let submenu = item.submenu {
                let subgroup = group.isEmpty ? item.title : group + " › " + item.title
                return menuCommands(in: submenu, group: subgroup)
            }
            guard let action = item.action, action != #selector(WorkspaceWindowController.showCommandPalette(_:)),
                  item.target != nil || NSApp.target(forAction: action) != nil else { return [] }
            let path = group.isEmpty ? item.title : group + " " + item.title
            return [Command(title: item.title, group: group, symbols: symbols(for: item), path: path, item: item)]
        }
    }

    private static func symbols(for item: NSMenuItem) -> [String] {
        guard !item.keyEquivalent.isEmpty else { return [] }
        let modifiers = item.keyEquivalentModifierMask
        var symbols: [String] = []
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        // An uppercase key equivalent implies Shift.
        if modifiers.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        symbols.append(keyNames[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
        return symbols
    }

    /// Keys without a printable glyph; arrows etc. are private-use characters.
    private static let keyNames: [String: String] = {
        var names = ["\t": "⇥", "\r": "↩", "\u{1B}": "⎋", " ": "Space", "\u{8}": "⌫"]
        let functionKeys = [
            NSUpArrowFunctionKey: "↑", NSDownArrowFunctionKey: "↓",
            NSLeftArrowFunctionKey: "←", NSRightArrowFunctionKey: "→",
            NSHomeFunctionKey: "↖", NSEndFunctionKey: "↘",
            NSPageUpFunctionKey: "⇞", NSPageDownFunctionKey: "⇟", NSDeleteFunctionKey: "⌦",
        ]
        for (code, name) in functionKeys {
            if let scalar = UnicodeScalar(code) { names[String(scalar)] = name }
        }
        return names
    }()

    private let commands: [Command]
    private var matches: [Command] = []
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No matches")
    private var listHeight: NSLayoutConstraint?

    init(commands: [Command], dark: Bool) {
        self.commands = commands
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        field.placeholderString = "Execute a command…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .light)
        field.cell?.usesSingleLineMode = true
        field.delegate = self

        table.addTableColumn(NSTableColumn(identifier: .init("command")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.listPadding, left: 0, bottom: Self.listPadding, right: 0)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator

        let container = NSView()
        for view in [field, divider, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        container.addSubview(emptyLabel)
        let height = scroll.heightAnchor.constraint(equalToConstant: 0)
        listHeight = height
        NSLayoutConstraint.activate([
            field.centerYAnchor.constraint(equalTo: container.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            divider.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.fieldHeight),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            height,
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        let glass = NSGlassEffectView()
        glass.cornerRadius = 10
        glass.contentView = container
        contentView = glass
    }

    override var canBecomeKey: Bool { true }

    func show(over parent: NSWindow) {
        parent.addChildWindow(self, ordered: .above)
        refresh()
        setFrameTopLeftPoint(NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.maxY - 100))
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    override func resignKey() {
        super.resignKey()
        dismiss(refocusParent: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            guard table.selectedRow >= 0 else { return true }
            run(matches[table.selectedRow])
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(refocusParent: true)
        default:
            return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        matches.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CommandRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = matches[row]
        let title = NSTextField(labelWithString: command.title)
        let group = NSTextField(labelWithString: command.group)
        group.font = .systemFont(ofSize: 11)
        group.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, group])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let keys = NSStackView(views: command.symbols.map(Self.keyLabel))
        keys.spacing = 1

        let cell = NSTableCellView()
        for view in [text, keys] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            keys.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -18),
            keys.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static func keyLabel(_ symbol: String) -> NSTextField {
        let label = NSTextField(labelWithString: symbol)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 13).isActive = true
        return label
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        run(matches[table.clickedRow])
    }

    private func refresh() {
        let query = field.stringValue
        matches = query.isEmpty ? commands : commands.filter { $0.path.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if !matches.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        emptyLabel.isHidden = !matches.isEmpty
        let rows = min(CGFloat(matches.count) * Self.rowHeight, Self.maxListHeight)
        let list = matches.isEmpty ? Self.rowHeight : rows + 2 * Self.listPadding
        listHeight?.constant = list
        let height = Self.fieldHeight + 1 + list
        setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: Self.width, height: height), display: true)
    }

    private func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), matches.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func run(_ command: Command) {
        dismiss(refocusParent: true)
        guard let menu = command.item.menu else { return }
        menu.performActionForItem(at: menu.index(of: command.item))
    }

    func dismiss(refocusParent: Bool) {
        guard let parent else { return }
        parent.removeChildWindow(self)
        orderOut(nil)
        if refocusParent { parent.makeKey() }
    }
}

/// Rounded accent highlight inset from the list edges, as in Ghostty's palette.
private final class CommandRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 2), xRadius: 5, yRadius: 5).fill()
    }
}
