import AppKit

/// What a split holds: a terminal or a web page.
protocol Pane: NSView {
    /// The working directory: the shell's, or for a web page the one of the
    /// terminal it was opened from.
    var pwd: String? { get }
    /// Shown in the sidebar and the window title.
    var tabTitle: String { get }
    /// Shown left of the title in the sidebar.
    var tabIcon: NSImage { get }
    var bell: Bool { get set }
    var needsConfirmQuit: Bool { get }
    func teardown()
}

protocol PaneDelegate: AnyObject {
    /// Title, working directory or bell state changed.
    func paneDidUpdate(_ pane: any Pane)
    /// The pane became first responder (e.g. clicked or navigated to).
    func paneDidFocus(_ pane: any Pane)
    /// The shell exited or `close_surface` ran. `confirm` is true if a
    /// process is still running.
    func paneDidRequestClose(_ pane: any Pane, confirm: Bool)
    /// Returns false if the command isn't supported.
    func pane(_ pane: any Pane, perform command: TerminalCommand) -> Bool
}
