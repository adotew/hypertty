import AppKit

protocol TabListDelegate: AnyObject {
    func tabList(_ list: TabListViewController, didSelectTabAt index: Int, focusTerminal: Bool)
    func tabListNewTab(_ list: TabListViewController)
    func tabList(_ list: TabListViewController, closeTabAt index: Int)
    func tabList(_ list: TabListViewController, moveTabAt index: Int, by offset: Int)
    /// `title` is nil if renaming was cancelled, empty to reset to the folder name.
    func tabList(_ list: TabListViewController, didRenameTabAt index: Int, to title: String?)
    func tabListFocusTerminal(_ list: TabListViewController)
}

/// The sidebar's vertical tab list. When it has keyboard focus it works
/// like a small vim buffer:
///
///   j/k, ↓/↑   select next/previous tab (shows it without leaving the sidebar)
///   g/G        first/last tab
///   1-9        go to tab N
///   J/K        move the tab down/up
///   n          new tab
///   x          close tab
///   r          rename tab (empty name resets it)
///   l, ⏎, esc  back to the terminal
final class TabListViewController: NSViewController {
    weak var delegate: TabListDelegate?
    let tableView = SidebarTableView()

    private let theme: Theme
    private(set) var tabs: [Tab] = []
    /// Set while we change the selection programmatically.
    private var isUpdating = false
    private var renamingRow: Int?
    private var renameCancelled = false

    init(theme: Theme) {
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.rowHeight = 28
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

        view = SidebarScrollView(documentView: tableView)
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
        delegate?.tabList(self, didSelectTabAt: tableView.clickedRow, focusTerminal: true)
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
            delegate?.tabListFocusTerminal(self)
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers {
        case "j": select(row + 1)
        case "k": select(row - 1)
        case "g": select(0)
        case "G": select(tabs.count - 1)
        case "J": delegate?.tabList(self, moveTabAt: row, by: 1)
        case "K": delegate?.tabList(self, moveTabAt: row, by: -1)
        case "l": delegate?.tabListFocusTerminal(self)
        case "n": delegate?.tabListNewTab(self)
        case "x": delegate?.tabList(self, closeTabAt: row)
        case "r": beginRename(at: row)
        case let digit? where digit.count == 1 && ("1"..."9").contains(digit):
            let index = min(Int(digit)! - 1, tabs.count - 1)
            delegate?.tabList(self, didSelectTabAt: index, focusTerminal: true)
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

extension TabListViewController: NSTableViewDataSource, NSTableViewDelegate {
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
        cell.configure(tab: tabs[row], selected: tableView.selectedRow == row)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView(theme: theme)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Selected/unselected cells style differently (bell dot).
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tabs.count), columnIndexes: [0])
        guard !isUpdating, tableView.selectedRow >= 0 else { return }
        delegate?.tabList(self, didSelectTabAt: tableView.selectedRow, focusTerminal: false)
    }
}

// MARK: - Renaming

extension TabListViewController: NSTextFieldDelegate {
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
            self.delegate?.tabList(self, didRenameTabAt: row, to: title)
        }
    }
}

// MARK: - Views

final class TabCellView: NSTableCellView {
    let titleField = NSTextField(labelWithString: "")
    private let icon: IconTileView
    private let bellDot = FillView(color: .clear)
    private let theme: Theme

    init(theme: Theme) {
        self.theme = theme
        icon = IconTileView(theme: theme)
        super.init(frame: .zero)
        textField = titleField

        titleField.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleField.textColor = theme.foreground
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.focusRingType = .none

        bellDot.color = theme.accent
        bellDot.wantsLayer = true
        bellDot.layer?.cornerRadius = 3
        bellDot.layer?.masksToBounds = true

        // The title takes all spare width so the bell dot sits at the right edge.
        titleField.setContentHuggingPriority(.init(1), for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, titleField, bellDot])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
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

    func configure(tab: Tab, selected: Bool) {
        titleField.stringValue = tab.title
        icon.image = tab.icon
        icon.hasBackground = !(tab.focused is WebPaneView)
        bellDot.isHidden = !tab.hasBell || selected
    }
}

/// An app-icon-like tile: a rounded, softly lit square with a drop shadow
/// and the image on top. Drawn (not layer-styled) so it shows up in
/// DebugSnapshot's captures.
final class IconTileView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var hasBackground = true {
        didSet { needsDisplay = true }
    }

    private let theme: Theme

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hasBackground else {
            if let image {
                let glyph = fitted(image.size, in: bounds)
                image.draw(in: glyph)
            }
            return
        }

        // Room for the shadow, which falls downward.
        let tile = NSRect(x: 1, y: 1.5, width: bounds.width - 2, height: bounds.height - 2)
        let path = NSBezierPath(roundedRect: tile, xRadius: 5, yRadius: 5)
        let base = theme.background
        let (top, bottom) = theme.isDark
            ? (base.blended(withFraction: 0.1, of: .white), base.blended(withFraction: 0.15, of: .black))
            : (NSColor.white, base.blended(withFraction: 0.08, of: .black))

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(theme.isDark ? 0.5 : 0.2)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.set()
        (bottom ?? base).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: bottom ?? base, ending: top ?? base)?.draw(in: path, angle: 90)
        // A thin light edge along the top only, fading out down the sides,
        // like light falling on a macOS app icon.
        let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 0.25, dy: 0.25), xRadius: 4.75, yRadius: 4.75)
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.addPath(edge.cgPath)
            context.setLineWidth(0.5)
            context.replacePathWithStrokedPath()
            context.clip()
            let light = NSColor.white.withAlphaComponent(theme.isDark ? 0.35 : 0.8)
            NSGradient(colorsAndLocations: (.clear, 0.6), (light, 1))?.draw(in: tile, angle: 90)
            context.restoreGState()
        }

        guard let image else { return }
        let glyph = fitted(image.size, in: tile.insetBy(dx: 4, dy: 4))
        if image.isTemplate {
            // Symbols and single-color logos take the text color.
            let tinted = NSImage(size: glyph.size, flipped: false) { rect in
                image.draw(in: rect)
                self.theme.foreground.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: glyph)
        } else {
            image.draw(in: glyph)
        }
    }

    /// The largest rect with `size`'s aspect ratio, centered in `rect`.
    private func fitted(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}
