import AppKit
import GhosttyKit

/// One entry in the sidebar: a tree of split terminals. `view` hosts the
/// tree and is what the window shows when the tab is selected.
final class Tab {
    /// Renders the panes' glass together; spacing 0 keeps separate cards
    /// from merging.
    let view = NSGlassEffectContainerView()
    private let content = NSView()
    private(set) var root: SplitNode
    /// The pane that has (or last had) keyboard focus.
    private(set) var focused: TerminalView
    /// Set by `toggle_split_zoom`: only this pane is shown.
    private(set) var zoomed: TerminalView?
    /// Set by renaming the tab; overrides the title the shell reports.
    var customTitle: String?

    private let theme: Theme
    private var panes: [ObjectIdentifier: PaneView] = [:]

    init(terminal: TerminalView, theme: Theme) {
        root = .leaf(terminal)
        focused = terminal
        self.theme = theme
        view.spacing = 0
        view.contentView = content
        rebuild()
    }

    var terminals: [TerminalView] { root.leaves }

    var needsConfirmQuit: Bool { terminals.contains { $0.needsConfirmQuit } }

    // MARK: Sidebar

    var title: String {
        if let customTitle { return customTitle }
        if !focused.title.isEmpty { return focused.title }
        return directory ?? "Terminal"
    }

    /// The working directory, shown under the title unless it's the same.
    var subtitle: String? {
        guard let directory, directory != title else { return nil }
        return directory
    }

    var hasBell: Bool { terminals.contains { $0.bell } }

    var paneCount: Int { terminals.count }

    private var directory: String? {
        guard let pwd = focused.pwd else { return nil }
        return (pwd as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Splits

    func split(_ target: TerminalView, adding terminal: TerminalView,
               direction: ghostty_action_split_direction_e) {
        zoomed = nil
        root = root.inserting(terminal, at: target, direction: direction)
        rebuild()
    }

    /// Removes a pane and returns the one to focus next, or nil if it was
    /// the last pane.
    func remove(_ terminal: TerminalView) -> TerminalView? {
        // Focus moves to the previous pane, like Ghostty.
        let next = root.target(from: terminal, GHOSTTY_GOTO_SPLIT_PREVIOUS)
        guard let newRoot = root.removing(terminal) else { return nil }
        root = newRoot
        panes[ObjectIdentifier(terminal)] = nil
        if zoomed === terminal { zoomed = nil }
        if focused === terminal, let next { focused = next }
        rebuild()
        return next
    }

    func target(from terminal: TerminalView, _ direction: ghostty_action_goto_split_e) -> TerminalView? {
        root.target(from: terminal, direction)
    }

    func resize(_ terminal: TerminalView, _ resize: ghostty_action_resize_split_s) {
        zoomed = nil
        root = root.resizing(terminal, direction: resize.direction,
                             amount: CGFloat(resize.amount), in: view.bounds.size)
        rebuild()
    }

    func equalize() {
        root = root.equalized()
        rebuild()
    }

    func toggleZoom() {
        guard terminals.count > 1 else { return }
        zoomed = zoomed == nil ? focused : nil
        rebuild()
    }

    func unzoom() {
        guard zoomed != nil else { return }
        zoomed = nil
        rebuild()
    }

    /// Records which pane has focus and dims the others.
    func focusDidChange(to terminal: TerminalView) {
        guard root.contains(terminal) else { return }
        focused = terminal
        updateDimming()
    }

    // MARK: Views

    func pane(for terminal: TerminalView) -> PaneView {
        if let pane = panes[ObjectIdentifier(terminal)] { return pane }
        let pane = PaneView(terminal: terminal, theme: theme)
        panes[ObjectIdentifier(terminal)] = pane
        return pane
    }

    /// Recreates the view hierarchy from the tree. Terminals are reparented,
    /// not recreated, so their shells keep running.
    private func rebuild() {
        let hadFocus = focused.window?.firstResponder === focused
        content.subviews.forEach { $0.removeFromSuperview() }

        let tree = zoomed.map { pane(for: $0) } ?? makeView(root, path: [])
        tree.frame = content.bounds
        tree.autoresizingMask = [.width, .height]
        content.addSubview(tree)
        updateDimming()

        // Reparenting drops first responder; give it back.
        if hadFocus {
            focused.window?.makeFirstResponder(focused)
        }
    }

    private func makeView(_ node: SplitNode, path: [Bool]) -> NSView {
        switch node {
        case .leaf(let terminal):
            return pane(for: terminal)
        case .split(let axis, let ratio, let first, let second):
            let container = SplitContainerView(
                axis: axis, ratio: ratio,
                first: makeView(first, path: path + [false]),
                second: makeView(second, path: path + [true]))
            container.onRatioChange = { [weak self] ratio in
                guard let self else { return }
                root = root.setting(ratio: ratio, at: path[...])
            }
            return container
        }
    }

    private func updateDimming() {
        let split = zoomed == nil && terminals.count > 1
        for terminal in terminals {
            let pane = pane(for: terminal)
            pane.dimmed = split && terminal !== focused
        }
    }
}
