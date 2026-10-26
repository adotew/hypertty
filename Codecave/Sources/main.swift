import AppKit
import GhosttyKit

// Always use the resources bundled with this app. When launched from a
// Ghostty terminal we'd otherwise inherit Ghostty.app's resources dir,
// which may not match the libghostty version we link against.
if let resources = Bundle.main.resourceURL?.appendingPathComponent("ghostty") {
    setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)
}

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    fatalError("ghostty_init failed")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
