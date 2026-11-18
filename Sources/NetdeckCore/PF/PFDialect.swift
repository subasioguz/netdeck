import Foundation

/// pfSense and OPNsense over SSH or the console. Both descend from m0n0wall, run FreeBSD and keep their whole
/// configuration in `/conf/config.xml`; Netdeck reads them the same way.
///
/// An administrator lands in the console menu ("Enter an option:"), where some numbers reset the unit to
/// factory defaults, reboot or halt it. Netdeck never types a number it hasn't read on the screen: it looks
/// for the "N) Shell" entry and sends that N, or stops. From whatever shell it gets (pfSense's
/// `[2.7.2-RELEASE][admin@fw.home.arpa]/root:`, csh's `root@OPNsense:~ #`, a plain `$`), it starts
/// `/bin/sh` with a clean environment and its own prompt, so every command and its output look the same on
/// both systems. Logging out walks back: `exit` twice, then "0) Logout" in the menu.
public struct PFDialect: CLIDialect {
    public init() {}

    /// Netdeck's own shell prompt.
    static let prompt = "NETDECK> "
    static let menuPrompt = "Enter an option:"
    /// The shell Netdeck runs: no inherited `ENV` file or colours, a known prompt.
    static let shellCommand = "env -i PS1='" + prompt + "' TERM=dumb HOME=/root "
        + "PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin /bin/sh"

    static let pfSensePrompt = #"^\[[^\]]+\]\[[^\]@\s]+@[^\]\s]+\][^\s]*:$"#
    static let cshPrompt = #"^[\w.\-]+@[\w.\-]+:[^\s]* ?[#%>$]$"#

    public func prompt(_ line: String) -> CLIPrompt? {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return nil }
        if l == Self.prompt.trimmingCharacters(in: .whitespaces) { return .operational }
        if l.hasSuffix("login:") { return .login }
        if l.hasSuffix("Password:") || l.hasSuffix("password:") || l.hasPrefix("Password for ") { return .password }
        if l.hasSuffix(Self.menuPrompt) { return .question }
        if l.range(of: #"[\(\[](y/n|Y/n|y/N|yes/no)[\)\]]\s*:?\s*$"#, options: .regularExpression) != nil { return .question }
        if l.range(of: Self.pfSensePrompt, options: .regularExpression) != nil
            || l.range(of: Self.cshPrompt, options: .regularExpression) != nil
            || ["$", "#", "%"].contains(l) {
            return .shell
        }
        return nil
    }

    /// The menu entry number of `title` on the screen ("8" for " 8) Shell"), when exactly one is shown. The
    /// menus print two columns, so the entry may be anywhere on its line; "12) PHP shell + pfSense tools"
    /// doesn't count (case and the full title must match).
    static func menuOption(_ title: String, on screen: String) -> String? {
        let pattern = #"(?:^|\s)(\d{1,2})\) "# + NSRegularExpression.escapedPattern(for: title) + #"(?=\s{2,}|\s*$)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let ns = screen as NSString
        let found = Set(re.matches(in: screen, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
        guard found.count == 1, let n = found.first, let v = Int(n), (0...20).contains(v) else { return nil }
        return n
    }

    public var setupCommands: [String] { [] }

    public func advance(from prompt: CLIPrompt) -> String? {
        prompt == .shell ? Self.shellCommand + "\r" : nil
    }

    /// The menu: only the number shown next to "Shell". Any other question during login: stop.
    public func advance(from prompt: CLIPrompt, screen: String) -> String? {
        guard prompt == .question else { return advance(from: prompt) }
        let last = CLISession.lastLine(of: screen).trimmingCharacters(in: .whitespaces)
        guard last.hasSuffix(Self.menuPrompt), let n = Self.menuOption("Shell", on: screen) else { return nil }
        return n + "\r"
    }

    public func logout(from prompt: CLIPrompt?) -> String? {
        switch prompt {
        case .operational, .shell, .user, .configuration: return "exit\r"
        case .pager: return "q"
        // Never answer a question with yes on the way out.
        case .question: return "n\r"
        case .password, nil: return "\u{3}"
        case .login: return nil
        }
    }

    /// In the menu, "0) Logout" (pfSense: "Logout (SSH only)"); both menus have always put it at 0.
    public func logout(from prompt: CLIPrompt?, line: String) -> String? {
        if prompt == .question, line.trimmingCharacters(in: .whitespaces).hasSuffix(Self.menuPrompt) { return "0\r" }
        return logout(from: prompt)
    }

    public func errors(in output: String) -> [String] {
        output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            $0.hasSuffix("Permission denied") || $0.hasSuffix("not found") || $0.hasSuffix("No such file or directory")
        }
    }
}
