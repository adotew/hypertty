import AppKit
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate, GhosttyRuntimeDelegate {
    private var runtime: GhosttyRuntime!
    private var windows: [TerminalWindowController] = []

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
        windows.forEach { $0.terminal.teardown() }
    }

    // MARK: Windows

    @objc func newWindow(_ sender: Any?) {
        let focused = NSApp.keyWindow?.windowController as? TerminalWindowController
        newWindow(inheriting: focused?.terminal)
    }

    private func newWindow(inheriting parent: TerminalView?) {
        let controller = TerminalWindowController(
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

    func ghosttyQuit() {
        NSApp.terminate(nil)
    }

    // MARK: Menu

    /// Most shortcuts are Ghostty keybinds handled by the terminal itself
    /// (cmd+c/v, cmd+n, cmd+w, cmd+q, cmd+plus/minus, ...). The menu exists
    /// for discoverability and for when no terminal has focus.
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
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: fileMenu, title: "File")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(TerminalView.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: editMenu, title: "Edit")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Toggle Full Screen",
                           action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
