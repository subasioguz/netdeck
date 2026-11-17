import CryptoKit
import Foundation

/// Local config backups: one file per distinct config, per device.
public struct BackupStore: Sendable {
    public struct Backup: Sendable, Identifiable, Equatable {
        public var url: URL
        public var date: Date
        public var reason: String
        public var id: URL { url }
    }

    public let deviceID: String

    public init(deviceID: String) { self.deviceID = deviceID }

    func directory() throws -> URL {
        let dir = try AppPaths.supportDirectory().appendingPathComponent("backups/\(deviceID)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Saves unless the newest backup has identical content. Returns the backup (new or existing).
    @discardableResult
    public func save(configText: String, reason: String, date: Date = .now) throws -> Backup {
        let body = Self.normalized(configText)
        if let latest = try list().first, let old = try? String(contentsOf: latest.url, encoding: .utf8),
           Self.normalized(Self.stripHeader(old)) == body {
            return latest
        }
        let stamp = Self.fileFormatter.string(from: date)
        let hash = SHA256.hash(data: Data(body.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let url = try directory().appendingPathComponent("\(stamp)-\(hash).set")
        let header = "# Netdeck backup · \(ISO8601DateFormatter().string(from: date)) · \(reason)\n"
        try (header + body).write(to: url, atomically: true, encoding: .utf8)
        return Backup(url: url, date: date, reason: reason)
    }

    public func list() throws -> [Backup] {
        let dir = try directory()
        let urls = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".set") }
            .map { dir.appendingPathComponent($0) }
        return urls.compactMap { url -> Backup? in
            let name = url.deletingPathExtension().lastPathComponent
            guard let date = Self.fileFormatter.date(from: String(name.prefix(16))) else { return nil }
            let firstLine = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n").first ?? ""
            let reason = firstLine.components(separatedBy: " · ").last ?? ""
            return Backup(url: url, date: date, reason: reason)
        }.sorted { $0.date > $1.date }
    }

    public func read(_ backup: Backup) throws -> String {
        Self.stripHeader(try String(contentsOf: backup.url, encoding: .utf8))
    }

    static func stripHeader(_ s: String) -> String {
        s.hasPrefix("# Netdeck") ? s.components(separatedBy: "\n").dropFirst().joined(separator: "\n") : s
    }

    /// Ignore lines that change on every read (none today, but keep whitespace stable).
    static func normalized(_ s: String) -> String {
        s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
    }

    static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
}

/// Line-level diff (set format) for showing what changed between two configs.
public enum SetDiff {
    public struct Result: Equatable, Sendable {
        public var removed: [String]
        public var added: [String]

        public init(removed: [String], added: [String]) {
            self.removed = removed
            self.added = added
        }
    }

    public static func diff(old: String, new: String) -> Result {
        let a = lines(old), b = lines(new)
        let sa = Set(a), sb = Set(b)
        return Result(removed: a.filter { !sb.contains($0) }, added: b.filter { !sa.contains($0) })
    }

    static func lines(_ s: String) -> [String] {
        s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("set ") }
    }
}
