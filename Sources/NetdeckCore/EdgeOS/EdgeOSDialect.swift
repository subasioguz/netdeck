import Foundation

/// EdgeOS text CLI. Operational mode is a bash shell (`ubnt@er-x:~$`); `configure` enters configuration
/// mode (`ubnt@er-x#`), which prints an `[edit]` line above every prompt.
public struct EdgeOSDialect: CLIDialect {
    public init() {}

    static let userAtHost = #"[A-Za-z0-9_.\-]+@[A-Za-z0-9_.\-]+"#
    /// `user@host:path$` (`#` for root, whose shell EdgeOS treats as operational mode too).
    static let operationalPattern = "^" + userAtHost + #":[^\s]*[$#]$"#
    /// `user@host#`, without a path.
    static let configurationPattern = "^" + userAtHost + "#$"
    static let questionPatterns = [
        #"^Proceed\?"#,
        #"\[(yes|no|confirm|y|n|y/n|yes/no)\](\[[yn]\])?\s*:?\s*$"#,
        #"\((y/n|yes/no)\)\s*[:?]?\s*$"#,
    ]

    public func prompt(_ line: String) -> CLIPrompt? {
        var l = line
        // A terminal title (ESC ] 0;title BEL) may precede the prompt; cleaning leaves "0;title" + BEL.
        if let bel = l.lastIndex(of: "\u{7}") { l = String(l[l.index(after: bel)...]) }
        l = l.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return nil }
        if l.hasSuffix("login:") { return .login }
        if l.hasSuffix("Password:") || l.hasSuffix("password:") { return .password }
        if l == ":" || l.hasPrefix("--More--") || l.hasPrefix("--more--") { return .pager }
        if Self.questionPatterns.contains(where: { l.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return .question
        }
        if l.range(of: Self.operationalPattern, options: .regularExpression) != nil { return .operational }
        if l.range(of: Self.configurationPattern, options: .regularExpression) != nil { return .configuration }
        return nil
    }

    /// Paging off and a wide terminal, as netmiko does for EdgeRouter/VyOS.
    public var setupCommands: [String] { ["set terminal length 0", "set terminal width 512"] }

    /// A console can be left in configuration mode by an earlier session; leave it without keeping
    /// that session's uncommitted edits (they live only in that session).
    public func advance(from prompt: CLIPrompt) -> String? {
        switch prompt {
        case .configuration: return "exit discard\r"
        case .pager: return "q"
        case .question: return "\u{3}"
        default: return nil
        }
    }

    public func logout(from prompt: CLIPrompt?) -> String? {
        switch prompt {
        case .configuration: return "exit discard\r"
        case .operational, .shell, .user: return "exit\r"
        case .pager: return "q"
        // Never answer a question with yes on the way out; Ctrl-C also clears a half-typed line.
        case .question, .password, nil: return "\u{3}"
        case .login: return nil
        }
    }

    /// `[edit]` / `[edit interfaces ethernet eth1]` above the configuration-mode prompt.
    public func isTrailingNoise(_ line: String) -> Bool {
        line.range(of: #"^\[edit( [^\]]*)?\]$"#, options: .regularExpression) != nil
    }

    public func errors(in output: String) -> [String] { EdgeOSParsers.errors(in: output) }
}
