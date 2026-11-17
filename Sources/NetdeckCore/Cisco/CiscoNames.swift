import Foundation

/// Cisco interface names: `show` outputs print short names ("Gi1/0/3"), the running configuration and
/// configuration commands use full ones ("GigabitEthernet1/0/3").
public enum CiscoNames {
    /// Short prefix → full prefix. Matched exactly, so "Twe" (25G) and "Tw" (2.5G) stay apart.
    static let prefixes: [(short: String, full: String)] = [
        ("Gi", "GigabitEthernet"), ("Te", "TenGigabitEthernet"), ("Twe", "TwentyFiveGigE"),
        ("Fo", "FortyGigabitEthernet"), ("Hu", "HundredGigE"), ("Tw", "TwoGigabitEthernet"),
        ("Fi", "FiveGigabitEthernet"), ("Fa", "FastEthernet"), ("Et", "Ethernet"),
        ("Ap", "AppGigabitEthernet"), ("Po", "Port-channel"), ("Vl", "Vlan"), ("Lo", "Loopback"), ("Tu", "Tunnel"),
    ]

    /// Front-panel Ethernet ports. Port-channels, SVIs, loopbacks, tunnels and the app-hosting port are not.
    static let physicalPrefixes: Set<String> = [
        "GigabitEthernet", "TenGigabitEthernet", "TwentyFiveGigE", "FortyGigabitEthernet", "HundredGigE",
        "TwoGigabitEthernet", "FiveGigabitEthernet", "FastEthernet", "Ethernet",
    ]

    /// "Gi1/0/3" → ("Gi", "1/0/3"), "Port-channel1" → ("Port-channel", "1").
    static func split(_ name: String) -> (prefix: String, rest: String) {
        let prefix = name.prefix { $0.isLetter || $0 == "-" }
        return (String(prefix), String(name.dropFirst(prefix.count)))
    }

    /// "Gi1/0/3" → "GigabitEthernet1/0/3". Full names and unknown prefixes come back unchanged.
    public static func full(_ name: String) -> String {
        let (p, rest) = split(name)
        let lp = p.lowercased()
        if let m = prefixes.first(where: { $0.short.lowercased() == lp }) { return m.full + rest }
        return name
    }

    /// "GigabitEthernet1/0/3" → "Gi1/0/3". Short names and unknown prefixes come back unchanged.
    public static func short(_ name: String) -> String {
        let (p, rest) = split(name)
        let lp = p.lowercased()
        if let m = prefixes.first(where: { $0.full.lowercased() == lp }) { return m.short + rest }
        return name
    }

    /// The full name of `name` among the interfaces the device has (`known`, from the running config).
    /// Falls back to the prefix table, then to a unique known name that starts with the short prefix.
    public static func resolve(_ name: String, known: Set<String>) -> String {
        if known.contains(name) { return name }
        let f = full(name)
        if known.contains(f) { return f }
        let (p, rest) = split(name)
        let lp = p.lowercased()
        guard !lp.isEmpty else { return name }
        let candidates = known.filter {
            let (kp, kr) = split($0)
            return kr == rest && kp.lowercased().hasPrefix(lp)
        }
        return candidates.count == 1 ? candidates.first ?? f : f
    }

    /// A front-panel Ethernet port: physical media prefix, a slot/port path, no sub-interface.
    /// "FastEthernet0" (Catalyst management port) has no path and is excluded.
    public static func isPhysical(_ fullName: String) -> Bool {
        let (p, rest) = split(fullName)
        return physicalPrefixes.contains(p) && rest.contains("/") && !rest.contains(".") && !rest.contains(":")
    }

    /// "GigabitEthernet1/0/3" → [1, 0, 3].
    public static func path(_ name: String) -> [Int] {
        split(name).rest.split(separator: "/").compactMap { Int($0) }
    }

    /// Stack member of a member/module/port name (1 for names without a member number).
    static func member(_ name: String) -> Int {
        let p = path(name)
        return p.count >= 3 ? p[0] : 1
    }

    /// Module (slot) of the port: 0 for built-in ports, 1+ for network modules.
    static func module(_ name: String) -> Int {
        let p = path(name)
        return p.count >= 2 ? p[p.count - 2] : 0
    }

    /// Port on a network module (member/module/port with module ≠ 0), e.g. Te1/1/1 on a C9300 uplink module.
    static func isModulePort(_ name: String) -> Bool {
        let p = path(name)
        return p.count >= 3 && p[p.count - 2] != 0
    }
}
