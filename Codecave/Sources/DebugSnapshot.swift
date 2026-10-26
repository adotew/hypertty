#if DEBUG
import AppKit
import CoreImage
import GhosttyKit

/// Development aid for verifying rendering without screen-recording
/// permission. Launch with `CODECAVE_SNAPSHOT=/tmp/shot` (and optionally
/// `CODECAVE_SNAPSHOT_INPUT='echo hi'` to run a command in the shell first) and
/// the app writes /tmp/shot.png (the frame libghostty rendered, read back
/// from its IOSurface-backed layer) and /tmp/shot.txt (the screen text),
/// then exits.
enum DebugSnapshot {
    static func scheduleIfRequested(for terminal: TerminalView) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CODECAVE_SNAPSHOT"] else { return }
        let input = env["CODECAVE_SNAPSHOT_INPUT"]

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let input, let surface = terminal.surface {
                // Text arrives like a paste; Return is a real key press so the shell runs it.
                input.withCString { ghostty_surface_text(surface, $0, UInt(input.utf8.count)) }
                var key = ghostty_input_key_s()
                key.keycode = 0x24 // kVK_Return
                for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
                    key.action = action
                    _ = ghostty_surface_key(surface, key)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                write(terminal, to: path)
                exit(0)
            }
        }
    }

    private static func write(_ terminal: TerminalView, to path: String) {
        if let contents = terminal.layer?.contents,
           CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            let image = CIImage(ioSurface: contents as! IOSurface)
            let context = CIContext()
            if let cg = context.createCGImage(image, from: image.extent) {
                let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                try? png?.write(to: URL(fileURLWithPath: path + ".png"))
            }
        } else {
            NSLog("snapshot: layer has no IOSurface contents")
        }

        guard let surface = terminal.surface else { return }
        let size = ghostty_surface_size(surface)
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var report = "grid: \(size.columns)x\(size.rows) cell: \(size.cell_width_px)x\(size.cell_height_px)px\n"
        report += "title: \(terminal.title)\npwd: \(terminal.pwd ?? "-")\n"
        report += "window visible: \(terminal.window?.occlusionState.contains(.visible) ?? false)"
        report += " key: \(terminal.window?.isKeyWindow ?? false) app active: \(NSApp.isActive)\n---\n"
        if ghostty_surface_read_text(surface, selection, &text) {
            report += String(cString: text.text)
            ghostty_surface_free_text(surface, &text)
        }
        try? report.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    }
}
#endif
