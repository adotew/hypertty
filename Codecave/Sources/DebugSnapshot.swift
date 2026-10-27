#if DEBUG
import AppKit
import CoreImage
import GhosttyKit

/// Development aid for verifying the UI without screen-recording
/// permission. Launch with:
///
///   CODECAVE_SNAPSHOT=/tmp/shot           write /tmp/shot.png and /tmp/shot.txt, then exit
///   CODECAVE_SNAPSHOT_INPUT='ls'          run a command in the selected tab first
///   CODECAVE_SNAPSHOT_ACTIONS='new_tab;goto_tab:1;@focusTabSidebar:;key:j'
///       steps run 0.5s apart: Ghostty keybind actions on the selected
///       terminal, `@selector:` sent through the responder chain, or
///       `key:<chars>` typed into the first responder (`\r` for Return,
///       `\t` for Tab), or `web:<url>` opened in a split
///
/// The PNG composites the window's AppKit views with the frame libghostty
/// rendered (read back from the terminal's IOSurface-backed layer).
enum DebugSnapshot {
    static func scheduleIfRequested(for workspace: WorkspaceWindowController) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CODECAVE_SNAPSHOT"] else { return }
        var steps: [String] = []
        if let input = env["CODECAVE_SNAPSHOT_INPUT"] { steps.append("input:" + input) }
        steps += (env["CODECAVE_SNAPSHOT_ACTIONS"] ?? "").split(separator: ";").map(String.init)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            run(steps[...], in: workspace) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    write(workspace, to: path)
                    exit(0)
                }
            }
        }
    }

    private static func run(_ steps: ArraySlice<String>, in workspace: WorkspaceWindowController,
                            then done: @escaping () -> Void) {
        guard let step = steps.first else { return done() }
        let terminal = workspace.selectedTab?.focused as? TerminalView

        if step.hasPrefix("input:"), let surface = terminal?.surface {
            // Text arrives like a paste; Return is a real key press so the shell runs it.
            let text = String(step.dropFirst("input:".count))
            text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
            var key = ghostty_input_key_s()
            key.keycode = 0x24 // kVK_Return
            for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
                key.action = action
                _ = ghostty_surface_key(surface, key)
            }
        } else if step.hasPrefix("@") {
            // Target the workspace directly: the window may not be key yet
            // while the app is still activating.
            let selector = Selector(String(step.dropFirst()))
            NSApp.sendAction(selector, to: workspace.responds(to: selector) ? workspace : nil, from: nil)
        } else if step.hasPrefix("web:"), let pane = workspace.selectedTab?.focused,
                  let url = URL(string: String(step.dropFirst("web:".count))) {
            _ = workspace.pane(pane, perform: .openURL(url))
        } else if step.hasPrefix("key:"), let window = workspace.window {
            let keys = step.dropFirst("key:".count)
                .replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\t", with: "\t")
            for char in keys {
                let keyCode: UInt16 = char == "\r" ? 0x24 : char == "\t" ? 0x30 : 0
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: char.isUppercase ? .shift : [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: String(char), charactersIgnoringModifiers: String(char),
                    isARepeat: false, keyCode: keyCode) else { continue }
                window.firstResponder?.keyDown(with: event)
            }
        } else {
            terminal?.perform(action: step)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            run(steps.dropFirst(), in: workspace, then: done)
        }
    }

    private static func write(_ workspace: WorkspaceWindowController, to path: String) {
        guard let window = workspace.window, let contentView = window.contentView else { return }

        // AppKit views first, then each visible pane's Metal-rendered frame
        // and its unfocused-split dimming on top.
        if let views = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds),
           let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) {
            contentView.cacheDisplay(in: contentView.bounds, to: views)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // The window background shows through the transparent views.
            window.backgroundColor.setFill()
            contentView.bounds.fill()
            views.draw(in: contentView.bounds, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: false, hints: nil)
            for terminal in terminals(workspace.selectedTab) where terminal.window != nil {
                let rect = terminal.convert(terminal.bounds, to: nil)
                if let frame = terminalImage(terminal) {
                    NSGraphicsContext.current?.cgContext.draw(frame, in: rect)
                }
                if let pane = enclosingPane(terminal), pane.dimmed {
                    pane.dimColor.setFill()
                    NSBezierPath(roundedRect: pane.convert(pane.bounds, to: nil),
                                 xRadius: PaneView.cornerRadius, yRadius: PaneView.cornerRadius).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".png"))
        }

        var report = "window visible: \(window.occlusionState.contains(.visible)) key: \(window.isKeyWindow)\n"
        report += "first responder: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "-")\n"
        report += "tabs:\n"
        for (index, tab) in workspace.tabs.enumerated() {
            let marker = tab === workspace.selectedTab ? "*" : " "
            report += " \(marker)\(index + 1) \(tab.title) \(tab.hasBell ? "(bell)" : "")"
            report += " panes: \(tab.paneCount)\(tab.zoomed != nil ? " (zoomed)" : "")\n"
        }
        report += workspace.sidebarReport
        if let tab = workspace.selectedTab {
            report += "panes of selected tab (window points):\n"
            for terminal in terminals(tab) {
                let frame = terminal.window != nil ? terminal.convert(terminal.bounds, to: nil) : .zero
                let size = terminal.surface.map(ghostty_surface_size)
                report += " \(terminal === tab.focused ? "*" : " ") \(Int(frame.minX)),\(Int(frame.minY))"
                report += " \(Int(frame.width))x\(Int(frame.height)) grid \(size?.columns ?? 0)x\(size?.rows ?? 0)"
                report += " title: \"\(terminal.title)\" first responder: \(terminal.window?.firstResponder === terminal)"
                report += " dimmed: \(enclosingPane(terminal)?.dimmed ?? false)\n"
            }
            if let surface = (tab.focused as? TerminalView)?.surface {
                report += "---\n" + screenText(surface)
            }
        }
        try? report.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    }

    private static func terminals(_ tab: Tab?) -> [TerminalView] {
        tab?.panes.compactMap { $0 as? TerminalView } ?? []
    }

    private static func enclosingPane(_ terminal: TerminalView) -> PaneView? {
        sequence(first: terminal.superview, next: { $0?.superview }).lazy.compactMap { $0 as? PaneView }.first
    }

    private static func terminalImage(_ terminal: TerminalView) -> CGImage? {
        guard let surface = terminal.layer?.contents as? IOSurface else { return nil }
        let image = CIImage(ioSurface: surface)
        return CIContext().createCGImage(image, from: image.extent)
    }

    private static func screenText(_ surface: ghostty_surface_t) -> String {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
}
#endif

#if DEBUG
extension WorkspaceWindowController {
    /// Sidebar focus and the changes list.
    var sidebarReport: String {
        var report = "sidebar: \(sidebar.mode) focus: \(sidebar.hasFocus)\n"
        let changes = sidebar.changes
        report += "changes: \(changes.root?.path ?? "-") branch: \(changes.status?.branch ?? "-")\n"
        for change in changes.status?.changes ?? [] {
            report += "  \(change.staged ? "staged" : "      ") \(change.status) \(change.path)\n"
        }
        return report
    }
}
#endif
