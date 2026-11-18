import Foundation

/// HPE Aruba AOS-CX (6000–10000 series) text CLI: `switch#` (manager), `switch>` (operator),
/// `switch(config)#`, `switch(config-if)#`, `switch(config-vlan-10)#`.
public struct AOSCXDialect: CLIDialect {
    public init() {}

    // Hostnames start with a letter or digit (at most 32 characters). Whole line only, so output such as
    // "description Switch#1" never matches.
    private static let configPrompt = #"^[A-Za-z0-9][A-Za-z0-9._\-]*\(config[A-Za-z0-9._\-]*\)#$"#
    private static let managerPrompt = #"^[A-Za-z0-9][A-Za-z0-9._\-]*#$"#
    private static let operatorPrompt = #"^[A-Za-z0-9][A-Za-z0-9._\-]*>$"#

    public func prompt(_ line: String) -> CLIPrompt? {
        var l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, l.count < 200 else { return nil }
        // The auto checkpoint reminder is printed right after the prompt: "switch# WARNING".
        if let r = l.range(of: #"[#>]\s+WARNING.*$"#, options: .regularExpression) {
            l = String(l[..<l.index(after: r.lowerBound)])
        }
        if l.hasPrefix("-- MORE --") { return .pager }
        if l.range(of: Self.configPrompt, options: .regularExpression) != nil { return .configuration }
        if l.range(of: Self.managerPrompt, options: .regularExpression) != nil { return .operational }
        if l.range(of: Self.operatorPrompt, options: .regularExpression) != nil { return .user }
        if l.hasSuffix("login:") || l.hasSuffix("Username:") { return .login }
        if l.hasSuffix("Password:") || l.hasSuffix("password:") { return .password }
        if l.range(of: #"\((y/n|yes/no)\)\??\s*:?$"#, options: [.regularExpression, .caseInsensitive]) != nil { return .question }
        return nil
    }

    /// Paging off for this session. AOS-CX has no width setting; the SSH client's terminal size is used.
    public var setupCommands: [String] { ["no page"] }

    public func advance(from prompt: CLIPrompt) -> String? {
        switch prompt {
        case .configuration: return "end\r"
        case .pager: return " "
        default: return nil
        }
    }

    public func logout(from prompt: CLIPrompt?) -> String? {
        switch prompt {
        case .configuration: return "end\r"
        case .login, .password: return nil
        case .question: return "n\r"
        case .pager: return "q"
        case nil: return "\r"
        default: return "exit\r"
        }
    }

    /// Auto checkpoint messages, which arrive on their own after the prompt.
    public func isAsyncMessage(_ line: String) -> Bool {
        line == "WARNING" || line.hasPrefix("WARNING: Restoring configuration") || line == "Restoration successful"
            || line.hasPrefix("Please \"checkpoint auto confirm\"")
    }

    public func errors(in output: String) -> [String] {
        output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter(Self.isError)
    }

    /// `Invalid input: xyz`, `% Command incomplete.`, `Cannot execute command. Internal error.`, `Error: ...`,
    /// `VLAN 30 doesn't exist`.
    static func isError(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.hasPrefix("invalid input") || l.hasPrefix("% ") || l.hasPrefix("error") || l.hasPrefix("cannot ")
            || l.hasPrefix("incomplete") || l.hasPrefix("unable to") || l.contains("doesn't exist") || l.contains("does not exist")
    }

    static func isInvalidInput(_ output: String) -> Bool {
        output.contains("Invalid input") || output.contains("% Command incomplete") || output.contains("Unknown command")
    }

    public func isLoginFailure(_ text: String) -> Bool {
        let failures = ["Login incorrect", "Permission denied", "Authentication failed", "Login failed", "Access denied",
                        "Invalid username or password"]
        return failures.contains { text.contains($0) }
    }
}
