import AppKit

/// App chrome colors derived from the Ghostty theme, so the sidebar
/// matches the terminal.
struct Theme {
    let background: NSColor
    let foreground: NSColor
    /// Palette color 4 (blue), used to mark the focused sidebar.
    let accent: NSColor

    init(runtime: GhosttyRuntime) {
        background = runtime.configColor("background") ?? .black
        foreground = runtime.configColor("foreground") ?? .white
        accent = runtime.paletteColor(4) ?? .controlAccentColor
    }

    var sidebarBackground: NSColor { background.blended(withFraction: 0.2, of: .black) ?? background }
    var divider: NSColor { background.blended(withFraction: 0.12, of: foreground) ?? foreground }
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
