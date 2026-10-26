import AppKit
import GhosttyKit

/// Options for a new surface, e.g. inherited from the focused terminal.
struct SurfaceOptions {
    var workingDirectory: String?
    var fontSize: Float = 0
    var context = GHOSTTY_SURFACE_CONTEXT_WINDOW

    init() {}

    init(inheriting view: TerminalView?, context: ghostty_surface_context_e) {
        self.context = context
        guard let surface = view?.surface else { return }
        let inherited = ghostty_surface_inherited_config(surface, context)
        workingDirectory = inherited.working_directory.map { String(cString: $0) }
        fontSize = inherited.font_size
    }
}

/// Tab-level requests coming from Ghostty keybinds, handled by whatever
/// hosts the terminal.
enum TerminalCommand {
    case newTab
    case closeTab(ghostty_action_close_tab_mode_e)
    case gotoTab(ghostty_action_goto_tab_e)
    case moveTab(Int)
    case renameTab
    case focusSidebar
    case closeWindow
    case newSplit(ghostty_action_split_direction_e)
    case gotoSplit(ghostty_action_goto_split_e)
    case resizeSplit(ghostty_action_resize_split_s)
    case equalizeSplits
    case toggleSplitZoom
}

protocol TerminalViewDelegate: AnyObject {
    /// Title, working directory or bell state changed.
    func terminalDidUpdate(_ terminal: TerminalView)
    /// The terminal became first responder (e.g. clicked or navigated to).
    func terminalDidFocus(_ terminal: TerminalView)
    /// The shell exited or `close_surface` ran. `confirm` is true if a
    /// process is still running.
    func terminalDidRequestClose(_ terminal: TerminalView, confirm: Bool)
    /// Returns false if the command isn't supported.
    func terminal(_ terminal: TerminalView, perform command: TerminalCommand) -> Bool
}

/// An NSView hosting a single libghostty surface. libghostty installs its
/// own Metal layer on the view and renders on its own thread; this class
/// forwards size, focus, keyboard, IME and mouse events to it.
///
/// Input handling follows Ghostty's SurfaceView_AppKit.swift closely
/// since it encodes a lot of hard-won AppKit knowledge.
final class TerminalView: NSView {
    private(set) var surface: ghostty_surface_t?

    weak var delegate: TerminalViewDelegate?

    var title = "" { didSet { delegate?.terminalDidUpdate(self) } }
    var pwd: String? { didSet { delegate?.terminalDidUpdate(self) } }
    /// Set when the terminal rings the bell, cleared once it has focus.
    var bell = false {
        didSet { if bell != oldValue { delegate?.terminalDidUpdate(self) } }
    }
    var cellSize: NSSize = .zero

    private var focused = false
    private var suppressNextLeftMouseUp = false
    private var cursor: NSCursor = .iBeam
    private var windowObservers: [NSObjectProtocol] = []

    // Keyboard / IME state, see keyDown and the NSTextInputClient extension.
    fileprivate var markedText = NSMutableAttributedString()
    fileprivate var keyTextAccumulator: [String]?
    fileprivate var lastPerformKeyEvent: TimeInterval?

    init(app: ghostty_app_t, options: SurfaceOptions = .init()) {
        // Non-zero so the renderer has something to work with before layout.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = options.fontSize
        config.context = options.context

        surface = withOptionalCString(options.workingDirectory) { cwd in
            config.working_directory = cwd
            return ghostty_surface_new(app, &config)
        }
        if surface == nil {
            NSLog("ghostty_surface_new failed")
        }

        updateTrackingAreas()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        teardown()
    }

    /// Frees the surface, which also terminates the child process.
    func teardown() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    static func from(userdata: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func from(surface: ghostty_surface_t) -> TerminalView? {
        from(userdata: ghostty_surface_userdata(surface))
    }

    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Runs a Ghostty keybind action such as "copy_to_clipboard".
    @discardableResult
    func perform(action: String) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    func requestClose(confirm: Bool) {
        delegate?.terminalDidRequestClose(self, confirm: confirm)
    }

    // MARK: Size, scale, display

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let size = convertToBacking(bounds.size)
        guard size.width > 0, size.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            // We scale ourselves; stop Core Animation from scaling our layer.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let backing = convertToBacking(bounds)
        ghostty_surface_set_content_scale(surface, backing.width / bounds.width, backing.height / bounds.height)
        updateSurfaceSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []

        // Hidden tabs are removed from the window: stop drawing them.
        guard let window else {
            if let surface { ghostty_surface_set_occlusion(surface, false) }
            setFocused(false)
            return
        }

        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in self?.updateDisplayID() })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in self?.updateOcclusion() })

        updateDisplayID()
        updateOcclusion()
        viewDidChangeBackingProperties()
    }

    /// Lets the renderer sync to the right display's refresh rate.
    private func updateDisplayID() {
        guard let surface,
              let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        ghostty_surface_set_display_id(surface, number.uint32Value)
    }

    /// Lets the renderer stop drawing while the window is hidden.
    private func updateOcclusion() {
        guard let surface, let window else { return }
        ghostty_surface_set_occlusion(surface, window.occlusionState.contains(.visible))
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { setFocused(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocused(false) }
        return result
    }

    private func setFocused(_ value: Bool) {
        guard focused != value, let surface else { return }
        focused = value
        ghostty_surface_set_focus(surface, value)
        if value {
            bell = false
            delegate?.terminalDidFocus(self)
        }
    }

    // MARK: Cursor

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: cursor = .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: cursor = .resizeUpDown
        default: return
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
        super.updateTrackingAreas()
    }

    private func sendMousePos(_ event: NSEvent, outside: Bool = false) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = GhosttyInput.mods(event.modifierFlags)
        // Ghostty's origin is top-left; negative means the cursor left the view.
        if outside {
            ghostty_surface_mouse_pos(surface, -1, -1, mods)
        } else {
            ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, mods)
        }
    }

    @discardableResult
    private func sendMouseButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(
            surface, state, GhosttyInput.mouseButton(event.buttonNumber), GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        // Like Ghostty, a click that focuses a pane isn't sent to the program.
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
            suppressNextLeftMouseUp = true
            return
        }
        sendMouseButton(event, GHOSTTY_MOUSE_PRESS)
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        sendMouseButton(event, GHOSTTY_MOUSE_RELEASE)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !sendMouseButton(event, GHOSTTY_MOUSE_PRESS) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !sendMouseButton(event, GHOSTTY_MOUSE_RELEASE) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) { sendMouseButton(event, GHOSTTY_MOUSE_PRESS) }
    override func otherMouseUp(with event: NSEvent) { sendMouseButton(event, GHOSTTY_MOUSE_RELEASE) }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func mouseEntered(with event: NSEvent) { sendMousePos(event) }

    override func mouseExited(with event: NSEvent) {
        // While dragging we keep getting drag events outside the view.
        if NSEvent.pressedMouseButtons == 0 { sendMousePos(event, outside: true) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            // Same subjective trackpad multiplier as Ghostty.
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, GhosttyInput.scrollMods(event))
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Apply config such as `macos-option-as-alt` to the modifiers used
        // for text translation.
        let translationGhostty = GhosttyInput.flags(
            ghostty_surface_key_translation_mods(surface, GhosttyInput.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // Reuse the original event when possible; some IMEs (e.g. Korean)
        // depend on event identity.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Collect text produced by interpretKeyEvents (insertText) so we
        // can send it along with the key event.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        let layoutBefore = markedTextBefore ? nil : GhosttyInput.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // An input method switched layouts in response to this key; it's not for the terminal.
        if !markedTextBefore && layoutBefore != GhosttyInput.keyboardLayoutID {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                // Still composing, or this key just ended a composition (e.g.
                // backspace cancelling Japanese input) and must not be encoded.
                composing: markedText.length > 0 || markedTextBefore)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        var action = GHOSTTY_ACTION_RELEASE
        if GhosttyInput.mods(event.modifierFlags).rawValue & mod != 0 {
            // Only a press if this side's key is the one held down.
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    /// Command/control keys reach us here before keyDown. Ghostty keybinds
    /// (from your config) win; everything else continues through AppKit and,
    /// if unhandled, is re-dispatched to keyDown via doCommand(by:).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        var isBinding = false
        var ev = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        (event.characters ?? "").withCString { ptr in
            ev.text = ptr
            var flags = ghostty_binding_flags_e(0)
            isBinding = ghostty_surface_key_is_binding(surface, ev, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass ctrl+return through instead of opening a context menu.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // ctrl+/ beeps on macOS; treat it as ctrl+_ like Ghostty.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"

        default:
            // Synthetic events (zero timestamp) come from AppKit itself.
            if event.timestamp == 0 { return false }

            guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
                lastPerformKeyEvent = nil
                return false
            }

            // Second time we see the same event: nobody else wanted it.
            if let last = lastPerformKeyEvent, last == event.timestamp {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
                break
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else { return false }

        keyDown(with: finalEvent)
        return true
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing

        // Single control characters are encoded by Ghostty itself.
        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(surface, ev)
            }
        }
        return ghostty_surface_key(surface, ev)
    }

    fileprivate func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let string = markedText.string
            string.withCString { ghostty_surface_preedit(surface, $0, UInt(string.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: Menu actions

    @objc func copy(_ sender: Any?) { perform(action: "copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { perform(action: "paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { perform(action: "select_all") }
}

// MARK: - NSTextInputClient

extension TerminalView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        // Outside keyDown (e.g. layout switched mid-composition): update now.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    /// Where the IME candidate window should appear: at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }

        var x = 0.0, y = 0.0
        var width = Double(cellSize.width), height = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }

        // Ghostty's origin is top-left, AppKit's bottom-left.
        let viewRect = NSRect(x: x, y: bounds.height - y, width: width, height: max(height, cellSize.height))
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil, let surface else { return }

        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }

        unmarkText()

        // Inside keyDown: send together with the key event.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        chars.withCString { ghostty_surface_text(surface, $0, UInt(chars.utf8.count)) }
    }

    /// Prevents NSBeep for unhandled commands, and re-dispatches command
    /// keys that AppKit turned into selectors (see performKeyEquivalent).
    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
            return
        }

        switch selector {
        case #selector(moveToBeginningOfDocument(_:)): perform(action: "scroll_to_top")
        case #selector(moveToEndOfDocument(_:)): perform(action: "scroll_to_bottom")
        default: break
        }
    }
}

private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string else { return body(nil) }
    return string.withCString(body)
}
