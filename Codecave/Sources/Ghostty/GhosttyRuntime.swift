import AppKit
import GhosttyKit

protocol GhosttyRuntimeDelegate: AnyObject {
    /// Ghostty asked for a new window, e.g. via the `new_window` keybind.
    func ghosttyNewWindow(inheriting parent: TerminalView?)
    /// Ghostty asked for a new tab without a focused terminal to put it next to.
    func ghosttyNewTab()
    /// Ghostty asked to quit the app, e.g. via the `quit` keybind.
    func ghosttyQuit()
}

/// Owns the process-wide `ghostty_app_t` and its config, and routes
/// libghostty's runtime callbacks to the right `TerminalView`.
final class GhosttyRuntime {
    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    weak var delegate: GhosttyRuntimeDelegate?

    private var appearanceObservation: NSKeyValueObservation?

    init() {
        config = Self.loadConfig()

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in GhosttyRuntime.wakeup(userdata) },
            action_cb: { app, target, action in GhosttyRuntime.action(app, target: target, action: action) },
            read_clipboard_cb: { userdata, location, state in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, string, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, string: string, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                GhosttyRuntime.writeClipboard(userdata, location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
            }
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            fatalError("ghostty_app_new failed")
        }
        self.app = app

        ghostty_app_set_focus(app, NSApp.isActive)
        updateColorScheme()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidBecomeActive),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidResignActive),
                           name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardSelectionDidChange),
                           name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.updateColorScheme()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }

    /// Reads a color from the current config (e.g. "background").
    func configColor(_ key: String) -> NSColor? {
        guard let config else { return nil }
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(ghostty: color)
    }

    func configDouble(_ key: String) -> Double? {
        guard let config else { return nil }
        var value = 0.0
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        return value
    }

    /// One of the 256 palette colors after applying the theme.
    func paletteColor(_ index: Int) -> NSColor? {
        guard let config, (0..<256).contains(index) else { return nil }
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.utf8.count)) else { return nil }
        return withUnsafeBytes(of: &palette.colors) { raw in
            NSColor(ghostty: raw.bindMemory(to: ghostty_config_color_s.self)[index])
        }
    }

    /// Gives `item` the shortcut your config binds to a keybind action such
    /// as "goto_split:left", if a menu can show it. Menus are how keybinds
    /// reach panes that aren't terminals.
    func applyShortcut(for action: String, to item: NSMenuItem) {
        guard let config else { return }
        let trigger = ghostty_config_trigger(config, action, UInt(action.utf8.count))
        let key: String
        switch trigger.tag {
        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = UnicodeScalar(trigger.key.unicode) else { return }
            key = String(scalar)
        case GHOSTTY_TRIGGER_PHYSICAL:
            guard let code = Self.menuKeys[trigger.key.physical], let scalar = UnicodeScalar(code) else { return }
            key = String(scalar)
        default:
            return
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = GhosttyInput.flags(trigger.mods)
    }

    /// Physical keys a menu shortcut can use (letters come as unicode triggers).
    private static let menuKeys: [ghostty_input_key_e: Int] = [
        GHOSTTY_KEY_ARROW_UP: NSUpArrowFunctionKey,
        GHOSTTY_KEY_ARROW_DOWN: NSDownArrowFunctionKey,
        GHOSTTY_KEY_ARROW_LEFT: NSLeftArrowFunctionKey,
        GHOSTTY_KEY_ARROW_RIGHT: NSRightArrowFunctionKey,
        GHOSTTY_KEY_HOME: NSHomeFunctionKey,
        GHOSTTY_KEY_END: NSEndFunctionKey,
        GHOSTTY_KEY_PAGE_UP: NSPageUpFunctionKey,
        GHOSTTY_KEY_PAGE_DOWN: NSPageDownFunctionKey,
        GHOSTTY_KEY_ENTER: 0x0D,
        GHOSTTY_KEY_TAB: 0x09,
        GHOSTTY_KEY_ESCAPE: 0x1B,
        GHOSTTY_KEY_SPACE: 0x20,
        GHOSTTY_KEY_BACKSPACE: 0x08,
        GHOSTTY_KEY_DELETE: NSDeleteFunctionKey,
    ]

    // MARK: Config

    /// Loads the same files Ghostty.app does: ~/.config/ghostty/config and
    /// ~/Library/Application Support/com.mitchellh.ghostty/config(.ghostty),
    /// plus anything they `config-file` include, on top of Codecave's defaults.
    private static func loadConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        if let defaults = Bundle.main.path(forResource: "defaults", ofType: "ghostty") {
            ghostty_config_load_file(config, defaults)
        }
        ghostty_config_load_default_files(config)
        #if DEBUG
        // Lets tests try settings without touching the user's config.
        if let extra = ProcessInfo.processInfo.environment["CODECAVE_EXTRA_CONFIG"] {
            ghostty_config_load_file(config, extra)
        }
        #endif
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        for i in 0..<ghostty_config_diagnostics_count(config) {
            let diag = ghostty_config_get_diagnostic(config, i)
            if let message = diag.message {
                NSLog("ghostty config: %@", String(cString: message))
            }
        }
        return config
    }

    private func reloadConfig(surface: ghostty_surface_t?, soft: Bool) {
        guard let app else { return }
        if soft {
            if let config { ghostty_app_update_config(app, config) }
            return
        }

        guard let newConfig = Self.loadConfig() else { return }
        if let surface {
            ghostty_surface_update_config(surface, newConfig)
            ghostty_config_free(newConfig)
        } else {
            ghostty_app_update_config(app, newConfig)
            if let config { ghostty_config_free(config) }
            config = newConfig
        }
    }

    private func updateColorScheme() {
        guard let app else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    @objc private func appDidBecomeActive() {
        if let app { ghostty_app_set_focus(app, true) }
    }

    @objc private func appDidResignActive() {
        if let app { ghostty_app_set_focus(app, false) }
    }

    @objc private func keyboardSelectionDidChange() {
        if let app { ghostty_app_keyboard_changed(app) }
    }

    // MARK: Runtime callbacks

    private static func runtime(from userdata: UnsafeMutableRawPointer?) -> GhosttyRuntime? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Called from any thread when libghostty has work for the main thread.
    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let runtime = runtime(from: userdata) else { return }
        DispatchQueue.main.async {
            if let app = runtime.app { ghostty_app_tick(app) }
        }
    }

    private static func action(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let app, let runtime = runtime(from: ghostty_app_userdata(app)) else { return false }

        let surface: ghostty_surface_t? = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
        let view = surface.flatMap(TerminalView.from(surface:))

        func host(_ command: TerminalCommand) -> Bool {
            guard let view, let delegate = view.delegate else { return false }
            return delegate.pane(view, perform: command)
        }

        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            runtime.delegate?.ghosttyQuit()

        case GHOSTTY_ACTION_NEW_WINDOW:
            runtime.delegate?.ghosttyNewWindow(inheriting: view)

        case GHOSTTY_ACTION_NEW_TAB:
            if view == nil {
                runtime.delegate?.ghosttyNewTab()
                return true
            }
            return host(.newTab)

        case GHOSTTY_ACTION_CLOSE_TAB:
            return host(.closeTab(action.action.close_tab_mode))

        case GHOSTTY_ACTION_GOTO_TAB:
            return host(.gotoTab(action.action.goto_tab))

        case GHOSTTY_ACTION_MOVE_TAB:
            return host(.moveTab(Int(action.action.move_tab.amount)))

        case GHOSTTY_ACTION_PROMPT_TITLE:
            return host(.renameTab)

        case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW:
            return host(.focusSidebar)

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            return host(.closeWindow)

        case GHOSTTY_ACTION_NEW_SPLIT:
            return host(.newSplit(action.action.new_split))

        case GHOSTTY_ACTION_GOTO_SPLIT:
            return host(.gotoSplit(action.action.goto_split))

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            return host(.resizeSplit(action.action.resize_split))

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            return host(.equalizeSplits)

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            return host(.toggleSplitZoom)

        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            view?.window?.toggleFullScreen(nil)

        case GHOSTTY_ACTION_SET_TITLE:
            guard let view, let title = action.action.set_title.title else { return false }
            view.title = String(cString: title)

        case GHOSTTY_ACTION_PWD:
            guard let view, let pwd = action.action.pwd.pwd else { return false }
            view.pwd = String(cString: pwd)

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let view else { return false }
            let size = action.action.cell_size
            view.cellSize = view.convertFromBacking(NSSize(width: Double(size.width), height: Double(size.height)))

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setCursorShape(action.action.mouse_shape)

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)

        case GHOSTTY_ACTION_OPEN_URL:
            let v = action.action.open_url
            guard let ptr = v.url else { return false }
            let data = Data(bytes: ptr, count: Int(v.len))
            guard let string = String(data: data, encoding: .utf8) else { return false }
            let url = string.contains("://")
                ? URL(string: string)
                : URL(fileURLWithPath: (string as NSString).expandingTildeInPath)
            guard let url else { return false }
            // Web links open in a split; the rest in their default app.
            if ["http", "https"].contains(url.scheme), host(.openURL(url)) { return true }
            NSWorkspace.shared.open(url)

        case GHOSTTY_ACTION_OPEN_CONFIG:
            let path = ghostty_config_open_path()
            defer { ghostty_string_free(path) }
            guard let ptr = path.ptr else { return false }
            let string = String(decoding: Data(bytes: ptr, count: Int(path.len)), as: UTF8.self)
            NSWorkspace.shared.open(URL(fileURLWithPath: string))

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            runtime.reloadConfig(surface: surface, soft: action.action.reload_config.soft)

        case GHOSTTY_ACTION_RING_BELL:
            view?.bell = true
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }

        case GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_RENDER:
            // Informational; nothing to do for a single-surface window.
            break

        default:
            // Quick terminal, inspector, etc. aren't supported yet.
            return false
        }

        return true
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let view = TerminalView.from(userdata: userdata), let surface = view.surface else { return false }
        guard let string = NSPasteboard.ghostty(location)?.string(forType: .string) else { return false }
        string.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
        return true
    }

    /// Ghostty asks for confirmation on unsafe pastes and OSC 52 reads
    /// (per `clipboard-paste-protection` / `clipboard-read`).
    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = TerminalView.from(userdata: userdata), let surface = view.surface,
              let string else { return }
        let contents = String(cString: string)

        // Don't run a modal loop from inside a libghostty callback.
        DispatchQueue.main.async {
            let alert = NSAlert()
            if request == GHOSTTY_CLIPBOARD_REQUEST_PASTE {
                alert.messageText = "Paste potentially unsafe text?"
                alert.informativeText = "The text contains newlines or control sequences that may run commands:\n\n"
                    + contents.prefix(500)
                alert.addButton(withTitle: "Paste")
            } else {
                alert.messageText = "Allow the program to read your clipboard?"
                alert.addButton(withTitle: "Allow")
            }
            alert.addButton(withTitle: "Cancel")

            let allowed = alert.runModal() == .alertFirstButtonReturn
            // A cancelled request is completed with empty data.
            (allowed ? contents : "").withCString {
                ghostty_surface_complete_clipboard_request(surface, $0, state, true)
            }
        }
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let pasteboard = NSPasteboard.ghostty(location), let content, len > 0 else { return }

        var text: String?
        for i in 0..<len {
            guard let mime = content[i].mime, let data = content[i].data else { continue }
            if String(cString: mime) == "text/plain" { text = String(cString: data) }
        }
        guard let text else { return }

        guard confirm else {
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(text, forType: .string)
            return
        }

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Allow the program to write to your clipboard?"
            alert.informativeText = String(text.prefix(500))
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(text, forType: .string)
        }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let view = TerminalView.from(userdata: userdata) else { return }
        DispatchQueue.main.async { view.requestClose(confirm: processAlive) }
    }
}

extension NSColor {
    convenience init(ghostty color: ghostty_config_color_s) {
        self.init(srgbRed: CGFloat(color.r) / 255,
                  green: CGFloat(color.g) / 255,
                  blue: CGFloat(color.b) / 255,
                  alpha: 1)
    }
}

extension NSPasteboard {
    static let ghosttySelection = NSPasteboard(name: .init("dev.codecave.selection"))

    static func ghostty(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return ghosttySelection
        default: return nil
        }
    }
}
