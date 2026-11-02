import AppKit

/// JetBrains New UI file type icons, bundled in Resources/FileIcons
/// (see NOTICE.md there). `name_dark.svg` is used on dark themes.
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(forFileNamed name: String, dark: Bool) -> NSImage? {
        let icon = iconName(for: name)
        let key = dark ? icon + "_dark" : icon
        if let image = cache[key] { return image }
        let directory = Bundle.main.resourceURL?.appendingPathComponent("FileIcons")
        let image = [key, icon].lazy
            .compactMap { directory?.appendingPathComponent($0 + ".svg") }
            .compactMap(NSImage.init(contentsOf:))
            .first
        cache[key] = image
        return image
    }

    static func iconName(for fileName: String) -> String {
        let name = fileName.lowercased()
        if let icon = byName[name] { return icon }
        if name.hasPrefix("dockerfile") || name.hasSuffix(".dockerfile") { return "docker" }
        if name.hasPrefix(".env") { return "config" }
        if name.hasPrefix(".eslintrc") || name.hasPrefix("eslint.config.") { return "eslint" }
        if name.hasPrefix("license") || name.hasPrefix("copying") { return "text" }
        let ext = (name as NSString).pathExtension
        return byExtension[ext] ?? "anyType"
    }

    private static let byName: [String: String] = [
        "makefile": "makefile", "gnumakefile": "makefile",
        "containerfile": "docker", ".dockerignore": "ignored",
        ".gitignore": "gitignore", ".gitmodules": "gitignore", ".gitattributes": "gitignore",
        ".gitkeep": "gitignore",
        ".editorconfig": "editorConfig",
        "cmakelists.txt": "cmake",
        "go.mod": "gomod", "go.sum": "goSum", "go.work": "goWork",
        "jenkinsfile": "jenkins",
        "build.zig": "zig", "build.zig.zon": "zig",
        "manifest.mf": "manifest",
        "gemfile": "ruby", "rakefile": "ruby",
    ]

    private static let byExtension: [String: String] = {
        let groups: [String: [String]] = [
            "archive": ["zip", "tar", "gz", "tgz", "xz", "bz2", "7z", "jar", "dmg", "rar"],
            "binaryData": ["bin", "o", "a", "dylib", "so", "dll", "wasm"],
            "c": ["c", "m"],
            "cmake": ["cmake"],
            "config": ["ini", "cfg", "conf"],
            "cpp": ["cpp", "cc", "cxx", "c++", "mm"],
            "Csharp": ["cs", "csx"],
            "css": ["css", "scss", "sass", "less"],
            "csv": ["csv", "tsv"],
            "dart": ["dart"],
            "docker": ["dockerfile"],
            "elixir": ["ex", "exs"],
            "erlang": ["erl", "hrl"],
            "font": ["ttf", "otf", "woff", "woff2"],
            "gleam": ["gleam"],
            "go": ["go"],
            "gradle": ["gradle"],
            "graphql": ["graphql", "gql"],
            "groovy": ["groovy"],
            "h": ["h", "hh", "hpp", "hxx"],
            "haskell": ["hs", "lhs"],
            "hcl": ["hcl"],
            "html": ["html", "htm"],
            "http": ["http", "rest"],
            "image": ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "icns", "bmp", "tiff", "heic"],
            "java": ["java"],
            "javaClass": ["class"],
            "javaScript": ["js", "mjs", "cjs", "jsx"],
            "json": ["json", "jsonc", "json5"],
            "jupyter": ["ipynb"],
            "kotlin": ["kt", "kts"],
            "lua": ["lua"],
            "makefile": ["mk", "mak"],
            "markdown": ["md", "markdown", "mdx"],
            "microsoftWindows": ["bat", "cmd", "ps1", "exe"],
            "patch": ["patch", "diff"],
            "perl": ["pl", "pm"],
            "php": ["php"],
            "properties": ["properties"],
            "python": ["py", "pyi", "pyw"],
            "rst": ["rst"],
            "ruby": ["rb", "gemspec", "rake"],
            "rustFile": ["rs"],
            "scala": ["scala", "sc"],
            "shell": ["sh", "bash", "zsh", "fish", "command"],
            "sourceMap": ["map"],
            "sql": ["sql"],
            "swift": ["swift"],
            "terraform": ["tf", "tfvars"],
            "text": ["txt", "log", "lock"],
            "toml": ["toml"],
            "tsx": ["tsx"],
            "typeScript": ["ts", "mts", "cts"],
            "vue": ["vue"],
            "xhtml": ["xhtml"],
            "xml": ["xml", "plist", "xib", "storyboard", "entitlements", "xcscheme", "csproj"],
            "xsd": ["xsd"],
            "yaml": ["yml", "yaml"],
            "zig": ["zig", "zon"],
        ]
        var map: [String: String] = [:]
        for (icon, extensions) in groups {
            for ext in extensions { map[ext] = icon }
        }
        return map
    }()
}
