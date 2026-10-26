import AppKit

/// One entry in the sidebar. For now a tab holds a single terminal;
/// splits and browser panes come later.
final class Tab {
    let terminal: TerminalView
    /// Set by renaming the tab; overrides the title the shell reports.
    var customTitle: String?

    init(terminal: TerminalView) {
        self.terminal = terminal
    }

    var title: String {
        if let customTitle { return customTitle }
        if !terminal.title.isEmpty { return terminal.title }
        return directory ?? "Terminal"
    }

    /// The working directory, shown under the title unless it's the same.
    var subtitle: String? {
        guard let directory, directory != title else { return nil }
        return directory
    }

    var hasBell: Bool { terminal.bell }

    private var directory: String? {
        guard let pwd = terminal.pwd else { return nil }
        return (pwd as NSString).abbreviatingWithTildeInPath
    }
}
