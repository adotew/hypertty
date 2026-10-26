import AppKit
import GhosttyKit

/// A window with a vertical tab sidebar and one terminal per tab.
///
/// Tab shortcuts are Ghostty keybinds (new_tab, goto_tab, next_tab,
/// move_tab, close_tab, ...), so they follow your Ghostty config. The menu
/// items mirror Ghostty's defaults for when the sidebar has focus.
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private let runtime: GhosttyRuntime
    private(set) var tabs: [Tab] = []
    private(set) var selectedTab: Tab?
    var onClose: ((WorkspaceWindowController) -> Void)?

    private let splitViewController = NSSplitViewController()
    private let sidebar: SidebarViewController
    private let content: TerminalContainerViewController
    private let sidebarItem: NSSplitViewItem
    /// The sidebar was revealed by focusTabSidebar and hides again when
    /// focus returns to the terminal.
    private var sidebarPeeking = false
    /// A rename started from the terminal (prompt_title) returns there.
    private var renameReturnsToTerminal = false

    init(runtime: GhosttyRuntime, options: SurfaceOptions = .init()) {
        self.runtime = runtime
        let theme = Theme(runtime: runtime)
        sidebar = SidebarViewController(theme: theme)
        content = TerminalContainerViewController(background: theme.background)
        sidebarItem = NSSplitViewItem(viewController: sidebar)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = theme.background
        window.minSize = NSSize(width: 480, height: 240)

        super.init(window: window)
        window.delegate = self
        sidebar.delegate = self

        let splitView = ThemedSplitView(dividerColor: theme.divider)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitViewController.splitView = splitView

        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 420
        // Window resizes go to the terminal, not the sidebar.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 300
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)

        window.contentViewController = splitViewController
        window.setContentSize(NSSize(width: 1100, height: 680))

        addTab(options: options)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(cascadingFrom other: NSWindow?) {
        guard let window else { return }
        if let other {
            window.setFrameTopLeftPoint(other.cascadeTopLeft(from: NSPoint(x: other.frame.minX, y: other.frame.maxY)))
        } else {
            window.center()
        }
        showWindow(nil)
        focusTerminal()

        #if DEBUG
        DebugSnapshot.scheduleIfRequested(for: self)
        #endif
    }

    // MARK: Tabs

    var selectedIndex: Int? {
        guard let selectedTab else { return nil }
        return tabs.firstIndex { $0 === selectedTab }
    }

    /// Adds a tab after the selected one, inheriting its working directory.
    @discardableResult
    func addTab(options: SurfaceOptions? = nil) -> Tab? {
        guard let app = runtime.app else { return nil }
        let options = options ?? SurfaceOptions(inheriting: selectedTab?.terminal, context: GHOSTTY_SURFACE_CONTEXT_TAB)
        let terminal = TerminalView(app: app, options: options)
        terminal.delegate = self
        let tab = Tab(terminal: terminal)
        tabs.insert(tab, at: selectedIndex.map { $0 + 1 } ?? tabs.count)
        select(tab)
        return tab
    }

    func select(_ tab: Tab, focus: Bool = true) {
        selectedTab = tab
        content.show(tab.terminal)
        window?.title = tab.title
        sidebar.update(tabs: tabs, selectedIndex: selectedIndex)
        if focus { focusTerminal() }
    }

    /// Asks for confirmation if any of the tabs is running a process.
    func requestClose(_ tabsToClose: [Tab], confirm: Bool? = nil) {
        guard !tabsToClose.isEmpty else { return }
        let needsConfirm = confirm ?? tabsToClose.contains { $0.terminal.needsConfirmQuit }
        guard needsConfirm else {
            tabsToClose.forEach(close)
            return
        }
        confirmClose(
            message: tabsToClose.count == 1 ? "Close this tab?" : "Close \(tabsToClose.count) tabs?"
        ) { [weak self] in
            tabsToClose.forEach { self?.close($0) }
        }
    }

    private func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let sidebarHadFocus = sidebar.hasFocus
        tab.terminal.teardown()
        tab.terminal.removeFromSuperview()
        tabs.remove(at: index)

        guard !tabs.isEmpty else {
            window?.close()
            return
        }
        if selectedTab === tab {
            select(tabs[min(index, tabs.count - 1)], focus: !sidebarHadFocus)
        } else {
            sidebar.update(tabs: tabs, selectedIndex: selectedIndex)
        }
    }

    func move(_ tab: Tab, by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let target = max(0, min(tabs.count - 1, index + offset))
        guard target != index else { return }
        tabs.remove(at: index)
        tabs.insert(tab, at: target)
        sidebar.update(tabs: tabs, selectedIndex: selectedIndex)
    }

    /// Handles goto_tab: 1-based index, or previous/next/last (wrapping).
    private func goto(_ value: ghostty_action_goto_tab_e) -> Bool {
        guard let current = selectedIndex else { return false }
        let target: Int
        switch value {
        case GHOSTTY_GOTO_TAB_PREVIOUS: target = (current - 1 + tabs.count) % tabs.count
        case GHOSTTY_GOTO_TAB_NEXT: target = (current + 1) % tabs.count
        case GHOSTTY_GOTO_TAB_LAST: target = tabs.count - 1
        default:
            guard value.rawValue >= 1 else { return false }
            target = min(Int(value.rawValue) - 1, tabs.count - 1)
        }
        select(tabs[target])
        return true
    }

    private func confirmClose(message: String, onConfirm: @escaping () -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "A process is still running and will be terminated."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { onConfirm() }
        }
    }

    // MARK: Focus

    func focusTerminal() {
        if let terminal = selectedTab?.terminal {
            window?.makeFirstResponder(terminal)
        }
        if sidebarPeeking {
            sidebarPeeking = false
            sidebarItem.animator().isCollapsed = true
        }
    }

    private func revealSidebar() {
        if sidebarItem.isCollapsed {
            sidebarPeeking = true
            sidebarItem.animator().isCollapsed = false
        }
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) {
        addTab()
    }

    @objc func closeTab(_ sender: Any?) {
        if let selectedTab { requestClose([selectedTab]) }
    }

    @objc func selectNextTab(_ sender: Any?) {
        _ = goto(GHOSTTY_GOTO_TAB_NEXT)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        _ = goto(GHOSTTY_GOTO_TAB_PREVIOUS)
    }

    /// Menu items for tabs 1-9 carry the tab number in their tag.
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        _ = goto(ghostty_action_goto_tab_e(rawValue: Int32(sender.tag)))
    }

    @objc func toggleTabSidebar(_ sender: Any?) {
        sidebarPeeking = false
        let collapse = !sidebarItem.isCollapsed
        if collapse && sidebar.hasFocus { focusTerminal() }
        sidebarItem.animator().isCollapsed = collapse
    }

    /// Moves keyboard focus into the sidebar, or back to the terminal.
    @objc func focusTabSidebar(_ sender: Any?) {
        if sidebar.hasFocus {
            focusTerminal()
            return
        }
        revealSidebar()
        sidebar.focus()
    }

    @objc func renameTab(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        renameReturnsToTerminal = !sidebar.hasFocus
        revealSidebar()
        sidebar.beginRename(at: index)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard tabs.contains(where: { $0.terminal.needsConfirmQuit }) else { return true }
        confirmClose(message: "Close this window?") { [weak self] in self?.window?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        tabs.forEach { $0.terminal.teardown() }
        tabs = []
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Clear a bell on the visible tab once the user is looking at it.
        selectedTab?.terminal.bell = false
    }
}

// MARK: - TerminalViewDelegate

extension WorkspaceWindowController: TerminalViewDelegate {
    private func tab(for terminal: TerminalView) -> Tab? {
        tabs.first { $0.terminal === terminal }
    }

    func terminalDidUpdate(_ terminal: TerminalView) {
        guard let tab = tab(for: terminal) else { return }
        if tab === selectedTab {
            window?.title = tab.title
        }
        sidebar.refresh(tab: tab)
    }

    func terminalDidRequestClose(_ terminal: TerminalView, confirm: Bool) {
        guard let tab = tab(for: terminal) else { return }
        requestClose([tab], confirm: confirm)
    }

    func terminal(_ terminal: TerminalView, perform command: TerminalCommand) -> Bool {
        guard let tab = tab(for: terminal), let index = tabs.firstIndex(where: { $0 === tab }) else { return false }

        switch command {
        case .newTab:
            addTab(options: SurfaceOptions(inheriting: terminal, context: GHOSTTY_SURFACE_CONTEXT_TAB))

        case .closeTab(let mode):
            switch mode {
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER: requestClose(tabs.filter { $0 !== tab })
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT: requestClose(Array(tabs[(index + 1)...]))
            default: requestClose([tab])
            }

        case .gotoTab(let value):
            return goto(value)

        case .moveTab(let offset):
            move(tab, by: offset)

        case .renameTab:
            renameTab(nil)

        case .focusSidebar:
            focusTabSidebar(nil)

        case .closeWindow:
            window?.performClose(nil)
        }
        return true
    }
}

// MARK: - SidebarDelegate

extension WorkspaceWindowController: SidebarDelegate {
    func sidebar(_ sidebar: SidebarViewController, didSelectTabAt index: Int, focusTerminal: Bool) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index], focus: focusTerminal)
    }

    func sidebarNewTab(_ sidebar: SidebarViewController) {
        addTab()
    }

    func sidebar(_ sidebar: SidebarViewController, closeTabAt index: Int) {
        guard tabs.indices.contains(index) else { return }
        requestClose([tabs[index]])
    }

    func sidebar(_ sidebar: SidebarViewController, moveTabAt index: Int, by offset: Int) {
        guard tabs.indices.contains(index) else { return }
        move(tabs[index], by: offset)
    }

    func sidebar(_ sidebar: SidebarViewController, didRenameTabAt index: Int, to title: String?) {
        if let title, tabs.indices.contains(index) {
            tabs[index].customTitle = title.isEmpty ? nil : title
            if tabs[index] === selectedTab { window?.title = tabs[index].title }
        }
        sidebar.update(tabs: tabs, selectedIndex: selectedIndex)
        if renameReturnsToTerminal {
            renameReturnsToTerminal = false
            focusTerminal()
        }
    }

    func sidebarFocusTerminal(_ sidebar: SidebarViewController) {
        focusTerminal()
    }
}

// MARK: - Views

/// Shows the selected tab's terminal. Other tabs' terminals are removed
/// from the view hierarchy, which pauses their rendering.
final class TerminalContainerViewController: NSViewController {
    private(set) var terminal: TerminalView?
    private let background: NSColor

    init(background: NSColor) {
        self.background = background
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        // Fills the strip under the transparent titlebar.
        let view = FillView(color: background)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        self.view = view
    }

    func show(_ terminal: TerminalView) {
        guard terminal !== self.terminal else { return }
        self.terminal?.removeFromSuperview()
        self.terminal = terminal

        terminal.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminal)
        NSLayoutConstraint.activate([
            // Below the transparent titlebar.
            terminal.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

private final class ThemedSplitView: NSSplitView {
    private let themedDividerColor: NSColor

    init(dividerColor: NSColor) {
        themedDividerColor = dividerColor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var dividerColor: NSColor { themedDividerColor }
}
