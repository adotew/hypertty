import AppKit

/// Brand icons for programs running in a terminal, bundled in
/// Resources/AppIcons (see NOTICE.md there). The program is the first word
/// of the terminal title, which the shell sets to the command line.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(forTitle title: String) -> NSImage? {
        guard let word = title.split(separator: " ").first?.lowercased(),
              // A path at the prompt ("~/code/rust"), not a command.
              !word.contains(where: { "/~@:".contains($0) }),
              let name = byCommand[word] else { return nil }
        if let image = cache[name] { return image }
        let url = Bundle.main.resourceURL?.appendingPathComponent("AppIcons/\(name).svg")
        guard let svg = url.flatMap(NSImage.init(contentsOf:)) else { return nil }
        let image: NSImage
        if fullColor.contains(name) {
            image = svg
        } else if let hex = colors[name] {
            image = NSImage(size: svg.size, flipped: false) { rect in
                svg.draw(in: rect)
                NSColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: 1).set()
                rect.fill(using: .sourceAtop)
                return true
            }
        } else {
            // Tinted like the terminal symbol.
            svg.isTemplate = true
            image = svg
        }
        cache[name] = image
        return image
    }

    private static let byCommand: [String: String] = [
        "nvim": "neovim", "vim": "vim", "vi": "vim",
        "cargo": "rust", "rustc": "rust", "rustup": "rust", "rustlings": "rust",
        "pi": "pi", "π": "pi",
        "claude": "claude", "codex": "openai", "opencode": "opencode",
        "git": "git", "lazygit": "git", "gitui": "git", "gh": "github",
        "npm": "npm", "npx": "npm", "node": "nodedotjs", "bun": "bun", "bunx": "bun",
        "swift": "swift", "swiftc": "swift", "xcodebuild": "xcode", "xcrun": "xcode",
        "python": "python", "python3": "python", "uv": "uv", "uvx": "uv",
        "zig": "zig", "make": "make", "mvn": "apachemaven", "mvnw": "apachemaven",
        "java": "openjdk", "flutter": "flutter", "tmux": "tmux", "htop": "htop",
    ]

    /// Multicolor logos, drawn as they are.
    private static let fullColor: Set = ["neovim"]

    /// Brand colors that read on dark and light sidebars; the others
    /// (black ones like Rust's) are tinted instead.
    private static let colors: [String: Int] = [
        "vim": 0x019733, "claude": 0xD97757, "git": 0xF03C2E,
        "npm": 0xCB3837, "nodedotjs": 0x5FA04E, "swift": 0xF05138, "xcode": 0x147EFB,
        "python": 0x3776AB, "uv": 0xDE5FE9, "zig": 0xF7A41D, "apachemaven": 0xC71A36,
        "flutter": 0x02569B, "tmux": 0x1BB91F, "htop": 0x009020,
    ]
}
