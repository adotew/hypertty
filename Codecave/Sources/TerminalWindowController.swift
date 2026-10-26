import AppKit
import GhosttyKit

/// A window containing a single Ghostty terminal.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    let terminal: TerminalView
    var onClose: ((TerminalWindowController) -> Void)?

    init(runtime: GhosttyRuntime, options: SurfaceOptions = .init()) {
        guard let app = runtime.app else { fatalError("Ghostty app not initialized") }
        terminal = TerminalView(app: app, options: options)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Codecave"
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 300, height: 200)

        // Blend the titlebar into the terminal using your theme's background.
        window.titlebarAppearsTransparent = true
        if let background = runtime.configColor("background") {
            window.backgroundColor = background
        }

        super.init(window: window)
        window.delegate = self

        // The terminal sits below the transparent titlebar.
        let container = NSView()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        window.contentView = container
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminal.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
        ])

        terminal.onTitleChange = { [weak window] title in window?.title = title }
        terminal.onClose = { [weak window] in window?.close() }
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
        window.makeFirstResponder(terminal)

        #if DEBUG
        DebugSnapshot.scheduleIfRequested(for: terminal)
        #endif
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard terminal.needsConfirmQuit else { return true }
        terminal.requestClose(confirm: true)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        terminal.teardown()
        onClose?(self)
    }
}
