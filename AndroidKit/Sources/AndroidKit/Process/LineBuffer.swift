import Foundation

/// Splits a byte stream into lines on `\n`, `\r\n` or a bare `\r`.
///
/// Bare `\r` matters because `sdkmanager` redraws its progress bar with carriage returns.
/// Bytes are buffered until a full line is available, so multi-byte UTF-8 sequences split
/// across chunks decode correctly.
struct LineBuffer: Sendable {
    private var pending = Data()
    private var lastWasCarriageReturn = false

    mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            switch byte {
            case 0x0A: // \n
                if lastWasCarriageReturn {
                    // Second half of a \r\n pair; the line was already emitted on \r.
                    lastWasCarriageReturn = false
                    continue
                }
                lines.append(flushPending())
            case 0x0D: // \r
                lines.append(flushPending())
                lastWasCarriageReturn = true
                continue
            default:
                pending.append(byte)
            }
            lastWasCarriageReturn = false
        }
        return lines
    }

    /// Returns any trailing partial line once the stream has ended.
    mutating func finish() -> String? {
        guard !pending.isEmpty else { return nil }
        return flushPending()
    }

    private mutating func flushPending() -> String {
        defer { pending.removeAll(keepingCapacity: true) }
        return String(decoding: pending, as: UTF8.self)
    }
}
