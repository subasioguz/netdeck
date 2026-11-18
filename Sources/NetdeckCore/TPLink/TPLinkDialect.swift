import Foundation

/// TP-Link Omada / JetStream managed switches (SG2xxx, SG3xxx, SX3xxx, T1600G–T3700G): `SG3428>` (user),
/// `SG3428#` (privileged), `SG3428(config)#`, `SG3428(config-if)#`, `SG3428(config-if-range)#`,
/// `SG3428(config-vlan)#`. The prompt carries the hostname, by default the model name.
///
/// The pager ("Press any key to continue (Q to quit)") erases itself with carriage returns, sent as CR NUL,
/// and the output goes on in the same line; `normalize` takes it out once it has been answered. Paging is
/// answered rather than turned off: `no clipaging` is a configuration line that would end up in the startup
/// configuration on the next save.
public struct TPLinkDialect: CLIDialect {
    public init() {}

    static let pager = "Press any key to continue (Q to quit)"
    private static let promptPattern = #"^[A-Za-z0-9._\-]+(\(([a-z][a-z0-9\-]*)\))?([#>])$"#

    public func prompt(_ line: String) -> CLIPrompt? {
        let l = line.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, l.count < 200 else { return nil }
        if l.hasSuffix(Self.pager) { return .pager }
        if l.range(of: #"\((y/n|yes/no)\)\s*:?\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil { return .question }
        if let c = CiscoParsers.capture(Self.promptPattern, in: l) {
            if !c[1].isEmpty { return c[2] == "#" ? .configuration : nil }
            return c[2] == "#" ? .operational : .user
        }
        if l.hasSuffix("User:") || l.hasSuffix("Username:") || l.hasSuffix("login:") { return .login }
        if l.hasSuffix("Password:") || l.hasSuffix("password:") { return .password }
        return nil
    }

    /// Nothing to set up: the pager is answered (see the type's note).
    public var setupCommands: [String] { [] }

    /// The CLI takes CR as Enter; every tool that drives it sends CR LF (Netmiko, Oxidized).
    public var lineEnding: String { "\r\n" }

    /// An answered pager: the prompt text, then CR (NUL) and spaces that erase it.
    public func normalize(_ raw: String) -> String {
        var s = raw
        if s.contains(Self.pager) {
            s = s.replacingOccurrences(of: #"Press any key to continue \(Q to quit\)[\u0000 ]*\r[\r\u0000 ]*"#, with: "",
                                       options: .regularExpression)
        }
        return s.replacingOccurrences(of: "\u{0}", with: "")
    }

    public func advance(from prompt: CLIPrompt) -> String? {
        switch prompt {
        case .pager: return " "
        case .configuration: return "end\r\n"
        default: return nil
        }
    }

    /// `exit` from privileged mode only drops to user mode and the session stays; abandoned sessions fill the
    /// switch's small session table, so the way out is always `logout`. No save question is known; if one
    /// comes, the answer is no.
    public func logout(from prompt: CLIPrompt?) -> String? {
        switch prompt {
        case .configuration: return "end\r\n"
        case .login, .password: return nil
        case .question: return "N\r\n"
        case .pager: return "q"
        case nil: return "\r\n"
        default: return "logout\r\n"
        }
    }

    public var pagerKey: String { " " }

    public func errors(in output: String) -> [String] {
        output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter(Self.isError)
    }

    /// `Error: Bad command`, `Error: Invalid parameter.`, `Missing parameter data`, `Invalid port number.`,
    /// `Operation Fail. This command can't work in controller mode.`, `Failed to ...`, and the description
    /// check ("The description only allows letters, numbers, space and some special symbols").
    static func isError(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.hasPrefix("error") || l.hasPrefix("missing parameter") || l.hasPrefix("invalid ") || l.hasPrefix("failed")
            || l.hasPrefix("operation fail") || l.contains("can't work in controller mode") || l.contains("only allows")
            || l.hasPrefix("bad command") || l.hasPrefix("unknown command") || l.hasPrefix("incomplete command")
    }

    static func isBadCommand(_ output: String) -> Bool {
        output.contains("Bad command") || output.contains("Missing parameter") || output.contains("Invalid parameter")
    }

    public func isLoginFailure(_ text: String) -> Bool {
        let failures = ["Login invalid", "Login incorrect", "Authentication failed", "Access denied", "Permission denied",
                        "User name or password is wrong", "Invalid username or password", "incorrect password"]
        return failures.contains { text.contains($0) }
    }
}
