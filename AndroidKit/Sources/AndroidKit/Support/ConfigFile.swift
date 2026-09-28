import Foundation

/// Edits `key=value` files (`config.ini`, AVD `.ini`) in place: changed keys keep their line,
/// new keys are appended, and everything else (comments, unknown keys, order) is preserved.
struct ConfigFile {
    private var lines: [String]

    init(contents: String) {
        lines = contents.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
    }

    init(url: URL) throws {
        self.init(contents: try String(contentsOf: url, encoding: .utf8))
    }

    subscript(key: String) -> String? {
        get {
            lines.lazy.compactMap { Self.split($0) }.first { $0.key == key }?.value
        }
        set {
            let index = lines.firstIndex { Self.split($0)?.key == key }
            switch (index, newValue) {
            case let (index?, value?): lines[index] = "\(key)=\(value)"
            case let (index?, nil): lines.remove(at: index)
            case let (nil, value?): lines.append("\(key)=\(value)")
            case (nil, nil): break
            }
        }
    }

    var contents: String { lines.joined(separator: "\n") + "\n" }

    func write(to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func split(_ line: String) -> (key: String, value: String)? {
        guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
        return (line[..<equals].trimmingCharacters(in: .whitespaces), String(line[line.index(after: equals)...]))
    }
}
