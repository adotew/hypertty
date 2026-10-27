import Foundation
import CoreServices

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
}

/// A changed file, as listed by `git status`.
struct GitChange: Equatable {
    /// Relative to the work tree. Untracked directories end in "/".
    let path: String
    /// M, A, D, R, C, U (conflict) or ? (untracked).
    let status: Character
    /// In the index (vs. the work tree). A file can appear both ways.
    let staged: Bool
}

struct GitStatus: Equatable {
    var branch = ""
    var ahead = 0
    var behind = 0
    var changes: [GitChange] = []

    var staged: [GitChange] { changes.filter(\.staged) }
    var unstaged: [GitChange] { changes.filter { !$0.staged } }

    /// Parses `git status --porcelain=v1 -z --branch`.
    init(porcelain output: String) {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true)[...]
        if let header = fields.first, header.hasPrefix("## ") {
            fields = fields.dropFirst()
            parseBranch(header.dropFirst(3))
        }
        while let field = fields.popFirst(), field.count > 3 {
            let chars = Array(field.prefix(2))
            let index = chars[0], worktree = chars[1]
            let path = String(field.dropFirst(3))
            // Renames and copies are followed by the original path.
            if index == "R" || index == "C" { fields = fields.dropFirst() }
            if index == "?" {
                changes.append(GitChange(path: path, status: "?", staged: false))
                continue
            }
            let conflicted = index == "U" || worktree == "U" || (index == worktree && (index == "A" || index == "D"))
            if conflicted {
                changes.append(GitChange(path: path, status: "U", staged: false))
                continue
            }
            if index != " " { changes.append(GitChange(path: path, status: index, staged: true)) }
            if worktree != " " { changes.append(GitChange(path: path, status: worktree, staged: false)) }
        }
    }

    init() {}

    /// "main...origin/main [ahead 1, behind 2]", "No commits yet on main",
    /// "HEAD (no branch)".
    private mutating func parseBranch(_ line: Substring) {
        let parts = line.components(separatedBy: " [")
        var name = parts[0]
        if name.hasPrefix("No commits yet on ") { name.removeFirst("No commits yet on ".count) }
        branch = name.components(separatedBy: "...")[0]
        guard parts.count > 1 else { return }
        for item in parts[1].dropLast().components(separatedBy: ", ") {
            let words = item.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = count }
            if words[0] == "behind" { behind = count }
        }
    }
}

enum Git {
    /// The repository's status, or nil outside a work tree. Runs git, so
    /// call it off the main thread.
    static func status(in root: URL) -> GitStatus? {
        // --no-optional-locks: don't refresh the index, which would wake
        // the DirectoryWatcher and refresh again.
        run(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--branch"], in: root)
            .map(GitStatus.init(porcelain:))
    }

    static func stage(_ path: String, in root: URL) {
        _ = run(["add", "--", path], in: root)
    }

    static func unstage(_ path: String, in root: URL) {
        _ = run(["restore", "--staged", "--", path], in: root)
    }

    /// Standard output, or nil if git failed.
    private static func run(_ arguments: [String], in root: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Calls `onChange` (on the main queue) when anything under `url` changes,
/// including `.git` (commits, staging, checkouts).
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
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
