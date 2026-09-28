import Foundation

/// Compares version-ish strings so `27.1.12297006` sorts after `27.0.12077973`
/// and `android-37.0` after `android-9`.
public enum VersionComparator {
    public static func isLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }

    /// The leading integer of a version: `"21.0.7"` → 21, `"1.8.0_292"` → 8 (old Java scheme).
    public static func majorVersion(_ version: String) -> Int? {
        let components = version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let first = components.first else { return nil }
        if first == 1, components.count > 1 { return components[1] }
        return first
    }
}
