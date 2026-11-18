import Foundation

/// FortiOS (FortiGate, FortiWiFi) text CLI. The prompt is the hostname, a space and `#` (`FGT60F # `); a
/// context shows in brackets (`FGT60F (global) # `, `FGT60F (interface) # `). Administrators with a
/// read-only profile may get `$`.
///
/// Netdeck only reads FortiGates. It never changes the console output mode (`config system console` /
/// `set output standard` is a configuration change): the `--More--` pager is answered instead. The only
/// context it enters itself is `config global`, on units with virtual domains, and it leaves with `end`.
public struct FortiOSDialect: CLIDialect {
    public init() {}

    /// `FGT60F #`, `FGT60F (global) #`, `fw-01 $` (trailing blanks already trimmed).
    static let promptPattern = #"^[A-Za-z0-9][A-Za-z0-9_.\-]*( \(([^()\s]+)\))? [#$]$"#
    static let questionPattern = #"\((y/n|Y/N|y/N|Y/n)\)\s*:?\s*$"#

    public func prompt(_ line: String) -> CLIPrompt? {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return nil }
        if l.hasSuffix("login:") { return .login }
        if l.hasSuffix("Password:") || l.hasSuffix("password:") { return .password }
        if l.hasPrefix("--More--") { return .pager }
        if l.range(of: Self.questionPattern, options: .regularExpression) != nil { return .question }
        guard l.range(of: Self.promptPattern, options: .regularExpression) != nil else { return nil }
        return Self.context(l) == nil ? .operational : .configuration
    }

    /// The bracketed context of a prompt line ("global" for `FGT60F (global) #`), nil at the top level.
    static func context(_ line: String) -> String? {
        CiscoParsers.capture(#" \(([^()\s]+)\) [#$]$"#, in: line.trimmingCharacters(in: .whitespaces))?.first
    }

    public var setupCommands: [String] { [] }

    /// After a key, FortiOS takes the pager prompt back off the line with a carriage return, blanks and
    /// another carriage return (or with backspaces, which `JunosCLI.clean` already handles). Without this
    /// the next output line would start with "--More--". A pager still waiting for its key stays visible,
    /// so the session answers it.
    public func normalize(_ raw: String) -> String {
        guard raw.contains("--More--") else { return raw }
        return raw.replacingOccurrences(of: #"--More--[ \t]*(\r[ \t]*)+"#, with: "", options: .regularExpression)
    }

    /// A console can be left inside a configuration context by an earlier session. `abort` leaves it
    /// without saving what that session typed (`end` would save it).
    public func advance(from prompt: CLIPrompt) -> String? {
        switch prompt {
        case .configuration: return "abort\r"
        case .pager: return " "
        case .question: return "n"
        default: return nil
        }
    }

    public func logout(from prompt: CLIPrompt?) -> String? {
        switch prompt {
        case .configuration: return "abort\r"
        case .operational, .shell, .user: return "exit\r"
        case .pager: return "q"
        // Never answer a question with yes on the way out.
        case .question: return "n"
        case .password, nil: return "\u{3}"
        case .login: return nil
        }
    }

    /// `config global` is left with `end` (it holds no edits of its own); any other context with `abort`.
    public func logout(from prompt: CLIPrompt?, line: String) -> String? {
        if prompt == .configuration, Self.context(line) == "global" { return "end\r" }
        return logout(from: prompt)
    }

    public func errors(in output: String) -> [String] { FortiOSParsers.errors(in: output) }
}
