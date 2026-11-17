import Foundation

/// Why connecting or reading failed, in the terms the error cards use (§3.13).
public enum ConnectionFailure: Equatable, Sendable {
    case wrongPassword
    /// The serial device file is gone: adapter unplugged or on another USB port.
    case cableNotFound(path: String)
    /// The serial port is held by another app (screen, minicom...).
    case portBusy(path: String)
    /// The port opened but no usable prompt arrived (booting, or wrong speed).
    case notResponding(seconds: Int)
    case sshUnreachable(detail: String)
    case hostKeyChanged(detail: String)
    case droppedWhileReading(detail: String)
    /// HTTPS: no answer from the device's API (refused, timed out, unknown host).
    case apiUnreachable(detail: String)
    /// HTTPS: the device's certificate differs from the one trusted on first connection.
    case certificateChanged(host: String)
    case other(String)

    /// `reading` is true when the failure happened after login, while the snapshot was being read.
    /// `elapsed` is how long the attempt ran. `fileExists` is injectable for tests.
    public static func classify(_ error: Error, connection: DeviceProfile.Connection, reading: Bool, elapsed: TimeInterval,
                                fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ConnectionFailure {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let serialPath: String? = { if case let .serial(path, _) = connection { return path }; return nil }()
        let isSSH: Bool = { if case .ssh = connection { return true }; return false }()

        if let e = error as? CLIError {
            switch e {
            case .authenticationFailed:
                return .wrongPassword
            case .unrecognizedPrompt:
                return reading ? .droppedWhileReading(detail: message) : .notResponding(seconds: max(1, Int(elapsed.rounded())))
            case .timeout:
                if reading { return .droppedWhileReading(detail: message) }
                if let p = serialPath, !fileExists(p) { return .cableNotFound(path: p) }
                return .notResponding(seconds: max(1, Int(elapsed.rounded())))
            case let .closed(reason):
                if isSSH {
                    if reason.contains("Host key verification failed") || reason.contains("IDENTIFICATION HAS CHANGED") {
                        return .hostKeyChanged(detail: reason)
                    }
                    if reason.contains("Permission denied") { return .wrongPassword }
                    return reading ? .droppedWhileReading(detail: reason) : .sshUnreachable(detail: reason)
                }
                guard let p = serialPath else { return .other(reason) }
                return fileExists(p) ? .droppedWhileReading(detail: reason) : .cableNotFound(path: p)
            }
        }
        if let e = error as? APIError {
            switch e {
            case .unauthorized: return .wrongPassword
            case let .certificateChanged(host): return .certificateChanged(host: host)
            case let .unreachable(detail): return reading ? .droppedWhileReading(detail: detail) : .apiUnreachable(detail: detail)
            default: return .other(message)
            }
        }
        if let e = error as? TransportError {
            switch e {
            case let .openFailed(m):
                guard let p = serialPath else { return isSSH ? .sshUnreachable(detail: m) : .other(message) }
                if !fileExists(p) { return .cableNotFound(path: p) }
                if m == t("The port is in use by another app.") || m.localizedCaseInsensitiveContains("busy") { return .portBusy(path: p) }
                return .other(message)
            case .writeFailed, .notOpen:
                if let p = serialPath, !fileExists(p) { return .cableNotFound(path: p) }
                return reading ? .droppedWhileReading(detail: message) : .other(message)
            }
        }
        return .other(message)
    }
}
