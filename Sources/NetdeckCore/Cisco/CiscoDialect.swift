import Foundation

/// Cisco IOS / IOS-XE text CLI: `Switch>` (user mode), `Switch#` (privileged), `Switch(config-if)#`.
public struct CiscoDialect: CLIDialect {
    public init() {}

    // Whole line only: hostname characters, no spaces, ending in > or #. Output lines such as
    // " description Switch#1" or "Switch#1" never match.
    private static let configPrompt = #"^[A-Za-z0-9][A-Za-z0-9._\-]*\([A-Za-z0-9._\-]+\)#$"#
    private static let privilegedPrompt = #"^[A-Za-z0-9][A-Za-z0-9._\-]*#$"#
    private static let userPrompt = #"^[A-Za-z0-9][A-Za-z0-9._\-]*>$"#

    public func prompt(_ line: String) -> CLIPrompt? {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, l.count < 200 else { return nil }
        if l.range(of: #"^-+\s*More\s*-+$"#, options: .regularExpression) != nil { return .pager }
        if l.range(of: Self.configPrompt, options: .regularExpression) != nil { return .configuration }
        if l.range(of: Self.privilegedPrompt, options: .regularExpression) != nil { return .operational }
        if l.range(of: Self.userPrompt, options: .regularExpression) != nil { return .user }
        if l.hasSuffix("Username:") || l.hasSuffix("login:") || l.hasSuffix("Login:") { return .login }
        if l.hasSuffix("Password:") || l.hasSuffix("password:") { return .password }
        if l.hasSuffix("[confirm]") || l.hasSuffix("]?")
            || l.range(of: #"\[(yes/no|yes|no)\]\s*:?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .question
        }
        return nil
    }

    public var setupCommands: [String] { ["terminal length 0", "terminal width 511"] }

    public func advance(from prompt: CLIPrompt) -> String? {
        switch prompt {
        case .configuration: return "end\r"
        // A fresh switch asks "Would you like to enter the initial configuration dialog? [yes/no]".
        case .question: return "no\r"
        case .pager: return " "
        default: return nil
        }
    }

    public func logout(from prompt: CLIPrompt?) -> String? {
        switch prompt {
        case .configuration: return "end\r"
        case .login, .password: return nil
        case .question: return "no\r"
        case .pager: return "q"
        // No prompt as the last line: a log message may have been printed after it. Enter shows the
        // prompt again; "exit" here could wake a console that is already logged out.
        case nil: return "\r"
        default: return "exit\r"
        }
    }

    public var pagerKey: String { " " }
    public var lineEnding: String { "\r" }

    /// Console log messages: `*Nov 17 10:01:02.123: %LINK-3-UPDOWN: ...`, `Nov 17 10:01:02: %SYS-5-CONFIG_I: ...`,
    /// `%LINEPROTO-5-UPDOWN: ...` or with a sequence number `000123: *Nov ...`.
    public func isAsyncMessage(_ line: String) -> Bool {
        line.range(of: #"%[A-Z0-9_]+-\d+-[A-Z0-9_]+:"#, options: .regularExpression) != nil
            && line.range(of: #"^(\d+:\s*)?[*.]?([A-Z][a-z]{2}\s+\d+\s+[\d:.]+[^%]*:\s*)?%[A-Z0-9_]+-\d+-"#, options: .regularExpression) != nil
    }

    public func errors(in output: String) -> [String] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(Self.isError)
    }

    /// `% Invalid input detected`, `% Incomplete command`, `% Ambiguous command`, `% Bad ...`,
    /// `%Command rejected` and the like. Syslog messages (`%LINK-3-UPDOWN: ...`) and warnings are not errors.
    static func isError(_ line: String) -> Bool {
        if line.contains("Command rejected") { return true }
        guard line.hasPrefix("%") else { return false }
        if line.range(of: #"^%[A-Z0-9_]+-\d+-[A-Z0-9_]+:"#, options: .regularExpression) != nil { return false }
        let body = line.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
        if body.isEmpty || body.hasPrefix("warning") || body.hasPrefix("note") { return false }
        return true
    }

    /// The device didn't know the command (older IOS spells some `show` commands differently).
    static func isInvalidInput(_ output: String) -> Bool {
        output.contains("% Invalid input") || output.contains("% Unrecognized command") || output.contains("% Incomplete command")
    }

    public func isLoginFailure(_ text: String) -> Bool {
        let failures = ["Login incorrect", "Permission denied", "% Login invalid", "% Authentication failed",
                        "Login failed", "incorrect password", "Access denied", "% Bad passwords"]
        return failures.contains { text.contains($0) }
    }
}
