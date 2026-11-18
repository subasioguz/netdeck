import Foundation

/// HPE Aruba AOS-S / ProCurve (2530–5400R) text CLI: `HP-2930M#` (manager), `HP-2930M>` (operator),
/// `HP-2930M(config)#`, `HP-2930M(eth-1)#`, `HP-2930M(vlan-10)#`. Hostnames may contain spaces
/// ("ProCurve Switch 2650#"). After an SSH login the switch shows "Press any key to continue"; its output
/// is drawn with VT100 cursor movement, which the default `normalize` and `JunosCLI.clean` take apart.
public struct AOSSDialect: CLIDialect {
    public init() {}

    private static let host = #"[A-Za-z0-9][A-Za-z0-9 _.\-]*"#
    private static let configPrompt = "^" + host + #"\((config|eth-[A-Za-z0-9/\-,]+|vlan-\d+|[a-z][a-z0-9\-]*)\)#$"#
    private static let managerPrompt = "^" + host + "#$"
    private static let operatorPrompt = "^" + host + ">$"

    public func prompt(_ line: String) -> CLIPrompt? {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, l.count < 200 else { return nil }
        if l.hasPrefix("-- MORE --") || l.hasSuffix("Press any key to continue") { return .pager }
        if l.range(of: #"\[?\(?y/n(/\^C)?\]?\)?\??\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil { return .question }
        if l.range(of: Self.configPrompt, options: .regularExpression) != nil { return .configuration }
        if l.range(of: Self.managerPrompt, options: .regularExpression) != nil { return .operational }
        if l.range(of: Self.operatorPrompt, options: .regularExpression) != nil { return .user }
        if l.hasSuffix("Username:") || l.hasSuffix("login:") || l.hasSuffix("Login Name:") { return .login }
        if l.hasSuffix("Password:") || l.hasSuffix("password:") { return .password }
        return nil
    }

    /// Paging off and a wide terminal (manager level is needed for `no page`).
    public var setupCommands: [String] { ["no page", "terminal width 511"] }

    public func advance(from prompt: CLIPrompt) -> String? {
        switch prompt {
        case .pager: return "\r"
        case .configuration: return "exit\r"
        default: return nil
        }
    }

    public func logout(from prompt: CLIPrompt?) -> String? {
        logout(from: prompt, line: "")
    }

    /// `logout` asks "Do you want to log out [y/n]?" and, when the running configuration differs from the
    /// startup configuration, "Do you want to save current configuration [y/n/^C]?". Never save here: a change
    /// waiting for confirmation must not reach the startup configuration.
    public func logout(from prompt: CLIPrompt?, line: String) -> String? {
        switch prompt {
        case .configuration: return "exit\r"
        case .login, .password: return nil
        case .question:
            let l = line.lowercased()
            if l.contains("save") { return "n\r" }
            if l.contains("log out") || l.contains("logout") { return "y\r" }
            return "n\r"
        case .pager: return "\r"
        case nil: return "\r"
        default: return "logout\r"
        }
    }

    public var pagerKey: String { " " }

    public func errors(in output: String) -> [String] {
        output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter(Self.isError)
    }

    /// `Invalid input: x`, `Incomplete input: x`, `Ambiguous input: x`, `Module not present for port or invalid
    /// port: x`, `Not authorized to run this command`, `... does not exist`, `Unable to ...`, `Error ...`.
    static func isError(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.hasPrefix("invalid input") || l.hasPrefix("incomplete input") || l.hasPrefix("ambiguous input")
            || l.hasPrefix("module not present") || l.hasPrefix("not authorized") || l.hasPrefix("unable to")
            || l.hasPrefix("error") || l.hasPrefix("failed") || l.contains("does not exist") || l.contains("not found")
            || l.hasPrefix("cannot ") || l.hasPrefix("value ") && l.contains("out of range")
    }

    static func isInvalidInput(_ output: String) -> Bool {
        output.contains("Invalid input") || output.contains("Incomplete input")
    }

    public func isLoginFailure(_ text: String) -> Bool {
        let failures = ["Invalid password", "Login incorrect", "Permission denied", "Authentication failed", "Access denied",
                        "Invalid username or password"]
        return failures.contains { text.contains($0) }
    }
}
