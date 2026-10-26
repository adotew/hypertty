import AppKit
import CoreServices

/// A file or directory in the sidebar's tree. A chain of directories that
/// each contain only one directory is shown as one node ("vendor / ghostty"),
/// whose `url` is the innermost directory.
final class FileNode {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// Matched by .gitignore (or inside an ignored directory).
    let isIgnored: Bool
    /// Loaded when first needed.
    var children: [FileNode]?

    init(url: URL, name: String, isDirectory: Bool, isIgnored: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isIgnored = isIgnored
    }

    var path: String { url.path }
}

/// Lists directories for the tree: directories first, hidden files shown,
/// `.git` and `.DS_Store` skipped.
struct FileLister {
    /// Absolute paths git ignores. A directory listed here covers its contents.
    var ignoredPaths: Set<String> = []
    var showsIgnored = true

    private static let skipped: Set<String> = [".git", ".DS_Store"]

    func children(of node: FileNode) -> [FileNode] {
        entries(of: node.url).compactMap { url, isDirectory in
            let ignored = node.isIgnored || ignoredPaths.contains(url.path)
            if ignored && !showsIgnored { return nil }
            guard isDirectory else {
                return FileNode(url: url, name: url.lastPathComponent, isDirectory: false, isIgnored: ignored)
            }
            return compacted(url, ignored: ignored)
        }
    }

    private func compacted(_ url: URL, ignored: Bool) -> FileNode {
        var url = url
        var name = url.lastPathComponent
        var ignored = ignored
        while true {
            let entries = entries(of: url).filter { showsIgnored || !ignoredPaths.contains($0.url.path) }
            guard entries.count == 1, let only = entries.first, only.isDirectory else { break }
            url = only.url
            name += " / " + url.lastPathComponent
            ignored = ignored || ignoredPaths.contains(url.path)
        }
        return FileNode(url: url, name: name, isDirectory: true, isIgnored: ignored)
    }

    private func entries(of directory: URL) -> [(url: URL, isDirectory: Bool)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { !Self.skipped.contains($0.lastPathComponent) }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                var isDirectory = values?.isDirectory ?? false
                if values?.isSymbolicLink == true {
                    isDirectory = (try? url.resolvingSymlinksInPath()
                        .resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                }
                return (url.standardizedFileURL, isDirectory)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
    }
}

enum ProjectRoot {
    /// The enclosing git work tree, or the directory itself.
    static func containing(_ directory: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var url = directory.standardizedFileURL
        while url.path != "/" && url != home {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        return directory.standardizedFileURL
    }

    /// Paths git ignores under `root` (empty outside a repository). Runs git,
    /// so call it off the main thread.
    static func ignoredPaths(in root: URL) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "ls-files", "--others", "--ignored",
                             "--exclude-standard", "--directory", "-z"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return Set(data.split(separator: 0).compactMap { bytes in
            String(bytes: bytes, encoding: .utf8).map { root.appendingPathComponent($0).standardizedFileURL.path }
        })
    }
}

/// Calls `onChange` (on the main queue) with the directories that changed
/// under `url`, except inside `.git`.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let gitDirectory: String
    private let onChange: ([String]) -> Void

    init(url: URL, onChange: @escaping ([String]) -> Void) {
        gitDirectory = url.appendingPathComponent(".git").path
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).prefix(count)
                .filter { !$0.hasPrefix(watcher.gitDirectory) }
                .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            if !paths.isEmpty { watcher.onChange(paths) }
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
