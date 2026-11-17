import Foundation

/// A bidirectional byte stream to a device (serial console, SSH, ...).
public protocol Transport: AnyObject, Sendable {
    /// Human-readable target, e.g. "/dev/cu.usbserial-XYZ @ 9600" or "admin@192.0.2.10".
    var displayName: String { get }
    /// Opens the stream. `onData` is called in arrival order on a private queue.
    /// `onClose` is called once when the stream ends; the argument is an error description or nil.
    func open(
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (String?) -> Void
    ) throws
    func send(_ data: Data) throws
    func close()
}

public enum TransportError: Error, LocalizedError, Equatable {
    case openFailed(String)
    case writeFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return t("Could not open the connection: %@", m)
        case .writeFailed(let m): return t("Could not send data: %@", m)
        case .notOpen: return t("The connection is not open.")
        }
    }
}
