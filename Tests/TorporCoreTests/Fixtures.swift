import Foundation
import Testing
@testable import Torpor

// MARK: - A throwaway home directory, for the whole test process

/// Redirects `FileManager.default.homeDirectoryForCurrentUser` — and with it
/// every path Torpor derives from it — at a temporary tree.
///
/// Nothing in this suite may read or write the developer's real state, and
/// three specific traps make that easy to get wrong: `Preferences.save()`
/// overwrites `~/Library/Application Support/Torpor/preferences.json`,
/// `QuotaReader.sessionUsage(live:)` *deletes* files under that same directory,
/// and `TranscriptScanner.totals(cwd:sessionId:)` reads `~/.claude/projects`
/// and populates a process-wide search cache that outlives the test.
///
/// None of `Paths.*` or `TranscriptScanner.projectsRoot` takes an injectable
/// root, so the redirect happens one level down: `CFFIXED_USER_HOME` is
/// CoreFoundation's own override for that lookup, which makes the whole suite
/// hermetic without a line of production change. It is read on every call —
/// these are computed properties — so setting it before the first one runs is
/// all that is required.
///
/// Set once, process-wide, and never unset. A per-test swap would race:
/// swift-testing runs tests in parallel. Tests stay out of each other's way by
/// owning a distinct project directory or session id instead — see
/// `TranscriptSandbox`. The exception is `QuotaReader`, whose snapshot lives at
/// one fixed path per home; that suite is `.serialized` for exactly this
/// reason.
let testHome: URL = {
    // Resolved before the override, so this is the real temporary directory.
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("torpor-home-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    testHomeToRemove = root.path
    setenv("CFFIXED_USER_HOME", root.path, 1)
    atexit(removeTestHome)
    return root
}()

private nonisolated(unsafe) var testHomeToRemove: String?

/// Top-level and capture-free so it converts to a C function pointer.
private func removeTestHome() {
    if let path = testHomeToRemove { try? FileManager.default.removeItem(atPath: path) }
}

/// A directory under `NSTemporaryDirectory()` that the caller deletes.
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
                      tty: tty)
}

// MARK: - Transcripts

/// One session's corner of a throwaway `~/.claude/projects`, laid out the way
/// Claude Code lays out the real one: `<encoded cwd>/<sessionId>.jsonl` beside a
/// `<encoded cwd>/<sessionId>/subagents/**` tree.
///
/// Each sandbox gets its own project directory by default, because the fake
/// home is shared by the whole process and tests run in parallel. Pass an
/// explicit `cwd` only when a test is *about* two sessions sharing a directory.
struct TranscriptSandbox {
    let cwd: String
    let sessionId: String
    let projectDirectory: URL

    init(cwd: String? = nil, sessionId: String = UUID().uuidString) throws {
        self.cwd = cwd ?? "/Users/tester/work/\(UUID().uuidString)"
        self.sessionId = sessionId
        projectDirectory = testHome
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(TranscriptScanner.encode(cwd: self.cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory,
                                                withIntermediateDirectories: true)
    }

    /// The parent conversation.
    var parent: URL { projectDirectory.appendingPathComponent("\(sessionId).jsonl") }

    /// A subagent transcript at `<sessionId>/subagents/<relative>`.
    ///
    /// `relative` is a path, not a name, because the real tree nests: some
    /// subagents sit directly under `subagents/`, others under
    /// `subagents/workflows/wf_<hex>/`. Both were read off this machine.
    func subagent(_ relative: String) -> URL {
        projectDirectory
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent(relative)
    }

    /// Writes whole lines, newline-terminated. A transcript Claude Code is not
    /// mid-write on always ends in a newline, and the scanner deliberately
    /// leaves any partial tail unread.
    func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    func totals(_ scanner: TranscriptScanner) async -> TokenTotals {
        await scanner.totals(cwd: cwd, sessionId: sessionId)
    }
}

/// One assistant record, in the shape `~/.claude/projects` really holds — the
/// field names and nesting below were copied off a live transcript.
///
/// `nil` for `model`, `messageId` or `requestId` omits that key entirely, which
/// is how a record that carries none of them actually looks on disk.
///
/// Serialized with `.sortedKeys`, so two calls that differ only in a token
/// count of the same width produce byte strings of the same length. Several
/// tests depend on that to tell "the scanner re-read this file" apart from "the
/// scanner returned its cache".
func usageLine(model: String? = "claude-opus-4-8",
               messageId: String? = "msg_011Cd4DMF2kdo1MSweX7kbqL",
               requestId: String? = "req_011Cd4DMDqp6dWpzmKyixcXq",
               uuid: String = UUID().uuidString,
               input: Int = 0,
               output: Int = 0,
               cacheRead: Int = 0,
               cacheCreation: Int = 0,
               iterations: Int = 0) -> String {
    var usage: [String: Any] = [
        "input_tokens": input,
        "output_tokens": output,
        "cache_read_input_tokens": cacheRead,
        "cache_creation_input_tokens": cacheCreation,
        "service_tier": "standard",
        "server_tool_use": ["web_search_requests": 0, "web_fetch_requests": 0],
    ]
    if iterations > 0 {
        usage["iterations"] = (0..<iterations).map { _ in
            [
                "type": "message",
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_input_tokens": cacheRead,
                "cache_creation_input_tokens": cacheCreation,
            ] as [String: Any]
        }
    }

    var message: [String: Any] = ["type": "message", "role": "assistant",
                                  "content": [], "usage": usage]
    if let model { message["model"] = model }
    if let messageId { message["id"] = messageId }

    var object: [String: Any] = ["type": "assistant", "message": message,
                                 "uuid": uuid, "isSidechain": false,
                                 "timestamp": "2026-07-15T17:10:24.237Z"]
    if let requestId { object["requestId"] = requestId }

    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

/// A line with no `message.usage` at all — what `journal.jsonl` and every user
/// turn look like. Must contribute nothing rather than be skipped as a file.
func nonUsageLine(_ text: String = "hello") -> String {
    let object: [String: Any] = ["type": "user", "uuid": UUID().uuidString,
                                 "message": ["role": "user", "content": text]]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
