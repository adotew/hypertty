import AppKit
import GhosttyKit

/// One entry in the sidebar: a tree of split panes. `view` hosts the
/// tree and is what the window shows when the tab is selected.
final class Tab {
    /// Renders the panes' glass together; spacing 0 keeps separate cards
    /// from merging.
    let view = NSGlassEffectContainerView()
    private let content = NSView()
    private(set) var root: SplitNode
    /// The pane that has (or last had) keyboard focus.
    private(set) var focused: any Pane
    /// Set by `toggle_split_zoom`: only this pane is shown.
    private(set) var zoomed: (any Pane)?
    /// Set by renaming the tab; overrides the folder name.
    var customTitle: String?

    private let theme: Theme
    private var paneViews: [ObjectIdentifier: PaneView] = [:]

    init(terminal: TerminalView, theme: Theme) {
        root = .leaf(terminal)
        focused = terminal
        self.theme = theme
        view.spacing = 0
        view.contentView = content
        rebuild()
    }

    var panes: [any Pane] { root.leaves }

    var needsConfirmQuit: Bool { panes.contains { $0.needsConfirmQuit } }

    // MARK: Sidebar

    var title: String { customTitle ?? focused.tabTitle }

    var icon: NSImage { focused.tabIcon }

    var hasBell: Bool { panes.contains { $0.bell } }

    var paneCount: Int { panes.count }

    // MARK: Splits

    func split(_ target: any Pane, adding pane: any Pane,
               direction: ghostty_action_split_direction_e) {
        zoomed = nil
        root = root.inserting(pane, at: target, direction: direction)
        rebuild()
    }

    /// Removes a pane and returns the one to focus next, or nil if it was
    /// the last pane.
    func remove(_ pane: any Pane) -> (any Pane)? {
        // Focus moves to the previous pane, like Ghostty.
        let next = root.target(from: pane, GHOSTTY_GOTO_SPLIT_PREVIOUS)
        guard let newRoot = root.removing(pane) else { return nil }
        root = newRoot
        paneViews[ObjectIdentifier(pane)] = nil
        if zoomed === pane { zoomed = nil }
        if focused === pane, let next { focused = next }
        rebuild()
        return next
    }

    func target(from pane: any Pane, _ direction: ghostty_action_goto_split_e) -> (any Pane)? {
        root.target(from: pane, direction)
    }

    func resize(_ pane: any Pane, _ resize: ghostty_action_resize_split_s) {
        zoomed = nil
        root = root.resizing(pane, direction: resize.direction,
                             amount: CGFloat(resize.amount), in: view.bounds.size)
        rebuild()
    }

    func equalize() {
        root = root.equalized()
        rebuild()
    }

    func toggleZoom() {
        guard panes.count > 1 else { return }
        zoomed = zoomed == nil ? focused : nil
        rebuild()
    }

    func unzoom() {
        guard zoomed != nil else { return }
        zoomed = nil
        rebuild()
    }

    /// Records which pane has focus and dims the others.
    func focusDidChange(to pane: any Pane) {
        guard root.contains(pane) else { return }
        focused = pane
        updateDimming()
    }

    // MARK: Views

    func view(for pane: any Pane) -> PaneView {
        if let view = paneViews[ObjectIdentifier(pane)] { return view }
        let view = PaneView(pane: pane, theme: theme)
        paneViews[ObjectIdentifier(pane)] = view
        return view
    }

    /// Recreates the view hierarchy from the tree. Panes are reparented,
    /// not recreated, so their shells keep running.
    private func rebuild() {
        let hadFocus = focused.window?.firstResponder === focused
        content.subviews.forEach { $0.removeFromSuperview() }

        let tree = zoomed.map { view(for: $0) } ?? makeView(root, path: [])
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
        case .leaf(let pane):
            return view(for: pane)
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
        let split = zoomed == nil && panes.count > 1
        for pane in panes {
            view(for: pane).dimmed = split && pane !== focused
        }
    }
}
