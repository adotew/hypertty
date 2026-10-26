import AppKit

/// App chrome colors derived from the Ghostty theme, so the sidebar
/// matches the terminal.
struct Theme {
    let background: NSColor
    let foreground: NSColor
    /// Palette color 4 (blue), used to mark the focused sidebar.
    let accent: NSColor
    /// Drawn over unfocused split panes.
    let unfocusedSplitFill: NSColor
    /// Pane card outline. Ghostty's `split-divider-color` if set, since
    /// panes are separated by gaps rather than divider lines.
    let paneBorder: NSColor

    init(runtime: GhosttyRuntime) {
        background = runtime.configColor("background") ?? .black
        foreground = runtime.configColor("foreground") ?? .white
        accent = runtime.paletteColor(4) ?? .controlAccentColor

        // Same defaults and clamping as Ghostty.
        let opacity = min(1, max(0.15, runtime.configDouble("unfocused-split-opacity") ?? 0.7))
        unfocusedSplitFill = (runtime.configColor("unfocused-split-fill") ?? background)
            .withAlphaComponent(1 - opacity)
        paneBorder = runtime.configColor("split-divider-color") ?? foreground.withAlphaComponent(0.08)
    }

    /// Behind the sidebar and between pane cards.
    var chrome: NSColor { background.blended(withFraction: 0.2, of: .black) ?? background }
    var paneBorderActive: NSColor { paneBorder.withAlphaComponent(min(1, paneBorder.alphaComponent * 2.2)) }
    var selection: NSColor { foreground.withAlphaComponent(0.1) }
    var secondaryText: NSColor { foreground.withAlphaComponent(0.5) }
}

/// A view that fills itself with a color. Drawn (rather than using a layer
/// background) so it also shows up in DebugSnapshot's window captures.
final class FillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}
