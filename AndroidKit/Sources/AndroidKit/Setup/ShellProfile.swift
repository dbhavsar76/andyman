import Foundation

/// Adds (or updates) the Android environment block in the user's shell profile.
///
/// The block is fenced with markers so it can be updated later without touching anything else,
/// and the original file is backed up before every change.
public struct ShellProfileEditor: Sendable {
    public static let beginMarker = "# >>> Andyman >>>"
    public static let endMarker = "# <<< Andyman <<<"

    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// The profile for a shell, e.g. `~/.zshrc`.
    public init(shell: ShellExports.Shell) {
        self.init(file: URL(fileURLWithPath: ShellEnvironment.expandTilde(shell.profilePath)))
    }

    public struct Change: Sendable, Equatable {
        /// Lines the block will contain.
        public var block: [String]
        /// Whether the profile already has an Andyman block (which will be replaced).
        public var replacesExisting: Bool
        /// Whether anything would change at all.
        public var isNeeded: Bool
        public var newContents: String
    }

    public func proposedChange(lines: [String]) -> Change {
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let block = [Self.beginMarker] + lines + [Self.endMarker]
        let blockText = block.joined(separator: "\n")

        if let range = Self.blockRange(in: current) {
            var updated = current
            updated.replaceSubrange(range, with: blockText)
            return Change(block: block, replacesExisting: true, isNeeded: updated != current, newContents: updated)
        }
        var updated = current
        if !updated.isEmpty {
            if !updated.hasSuffix("\n") { updated += "\n" }
            updated += "\n"
        }
        updated += blockText + "\n"
        return Change(block: block, replacesExisting: false, isNeeded: true, newContents: updated)
    }

    /// Writes the block, backing up the existing file first. Returns the backup's location.
    @discardableResult
    public func apply(lines: [String]) throws -> URL? {
        let change = proposedChange(lines: lines)
        guard change.isNeeded else { return nil }
        var backup: URL?
        if FileManager.default.fileExists(atPath: file.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = file.deletingLastPathComponent().appending(path: "\(file.lastPathComponent).andyman-backup-\(stamp)")
            try FileManager.default.copyItem(at: file, to: url)
            backup = url
        } else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try change.newContents.write(to: file, atomically: true, encoding: .utf8)
        return backup
    }

    /// A line outside the Andyman block that also sets a variable.
    public struct OtherAssignment: Sendable, Equatable, Codable {
        public var line: Int
        public var text: String
        /// The line comes after the block, so it overrides what the block sets.
        public var overridesBlock: Bool
    }

    /// Lines outside the block that set `name` (`export NAME=…`, `NAME=…`, `set -gx NAME …`),
    /// so a change can warn that something else in the profile also sets it.
    public func otherAssignments(of name: String) -> [OtherAssignment] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let blockLines: ClosedRange<Int>? = Self.blockRange(in: text).map { range in
            let start = text[..<range.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).count
            let end = text[..<range.upperBound].split(separator: "\n", omittingEmptySubsequences: false).count
            return start...end
        }
        let pattern = #"^\s*(export\s+\#(name)=|\#(name)=|set\s+(-\w+\s+)*\#(name)\s)"#
        return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            let number = index + 1
            if let blockLines, blockLines.contains(number) { return nil }
            guard line.range(of: pattern, options: .regularExpression) != nil else { return nil }
            // Without a block yet, the new one is appended at the end, after every existing line.
            let overrides = blockLines.map { number > $0.upperBound } ?? false
            return OtherAssignment(line: number, text: line.trimmingCharacters(in: .whitespaces), overridesBlock: overrides)
        }
    }

    static func blockRange(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: beginMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        else { return nil }
        return start.lowerBound..<end.upperBound
    }

    /// Whether a shell environment already points at this SDK with its tools on `PATH`
    /// (so there's nothing to add).
    public static func isConfigured(environment: [String: String], sdkPath: String) -> Bool {
        guard let home = environment["ANDROID_HOME"] ?? environment["ANDROID_SDK_ROOT"],
              SDKLocator.Candidate.samePath(home, sdkPath)
        else { return false }
        return ShellEnvironment.pathEntries(environment).contains { SDKLocator.Candidate.samePath($0, "\(sdkPath)/platform-tools") }
    }
}
