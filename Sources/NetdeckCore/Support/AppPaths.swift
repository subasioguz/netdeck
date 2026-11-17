import Foundation

public enum AppPaths {
    /// ~/Library/Application Support/Netdeck (created on demand). Override with NETDECK_HOME for tests.
    public static func supportDirectory() throws -> URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["NETDECK_HOME"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("Netdeck", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
