import Foundation

public enum CodexHomeScope {
    /// A background app server as Codex records it for one home.
    public struct RecordedAppServer: Equatable, Sendable {
        public let pid: Int32
        /// The native start time Codex writes beside the PID on macOS. Older records and Linux records have none.
        let startedAt: Date?

        /// A PID record outlives its process, so only the start time tells the recorded process from a reused PID.
        func identifies(pid: Int32, startedAt: Date?) -> Bool {
            guard pid == self.pid, let recorded = self.startedAt, let startedAt else { return false }
            return abs(startedAt.timeIntervalSince(recorded)) < 0.001
        }
    }

    private struct AppServerPIDRecord: Decodable {
        struct Identity: Decodable {
            let startSeconds: UInt64?
            let startMicroseconds: UInt64?
        }

        let pid: Int32
        let processIdentity: Identity?
    }

    /// Daemon-owned and legacy installs use separate PID record files.
    public static func recordedAppServers(codexHome: URL) -> [RecordedAppServer] {
        let directory = codexHome.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("app-server-daemon", isDirectory: true)
        return ["daemon.pid", "app-server.pid"].compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let record = try? JSONDecoder().decode(AppServerPIDRecord.self, from: data)
            else { return nil }
            let startedAt = record.processIdentity.flatMap { identity -> Date? in
                guard let seconds = identity.startSeconds, let microseconds = identity.startMicroseconds
                else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000)
            }
            return RecordedAppServer(pid: record.pid, startedAt: startedAt)
        }
    }

    public static func isAppServerProcess(_ pid: Int32) -> Bool {
        #if canImport(Darwin)
        guard pid > 0, let arguments = DarwinProcessEnumerator.arguments(pid: pid) else { return false }
        return self.isAppServer(arguments: arguments)
        #else
        return false
        #endif
    }

    static func isAppServer(arguments: [String]) -> Bool {
        guard let executable = arguments.first else { return false }
        // Provider-specific by design: match the managed Codex daemon's native command.
        return URL(fileURLWithPath: executable).lastPathComponent == "codex" &&
            arguments.dropFirst().starts(with: ["app-server"]) &&
            arguments.contains("--listen") && arguments.contains("unix://")
    }

    public static func normalizedHomePath(
        _ rawPath: String?,
        fileManager: FileManager = .default)
        -> String?
    {
        guard var path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        if path == "~" {
            path = fileManager.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            path = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
                .path
        } else if path.hasPrefix("~") {
            return nil
        }
        guard (path as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    public static func ambientHomeURL(
        env: [String: String],
        fileManager: FileManager = .default)
        -> URL
    {
        if let raw = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        // Provider-specific by design: `.codex` is the CLI's default on-disk home contract.
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func scopedEnvironment(base: [String: String], codexHome: String?) -> [String: String] {
        guard let codexHome, !codexHome.isEmpty else { return base }
        var env = base
        env["CODEX_HOME"] = codexHome
        return env
    }
}
