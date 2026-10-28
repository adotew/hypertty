import AppKit
import GhosttyKit

/// A window with a vertical tab sidebar; each tab holds split terminals and
/// web pages.
///
/// Tab and split shortcuts are Ghostty keybinds (new_tab, goto_tab,
/// new_split, goto_split, resize_split, ...), so they follow your Ghostty
/// config. The menu items mirror Ghostty's defaults for when the sidebar
/// has focus.
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private let runtime: GhosttyRuntime
    private let theme: Theme
    private(set) var tabs: [Tab] = []
    private(set) var selectedTab: Tab?
    var onClose: ((WorkspaceWindowController) -> Void)?

    private let splitViewController = NSSplitViewController()
    private var locationPanel: LocationPanel?
    private var commandPalette: CommandPalette?
    let sidebar: SidebarViewController
    private let content: TabContainerViewController
    private let sidebarItem: NSSplitViewItem
    /// The sidebar was revealed by focusTabSidebar and hides again when
    /// focus returns to the terminal.
    private var sidebarPeeking = false
    /// A rename started from the terminal (prompt_title) returns there.
    private var renameReturnsToTerminal = false

    init(runtime: GhosttyRuntime, options: SurfaceOptions = .init()) {
        self.runtime = runtime
        let theme = Theme(runtime: runtime)
        self.theme = theme
        sidebar = SidebarViewController(theme: theme)
        content = TabContainerViewController()
        sidebarItem = NSSplitViewItem(viewController: sidebar)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The only thing that paints the background; the sidebar and pane
        // container are transparent on top of it.
        window.backgroundColor = theme.chrome
        window.minSize = NSSize(width: 480, height: 240)

        super.init(window: window)
        window.delegate = self
        sidebar.tabList.delegate = self

        // Sidebar and pane gaps share one background, so hide the divider.
        let splitView = ThemedSplitView(dividerColor: .clear)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitViewController.splitView = splitView

        sidebarItem.canCollapse = true
        // Fits the traffic lights and the project header.
        sidebarItem.minimumThickness = 200
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

    private func makeTerminal(_ options: SurfaceOptions) -> TerminalView? {
        guard let app = runtime.app else { return nil }
        let terminal = TerminalView(app: app, options: options)
        terminal.delegate = self
        return terminal
    }

    /// Adds a tab after the selected one, inheriting its working directory.
    @discardableResult
    func addTab(options: SurfaceOptions? = nil) -> Tab? {
        let options = options ?? SurfaceOptions(inheriting: selectedTab?.focused, context: GHOSTTY_SURFACE_CONTEXT_TAB)
        guard let terminal = makeTerminal(options) else { return nil }
        let tab = Tab(terminal: terminal, theme: theme)
        tabs.insert(tab, at: selectedIndex.map { $0 + 1 } ?? tabs.count)
        select(tab)
        return tab
    }

    func select(_ tab: Tab, focus: Bool = true) {
        selectedTab = tab
        content.show(tab.view)
        window?.title = tab.title
        sidebar.update(tabs: tabs, selectedIndex: selectedIndex)
        if focus { focusTerminal() }
    }

    /// Asks for confirmation if any of the tabs is running a process.
    func requestClose(_ tabsToClose: [Tab], confirm: Bool? = nil) {
        guard !tabsToClose.isEmpty else { return }
        let needsConfirm = confirm ?? tabsToClose.contains { $0.needsConfirmQuit }
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
        tab.panes.forEach { $0.teardown() }
        tab.view.removeFromSuperview()
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
        if let pane = selectedTab?.focused {
            window?.makeFirstResponder(pane)
        }
        if sidebarPeeking {
            sidebarPeeking = false
            setSidebarCollapsed(true)
        }
    }

    private func revealSidebar() {
        if sidebarItem.isCollapsed {
            sidebarPeeking = true
            setSidebarCollapsed(false)
        }
    }

    private func setSidebarCollapsed(_ collapsed: Bool) {
        sidebarItem.animator().isCollapsed = collapsed
        content.clearsTitlebar = collapsed
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
        setSidebarCollapsed(collapse)
    }

    /// Moves keyboard focus to the tab list, or back to the terminal.
    @objc func focusTabSidebar(_ sender: Any?) {
        focusSidebar()
    }

    private func focusSidebar() {
        if sidebar.hasFocus {
            focusTerminal()
            return
        }
        revealSidebar()
        sidebar.focus()
    }

    // Split menu items act on the selected tab's focused pane, e.g. while
    // the sidebar has focus. In the terminal, Ghostty's keybinds run first.

    /// Runs the `TerminalCommand` in the item's representedObject.
    @objc func performMenuCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? TerminalCommand, let pane = selectedTab?.focused else { return }
        _ = perform(command, from: pane)
    }

    /// Closes the focused pane, or the tab with its last pane.
    @objc func closePane(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        closePane(tab.focused, in: tab, confirm: tab.focused.needsConfirmQuit)
    }

    /// Cmd+L: edits the focused web pane's address. From any other pane the
    /// web split opens right of it once an address is submitted.
    @objc func openLocation(_ sender: Any?) {
        guard let window, let tab = selectedTab else { return }
        let pane = tab.focused
        let web = pane as? WebPaneView
        locationPanel?.close()
        let text = web?.url == WebPaneView.blank ? "" : web?.url?.absoluteString ?? ""
        let panel = LocationPanel(text: text, dark: theme.isDark) { [weak self, weak web, weak pane] url in
            if let web {
                web.load(URLRequest(url: url))
            } else if let pane {
                self?.openWebPane(url, beside: pane)
            }
        }
        locationPanel = panel
        panel.show(over: window)
    }

    /// Cmd+Shift+P: lists the menu commands that can run right now. Pressing it
    /// again closes the palette.
    @objc func showCommandPalette(_ sender: Any?) {
        guard let window else { return }
        if let commandPalette, commandPalette.isVisible {
            commandPalette.dismiss(refocusParent: true)
            return
        }
        let palette = CommandPalette(commands: CommandPalette.menuCommands(in: NSApp.mainMenu), dark: theme.isDark)
        commandPalette = palette
        palette.show(over: window)
    }

    @objc func renameTab(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        renameReturnsToTerminal = !sidebar.hasFocus
        revealSidebar()
        sidebar.beginRename(at: index)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard tabs.contains(where: { $0.needsConfirmQuit }) else { return true }
        confirmClose(message: "Close this window?") { [weak self] in self?.window?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        tabs.forEach { $0.panes.forEach { $0.teardown() } }
        tabs = []
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Clear a bell on the visible tab once the user is looking at it.
        selectedTab?.focused.bell = false
    }
}

// MARK: - PaneDelegate

extension WorkspaceWindowController: PaneDelegate {
    private func tab(for pane: any Pane) -> Tab? {
        tabs.first { $0.root.contains(pane) }
    }

    func openWebPane(_ url: URL) {
        guard let pane = selectedTab?.focused else { return }
        openWebPane(url, beside: pane)
    }

    @discardableResult
    private func openWebPane(_ url: URL, beside pane: any Pane) -> WebPaneView? {
        guard let tab = tab(for: pane) else { return nil }
        let web = WebPaneView(url: url, pwd: pane.pwd, dark: theme.isDark)
        web.delegate = self
        tab.split(pane, adding: web, direction: GHOSTTY_SPLIT_DIRECTION_RIGHT)
        window?.makeFirstResponder(web)
        return web
    }

    /// Closes one pane; closing the last pane closes the tab.
    private func closePane(_ pane: any Pane, in tab: Tab, confirm: Bool) {
        guard tab.paneCount > 1 else {
            requestClose([tab], confirm: confirm)
            return
        }
        let close = { [weak self] in
            guard let self else { return }
            let wasFocused = tab.focused === pane
            pane.teardown()
            let next = tab.remove(pane)
            if wasFocused, tab === selectedTab, !sidebar.hasFocus, let next {
                window?.makeFirstResponder(next)
            }
            sidebar.refresh(tab: tab)
        }
        if confirm {
            confirmClose(message: "Close this split?", onConfirm: close)
        } else {
            close()
        }
    }

    func paneDidUpdate(_ pane: any Pane) {
        guard let tab = tab(for: pane) else { return }
        if tab === selectedTab {
            content.show(tab.view)
            window?.title = tab.title
        }
        sidebar.refresh(tab: tab)
    }

    func paneDidFocus(_ pane: any Pane) {
        guard let tab = tab(for: pane) else { return }
        tab.focusDidChange(to: pane)
        if tab === selectedTab {
            content.show(tab.view)
            window?.title = tab.title
        }
        sidebar.refresh(tab: tab)
    }

    func paneDidRequestClose(_ pane: any Pane, confirm: Bool) {
        guard let tab = tab(for: pane) else { return }
        closePane(pane, in: tab, confirm: confirm)
    }

    func pane(_ pane: any Pane, perform command: TerminalCommand) -> Bool {
        perform(command, from: pane)
    }

    private func perform(_ command: TerminalCommand, from pane: any Pane) -> Bool {
        guard let tab = tab(for: pane), let index = tabs.firstIndex(where: { $0 === tab }) else { return false }

        switch command {
        case .newTab:
            addTab(options: SurfaceOptions(inheriting: pane, context: GHOSTTY_SURFACE_CONTEXT_TAB))

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

        case .newSplit(let direction):
            let options = SurfaceOptions(inheriting: pane, context: GHOSTTY_SURFACE_CONTEXT_SPLIT)
            guard let newTerminal = makeTerminal(options) else { return false }
            tab.split(pane, adding: newTerminal, direction: direction)
            window?.makeFirstResponder(newTerminal)

        case .gotoSplit(let direction):
            guard let target = tab.target(from: pane, direction) else { return false }
            tab.unzoom()
            window?.makeFirstResponder(target)

        case .resizeSplit(let resize):
            tab.resize(pane, resize)

        case .equalizeSplits:
            tab.equalize()

        case .toggleSplitZoom:
            tab.toggleZoom()
            window?.makeFirstResponder(tab.focused)

        case .commandPalette:
            showCommandPalette(nil)

        case .openURL(let url):
            openWebPane(url, beside: pane)
        }
        return true
    }
}

// MARK: - TabListDelegate

extension WorkspaceWindowController: TabListDelegate {
    func tabList(_ list: TabListViewController, didSelectTabAt index: Int, focusTerminal: Bool) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index], focus: focusTerminal)
    }

    func tabListNewTab(_ list: TabListViewController) {
        addTab()
    }

    func tabList(_ list: TabListViewController, closeTabAt index: Int) {
        guard tabs.indices.contains(index) else { return }
        requestClose([tabs[index]])
    }

    func tabList(_ list: TabListViewController, moveTabAt index: Int, by offset: Int) {
        guard tabs.indices.contains(index) else { return }
        move(tabs[index], by: offset)
    }

    func tabList(_ list: TabListViewController, didRenameTabAt index: Int, to title: String?) {
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

    func tabListFocusTerminal(_ list: TabListViewController) {
        focusTerminal()
    }
}

// MARK: - Views

/// Shows the selected tab's view, inset so pane cards float on the window
/// background. Other tabs' views are removed from the view hierarchy, which
/// pauses their terminals' rendering.
final class TabContainerViewController: NSViewController {
    static let padding: CGFloat = 8

    private var shown: NSView?
    private var topConstraint: NSLayoutConstraint?
    /// With the sidebar hidden, the traffic lights sit over the content,
    /// so the cards start below the titlebar.
    var clearsTitlebar = false {
        didSet { updateTopConstraint() }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    func show(_ tabView: NSView) {
        if tabView !== shown {
            shown?.removeFromSuperview()
            shown = tabView

            tabView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(tabView)
            let padding = Self.padding
            NSLayoutConstraint.activate([
                tabView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding),
                tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
                tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            ])
        }
        updateTopConstraint()
    }

    private func updateTopConstraint() {
        guard let shown else { return }
        topConstraint?.isActive = false
        topConstraint = clearsTitlebar
            ? shown.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
            : shown.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.padding)
        topConstraint?.isActive = true
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
