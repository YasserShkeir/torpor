import Foundation
import Testing
@testable import Torpor

/// A directory under `NSTemporaryDirectory()` that the caller deletes.
///
/// Nothing in this suite may read or write the developer's real state. Three
/// specific traps this exists to avoid: `Preferences.save()` overwrites
/// `~/Library/Application Support/Torpor/preferences.json`,
/// `QuotaReader.sessionUsage(live:)` *deletes* files under that same directory,
/// and `TranscriptScanner.totals(cwd:sessionId:)` probes `~/.claude/projects`
/// and populates a process-wide search cache that outlives the test.
struct TempDir {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("torpor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    /// A child directory whose name is whatever the caller wants, including
    /// characters a shell would otherwise interpret.
    @discardableResult
    func makeDirectory(named name: String) throws -> URL {
        let child = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        return child
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
    }
}

/// A `HibernatedSession` with only the fields a test cares about set.
///
/// Every field is passed explicitly rather than leaning on the memberwise
/// initializer's optional defaults, so adding a field to the record is a
/// compile error here rather than a silently untested one.
func record(cwd: String = "/tmp/p",
            executable: String = "claude",
            executablePath: String? = nil,
            entrypoint: String? = "cli",
            arguments: [String] = [],
            tty: String? = nil) -> HibernatedSession {
    HibernatedSession(sessionId: "11111111-2222-3333-4444-555555555555",
                      cwd: cwd,
                      name: "p",
                      executable: executable,
                      executablePath: executablePath,
                      arguments: arguments,
                      hibernatedAt: Date(timeIntervalSince1970: 0),
                      reclaimedBytes: 0,
                      version: "2.1.220",
                      entrypoint: entrypoint,
                      tty: tty,
                      revivingSince: nil)
}
