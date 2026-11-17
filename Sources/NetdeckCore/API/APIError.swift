import Foundation

/// Why talking to a device's HTTPS API failed.
public enum APIError: Error, LocalizedError, Equatable {
    /// The address can't be used (empty, malformed).
    case invalidURL(String)
    /// An http:// address: Netdeck only sends credentials over HTTPS.
    case httpNotAllowed
    /// No answer: refused, timed out, unknown host, no network. Carries the system's message.
    case unreachable(String)
    /// The TLS handshake failed (e.g. a protocol version the Mac no longer accepts).
    case tlsFailed(String)
    /// The certificate differs from the one trusted on first connection (`APIPins`).
    case certificateChanged(host: String)
    case unauthorized
    /// The account needs a one-time code, which Netdeck can't ask for.
    case twoFactorRequired
    /// The device wants the account's password changed before it can be used.
    case passwordChangeRequired
    /// The device blocked this Mac's address after failed logins (Synology auto block).
    case blocked
    case notFound
    case badResponse(String)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let text):
            return t("'%@' is not a valid address.", text)
        case .httpNotAllowed:
            return t("Netdeck only connects over HTTPS. Use an https:// address.")
        case .unreachable(let detail):
            return t("Netdeck can't reach the device over HTTPS (%@).", detail)
        case .tlsFailed(let detail):
            return t("A secure connection to the device could not be set up (%@).", detail)
        case .certificateChanged(let host):
            return t("The security certificate of %@ has changed since Netdeck last connected. If the device was reset or got a new certificate, trust the new one. Otherwise someone may be intercepting the connection.", host)
        case .unauthorized:
            return t("Wrong username or password.")
        case .twoFactorRequired:
            return t("This account uses 2-step verification. Use an account without it for Netdeck.")
        case .passwordChangeRequired:
            return t("The device wants this account's password changed. Change it on the device's web page, then try again.")
        case .blocked:
            return t("The device blocked this Mac's address after too many failed logins. Unblock it on the device or wait, then try again.")
        case .notFound:
            return t("The device doesn't offer this information.")
        case .badResponse(let detail):
            return t("The device sent an answer Netdeck doesn't understand (%@).", detail)
        case .http(let code):
            return t("The device answered with HTTP error %@.", String(code))
        }
    }

    var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }
}
