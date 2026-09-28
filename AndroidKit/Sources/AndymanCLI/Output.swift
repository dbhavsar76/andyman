import Foundation

/// Writes command results.
///
/// With `--json`, everything (including errors) goes to stdout as one JSON document, so a
/// caller only has to parse one stream. Human output goes to stdout, errors to stderr.
enum Output {
    static let schemaVersion = 1

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func json(_ value: some Encodable) throws {
        let data = try encoder().encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func line(_ text: String = "") {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    /// Left-aligned columns; widths ignore ANSI styling.
    static func table(header: [String], rows: [[String]]) {
        let style = Style.current
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { visibleLength($0[column]) }.max() ?? 0 }
        func render(_ row: [String]) -> String {
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell + String(repeating: " ", count: widths[index] - visibleLength(cell))
            }.joined(separator: "  ")
        }
        line(style.dim(render(header)))
        rows.forEach { line(render($0)) }
    }

    /// A simple success result: `message` for humans, `{ok, message, ...fields}` for JSON.
    static func result(json: Bool, message: String, fields: [String: any Encodable]) throws {
        guard json else {
            line(message)
            return
        }
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ string: String) { stringValue = string }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        struct Payload: Encodable {
            let message: String
            let fields: [String: any Encodable]
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(Output.schemaVersion, forKey: Key("schemaVersion"))
                try container.encode(true, forKey: Key("ok"))
                try container.encode(message, forKey: Key("message"))
                for (key, value) in fields {
                    try container.encode(value, forKey: Key(key))
                }
            }
        }
        try Output.json(Payload(message: message, fields: fields))
    }

    private static func visibleLength(_ text: String) -> Int {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
    }

    static func errorLine(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func error(_ error: CLIError, json: Bool) {
        if json {
            struct Envelope: Encodable {
                var schemaVersion = Output.schemaVersion
                var error: CLIError
            }
            try? Output.json(Envelope(error: error))
        } else {
            errorLine("error: \(error.message)")
            if let hint = error.hint { errorLine("hint: \(hint)") }
        }
    }
}

/// ANSI styling for human output; disabled when stdout isn't a terminal or `NO_COLOR` is set.
struct Style: Sendable {
    let enabled: Bool

    static let current = Style(
        enabled: isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    )

    func green(_ text: String) -> String { wrap(text, "32") }
    func yellow(_ text: String) -> String { wrap(text, "33") }
    func red(_ text: String) -> String { wrap(text, "31") }
    func dim(_ text: String) -> String { wrap(text, "2") }
    func bold(_ text: String) -> String { wrap(text, "1") }

    private func wrap(_ text: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }
}
