import AppKit
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate, GhosttyRuntimeDelegate {
    private var runtime: GhosttyRuntime!
    private var windows: [WorkspaceWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime = GhosttyRuntime()
        runtime.delegate = self
        NSApp.mainMenu = makeMainMenu()
        newWindow(inheriting: nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard runtime.needsConfirmQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Codecave?"
        alert.informativeText = "Processes are still running in your terminals and will be terminated."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        windows.forEach { $0.tabs.forEach { $0.panes.forEach { $0.teardown() } } }
    }

    // MARK: Windows

    @objc func newWindow(_ sender: Any?) {
        newWindow(inheriting: keyWorkspace?.selectedTab?.focused)
    }

    private var keyWorkspace: WorkspaceWindowController? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? WorkspaceWindowController
    }

    private func newWindow(inheriting parent: (any Pane)?) {
        let controller = WorkspaceWindowController(
            runtime: runtime,
            options: SurfaceOptions(inheriting: parent, context: GHOSTTY_SURFACE_CONTEXT_WINDOW))
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        windows.append(controller)
        controller.show(cascadingFrom: parent?.window)
    }

    // MARK: GhosttyRuntimeDelegate

    func ghosttyNewWindow(inheriting parent: TerminalView?) {
        newWindow(inheriting: parent)
    }

    func ghosttyNewTab() {
        if let keyWorkspace {
            keyWorkspace.addTab()
        } else {
            newWindow(inheriting: nil)
        }
    }

    func ghosttyQuit() {
        NSApp.terminate(nil)
    }

    // MARK: Menu

    /// Most shortcuts are Ghostty keybinds handled by the terminal itself
    /// (cmd+c/v, cmd+t, cmd+n, cmd+w, cmd+1-9, ...), so they follow your
    /// Ghostty config. The menu covers them when a terminal doesn't have
    /// focus (the sidebar or a web page does): the pane items take their
    /// shortcuts from your config, the rest mirror Ghostty's defaults. It
    /// also owns the app-level shortcuts: ⌘B toggles the sidebar, ⌘S
    /// focuses it.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Codecave",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Codecave", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Codecave", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "Codecave")

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(WorkspaceWindowController.newTab(_:)),
                         keyEquivalent: "t")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(.separator())
        fileMenu.addItem(ghosttyItem("Close", #selector(WorkspaceWindowController.closePane(_:)),
                                     action: "close_surface"))
        fileMenu.addItem(ghosttyItem("Close Tab", #selector(WorkspaceWindowController.closeTab(_:)),
                                     action: "close_tab"))
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        main.addItem(submenu: fileMenu, title: "File")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(TerminalView.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: editMenu, title: "Edit")

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(WorkspaceWindowController.toggleTabSidebar(_:)),
                         keyEquivalent: "b")
        viewMenu.addItem(withTitle: "Show Tabs", action: #selector(WorkspaceWindowController.focusTabSidebar(_:)),
                         keyEquivalent: "s")
        viewMenu.addItem(withTitle: "Rename Tab…", action: #selector(WorkspaceWindowController.renameTab(_:)),
                         keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("Split Right", .newSplit(GHOSTTY_SPLIT_DIRECTION_RIGHT), action: "new_split:right"))
        viewMenu.addItem(commandItem("Split Down", .newSplit(GHOSTTY_SPLIT_DIRECTION_DOWN), action: "new_split:down"))
        viewMenu.addItem(withTitle: "Open Location…",
                         action: #selector(WorkspaceWindowController.openLocation(_:)), keyEquivalent: "l")
        viewMenu.addItem(withTitle: "Reload Page", action: #selector(WebPaneView.reload(_:)), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("Zoom Split", .toggleSplitZoom, action: "toggle_split_zoom"))
        viewMenu.addItem(commandItem("Equalize Splits", .equalizeSplits, action: "equalize_splits"))
        for (name, direction, action) in [
            ("Previous", GHOSTTY_GOTO_SPLIT_PREVIOUS, "previous"), ("Next", GHOSTTY_GOTO_SPLIT_NEXT, "next"),
            ("Left", GHOSTTY_GOTO_SPLIT_LEFT, "left"), ("Right", GHOSTTY_GOTO_SPLIT_RIGHT, "right"),
            ("Above", GHOSTTY_GOTO_SPLIT_UP, "up"), ("Below", GHOSTTY_GOTO_SPLIT_DOWN, "down"),
        ] {
            viewMenu.addItem(commandItem("Select Split \(name)", .gotoSplit(direction), action: "goto_split:\(action)"))
        }
        for (name, direction, action) in [
            ("Left", GHOSTTY_RESIZE_SPLIT_LEFT, "left"), ("Right", GHOSTTY_RESIZE_SPLIT_RIGHT, "right"),
            ("Up", GHOSTTY_RESIZE_SPLIT_UP, "up"), ("Down", GHOSTTY_RESIZE_SPLIT_DOWN, "down"),
        ] {
            // Ghostty's default resize keybinds move by 10 points.
            let resize = ghostty_action_resize_split_s(amount: 10, direction: direction)
            viewMenu.addItem(commandItem("Resize Split \(name)", .resizeSplit(resize), action: "resize_split:\(action),10"))
        }
        main.addItem(submenu: viewMenu, title: "View")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Toggle Full Screen",
                           action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Select Next Tab",
                           action: #selector(WorkspaceWindowController.selectNextTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control]
        windowMenu.addItem(withTitle: "Select Previous Tab",
                           action: #selector(WorkspaceWindowController.selectPreviousTab(_:)), keyEquivalent: "")
        for number in 1...9 {
            let item = windowMenu.addItem(withTitle: "Select Tab \(number)",
                                          action: #selector(WorkspaceWindowController.selectTabByNumber(_:)),
                                          keyEquivalent: "\(number)")
            item.tag = number
        }
        windowMenu.addItem(.separator())
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        return main
    }
}

private extension AppDelegate {
    /// An item with the shortcut your Ghostty config binds to `action`.
    func ghosttyItem(_ title: String, _ selector: Selector, action: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        runtime.applyShortcut(for: action, to: item)
        return item
    }

    /// An item that runs `command` on the focused pane.
    func commandItem(_ title: String, _ command: TerminalCommand, action: String) -> NSMenuItem {
        let item = ghosttyItem(title, #selector(WorkspaceWindowController.performMenuCommand(_:)), action: action)
        item.representedObject = command
        return item
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
