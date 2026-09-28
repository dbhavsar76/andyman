import Foundation

/// Which Java versions a Gradle version can run on.
/// From Gradle's compatibility matrix (docs.gradle.org/current/userguide/compatibility.html).
public enum GradleCompatibility {
    /// The first Gradle version that runs on each Java version.
    static let firstGradleForJava: [(java: Int, gradle: String)] = [
        (17, "7.3"), (18, "7.5"), (19, "7.6"), (20, "8.3"), (21, "8.5"),
        (22, "8.8"), (23, "8.10"), (24, "8.14"), (25, "9.1"),
    ]

    /// The Android Gradle Plugin 8+ (every current React Native) needs Java 17 or newer.
    public static let minimumJava = 17

    public enum Verdict: Sendable, Equatable {
        case supported
        case tooOld(minimum: Int)
        /// This Gradle version can't run on that Java version.
        case tooNew(maximum: Int)
        /// Newer than anything in our table; it may or may not work.
        case unknown(newestKnown: Int)
    }

    /// The newest Java version `gradle` runs on, as far as this table knows.
    public static func maximumJava(forGradle gradle: String) -> Int? {
        firstGradleForJava.last { !VersionComparator.isLess(gradle, $0.gradle) }?.java
    }

    public static func verdict(java: Int, gradle: String?) -> Verdict {
        if java < minimumJava { return .tooOld(minimum: minimumJava) }
        guard let gradle, let maximum = maximumJava(forGradle: gradle) else { return .supported }
        if java <= maximum { return .supported }
        let newestKnown = firstGradleForJava.last!.java
        // A Gradle release newer than the table's last entry may support newer Java too.
        if maximum == newestKnown, java > newestKnown { return .unknown(newestKnown: newestKnown) }
        return .tooNew(maximum: maximum)
    }
}
