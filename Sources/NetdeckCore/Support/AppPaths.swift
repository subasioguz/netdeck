import Foundation

public enum AppPaths {
    /// True inside the App Sandbox (Mac App Store build). The support directory then lives in the
    /// app's container (~/Library/Containers/<bundle id>/Data/Library/Application Support/Netdeck).
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

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
