import AppKit

/// A browser-style location bar floating over the middle of a window.
/// Return submits, Escape or clicking elsewhere dismisses.
final class LocationPanel: NSPanel, NSTextFieldDelegate {
    private static let size = NSSize(width: 600, height: 56)

    private let field = NSTextField()
    private let onSubmit: (URL) -> Void

    init(text: String, dark: Bool, onSubmit: @escaping (URL) -> Void) {
        self.onSubmit = onSubmit
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        field.stringValue = text
        field.placeholderString = "Search or enter address"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self

        let stack = NSStackView(views: [icon, field])
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)

        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.size.height / 2
        glass.contentView = stack
        contentView = glass
    }

    override var canBecomeKey: Bool { true }

    func show(over parent: NSWindow) {
        let width = min(Self.size.width, parent.frame.width - 80)
        setFrame(NSRect(x: parent.frame.midX - width / 2, y: parent.frame.midY - Self.size.height / 2,
                        width: width, height: Self.size.height), display: false)
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    override func resignKey() {
        super.resignKey()
        dismiss(refocusParent: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            guard let url = WebPaneView.url(from: field.stringValue) else { return true }
            dismiss(refocusParent: true)
            onSubmit(url)
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(refocusParent: true)
        default:
            return false
        }
        return true
    }

    private func dismiss(refocusParent: Bool) {
        guard let parent else { return }
        parent.removeChildWindow(self)
        orderOut(nil)
        if refocusParent { parent.makeKey() }
    }
}
