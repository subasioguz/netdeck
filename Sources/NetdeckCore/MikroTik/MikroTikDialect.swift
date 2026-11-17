import Foundation

/// RouterOS console: prompts, login options and error lines.
///
/// Prompts: `[admin@MikroTik] > `, `[admin@MikroTik] /ip address> `, safe mode `[admin@MikroTik] <SAFE> `.
/// Login: `<identity> Login:` and `Password:`. Paging and line wrapping are turned off by the login name
/// (`admin+ct511w4098h`), so no setup commands are needed.
public struct MikroTikDialect: CLIDialect {
    public init() {}

    /// Console options after "+": c = no colors, t = no terminal auto-detection (it waits for an answer
    /// Netdeck never sends), 511w = 511 columns, 4098h = 4098 rows (no pager).
    public static let loginOptions = "ct511w4098h"

    /// The login name with console options ("admin" → "admin+ct511w4098h"). Used for SSH and the console.
    public static func loginName(_ username: String) -> String {
        username.contains("+") ? username : username + "+" + loginOptions
    }

    public func loginName(_ username: String) -> String { Self.loginName(username) }

    public var setupCommands: [String] { [] }

    public func prompt(_ line: String) -> CLIPrompt? { Self.promptKind(line) }

    /// `[user@identity] ... >` at the end of a line (redraws can leave text before it).
    static let routerPrompt = #"\[[^\[\]@\s]+@[^\[\]]+\]\s*(/[\w/\- ]*)?(<SAFE>|>)$"#

    public static func promptKind(_ line: String) -> CLIPrompt? {
        let l = tidy(line).trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return nil }
        // The router insists on a new password: nothing may be typed here. `.shell` has no advance step,
        // so the login stops (MikroTikDriver turns it into a clear message).
        if l.lowercased().hasSuffix("new password>") { return .shell }
        if l.range(of: routerPrompt, options: .regularExpression) != nil { return .operational }
        if l.hasSuffix("Login:") || l.hasSuffix("login:") { return .login }
        if l.hasSuffix("Password:") || l.hasSuffix("password:") { return .password }
        if l.contains("Please press \"Enter\" to continue") || l.hasPrefix("-- [Q quit") { return .pager }
        if l.contains("[Y/n]") || l.contains("[y/N]") { return .question }
        // Default-configuration notice after a reset: "type "r"" removes it, any other key keeps it.
        if l.contains("type \"r\"") || l.contains("hit any other key to continue") || l.contains("you will be disconnected") {
            return .question
        }
        return nil
    }

    public func advance(from prompt: CLIPrompt) -> String? {
        switch prompt {
        case .pager: return "\r"       // "Please press "Enter" to continue!"
        case .question: return "n"     // license: no; default configuration: any key but "r" keeps it
        default: return nil
        }
    }

    public func logout(from prompt: CLIPrompt?) -> String? {
        switch prompt {
        case .operational, .user, .configuration: return "/quit\r"
        case .question: return "n"
        case .pager: return "q"
        // An empty password fails and brings the console back to "Login:".
        case .password: return "\r"
        // Unknown state: Ctrl-C ends a running command or clears the line, then quit.
        case nil: return "\u{3}/quit\r"
        case .shell, .login: return nil
        }
    }

    public func errors(in output: String) -> [String] { Self.errorLines(output) }

    static let errorNeedles = [
        "failure:", "bad command name", "syntax error", "expected end of command", "expected command name",
        "expected closing", "no such item", "input does not match any value", "invalid value", "ambiguous value",
        "missing value", "out of range", "not enough permissions", "action cancelled",
    ]

    /// Lines that mean the router rejected a command.
    public static func errorLines(_ output: String) -> [String] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { l in !l.isEmpty && errorNeedles.contains { l.contains($0) } }
    }

    /// The router asks for a new password before the first prompt.
    public static func asksForNewPassword(_ text: String) -> Bool {
        text.lowercased().contains("new password>")
    }

    // MARK: Output framing

    /// Printed after every command (`cmd; :put (...)`): the line only appears when the command finished
    /// without an error, and the echoed expression never matches it.
    static let marker = "netdeck-done"
    static let markerSuffix = "; :put (\"netdeck-\" . \"done\")"

    /// Removes escape sequences `JunosCLI.clean` leaves (ESC 7, ESC 8...) and control characters.
    static func tidy(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}.", with: "", options: .regularExpression)
        out.unicodeScalars.removeAll { ($0.value < 0x20 && $0 != "\n" && $0 != "\t") || $0.value == 0x7F }
        return out
    }

    /// Command output (from `CLISession.run`, first echo line already gone) without the rest of the echo,
    /// the end marker and trailing prompt lines. A long command can wrap or be redrawn, so leading lines
    /// that are pieces of what was sent are dropped too. `confirmed`: the end marker arrived.
    static func output(_ text: String, sent: String, marker expectMarker: Bool) -> (output: String, confirmed: Bool) {
        var lines = tidy(text).components(separatedBy: "\n")
        while let first = lines.first {
            let l = afterPrompt(first.trimmingCharacters(in: .whitespaces))
            if l.isEmpty || sent.contains(l) { lines.removeFirst() } else { break }
        }
        var confirmed = false
        if expectMarker, let i = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) {
            confirmed = true
            lines.removeSubrange(i...)
        }
        while let last = lines.last {
            let l = last.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || promptKind(l) == .operational { lines.removeLast() } else { break }
        }
        return (lines.joined(separator: "\n"), confirmed)
    }

    /// The text after the last router prompt on a line ("[admin@sw] > /system ..." → "/system ...").
    static func afterPrompt(_ line: String) -> String {
        let pattern = #"\[[^\[\]@\s]+@[^\[\]]+\]\s*(/[\w/\- ]*)?(<SAFE>|>)\s?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return line }
        let ns = line as NSString
        guard let m = re.matches(in: line, range: NSRange(location: 0, length: ns.length)).last else { return line }
        return ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespaces)
    }
}

/// RouterOS-specific failures.
public enum MikroTikError: Error, LocalizedError, Equatable {
    /// The router asks for a new password at login (first login after a reset).
    case newPasswordRequired

    public var errorDescription: String? {
        switch self {
        case .newPasswordRequired:
            return t("The router asks for a new password. Log in once with WinBox, WebFig or a terminal, set a password, then connect again.")
        }
    }
}
