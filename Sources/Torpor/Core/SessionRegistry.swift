import Foundation

/// A Claude Code session as Torpor understands it: the registry record joined
/// to live process state and its MCP child processes.
struct Session: Identifiable, Hashable {
    var pid: Int32
    var sessionId: String
    var cwd: String
    var name: String
    var version: String
    /// "interactive", "print", … — VS Code-hosted sessions report "claude-vscode"
    /// as their entrypoint and, on some versions, omit `status` entirely.
    var entrypoint: String
    var startedAt: Date
    /// Registry `status`, when present. Absent on older versions and on the
    /// VS Code entrypoint. There is no fallback: a nil status is treated as
    /// unknown, and an unknown session is never eligible for hibernate or
    /// auto-hibernate.
    var declaredStatus: String?
    /// Registry `updatedAt`: the moment status last *changed*. For a session
    /// that has been sitting idle, this is genuinely "went idle at" — verified
    /// on a session where it was written 43.6h after startedAt.
    var statusChangedAt: Date?

    var ownFootprint: UInt64 = 0
    var ownResident: UInt64 = 0
    var childFootprint: UInt64 = 0
    var childResident: UInt64 = 0
    var childCount: Int = 0

    var isFrozen: Bool = false

    var id: String { sessionId }

    var totalFootprint: UInt64 { ownFootprint + childFootprint }
    /// Retained for diagnostics only. Not shown in the UI: see the note on
    /// ProcProbe.Snapshot — the resident counter is volatile and cannot be
    /// differenced against footprint to yield compressed bytes.
    var totalResident: UInt64 { ownResident + childResident }

    var projectName: String { URL(fileURLWithPath: cwd).lastPathComponent }

    var idleFor: TimeInterval? {
        guard let changed = statusChangedAt, declaredStatus == "idle" else { return nil }
        return Date().timeIntervalSince(changed)
    }

    var age: TimeInterval { Date().timeIntervalSince(startedAt) }
}

/// Reads `~/.claude/sessions/<pid>.json`.
///
/// Two hard-won rules are encoded here:
///
/// 1. **Never discover sessions by process name.** The executable's basename is
///    the Claude Code version string (`2.1.220`), not `claude`, so `pgrep -x
///    claude` finds almost nothing. The registry is the only reliable
///    enumeration source. It is undocumented, so every field is optional.
///
/// 2. **Never trust `status` alone.** It is stamped on transition, not as a
///    heartbeat, so a session that crashes while `busy` leaves a permanently
///    stale `busy` record. Every entry is cross-checked against live process
///    state and a dead PID is treated as gone regardless of what the file says.
enum SessionRegistry {

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    private struct Record: Decodable {
        // Every field is optional. A single renamed or dropped key upstream
        // must not make a whole session invisible — and with hideWhenIdle on,
        // invisible sessions used to mean the app removed itself from the menu
        // bar and asserted "Nothing running."
        var pid: Int32?
        var sessionId: String?
        var cwd: String?
        var startedAt: Double?
        var version: String?
        var kind: String?
        var entrypoint: String?
        var name: String?
        var status: String?
        var updatedAt: Double?
        var statusUpdatedAt: Double?
    }

    /// Outcome of a load, so the UI can tell "no sessions" apart from
    /// "the registry format changed and we understood none of it".
    struct LoadResult {
        var sessions: [Session] = []
        var filesSeen = 0
        var filesDecoded = 0
        /// True when there were registry files but none produced a session —
        /// the signature of an upstream schema change.
        var looksBroken: Bool { filesSeen > 0 && filesDecoded == 0 }
    }

    /// All sessions whose PID is still alive, enriched with memory and children.
    static func loadDetailed() -> LoadResult {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil) else {
            return LoadResult()
        }

        let snapshots = ProcProbe.allPIDs().compactMap { ProcProbe.snapshot($0) }
        let byPID = Dictionary(snapshots.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let childIndex = ProcProbe.childIndex(snapshots)

        var result = LoadResult()
        let decoder = JSONDecoder()

        for file in files where file.pathExtension == "json" {
            result.filesSeen += 1
            guard let data = try? Data(contentsOf: file),
                  let rec = try? decoder.decode(Record.self, from: data) else { continue }

            // Fall back to the filename, which is the pid by construction.
            guard let pid = rec.pid ?? Int32(file.deletingPathExtension().lastPathComponent) else {
                continue
            }
            // Without a session id there is nothing to resume, so the row would
            // be inert; but we still count it as decoded so the "format changed"
            // banner does not fire spuriously.
            guard let sessionId = rec.sessionId else { result.filesDecoded += 1; continue }

            // Cross-check: a registry entry for a dead PID is a stale file.
            guard let proc = byPID[pid] else { result.filesDecoded += 1; continue }

            // Guard against PID reuse. A missing startedAt is disqualifying
            // rather than a free pass: a session we cannot identity-check must
            // not become eligible for signalling.
            guard let started = rec.startedAt else { result.filesDecoded += 1; continue }
            let claimed = Date(timeIntervalSince1970: started / 1000)
            if proc.startTime.timeIntervalSince(claimed) > 60 { result.filesDecoded += 1; continue }

            // cwd falls back to the live process's working directory.
            let cwd = rec.cwd ?? ProcProbe.workingDirectory(pid) ?? ""

            result.filesDecoded += 1
            var session = Session(
                pid: pid,
                sessionId: sessionId,
                cwd: cwd,
                name: rec.name ?? URL(fileURLWithPath: cwd).lastPathComponent,
                version: rec.version ?? "unknown",
                entrypoint: rec.entrypoint ?? rec.kind ?? "cli",
                startedAt: claimed,
                declaredStatus: rec.status,
                statusChangedAt: (rec.statusUpdatedAt ?? rec.updatedAt)
                    .map { Date(timeIntervalSince1970: $0 / 1000) }
            )

            session.ownFootprint = proc.footprint
            session.ownResident = proc.resident

            // MCP servers are separate processes and are the majority of a
            // session's real cost once you count them.
            let kids = ProcProbe.descendants(of: pid, index: childIndex)
            session.childCount = kids.count
            for kid in kids {
                guard let k = byPID[kid] else { continue }
                session.childFootprint += k.footprint
                session.childResident += k.resident
            }

            result.sessions.append(session)
        }

        result.sessions.sort { $0.totalFootprint > $1.totalFootprint }
        return result
    }
}
