import Foundation

/// A staged edit to one port. `nil` fields are left unchanged.
public struct PortEdit: Equatable, Sendable {
    public var port: String
    public var description: String?
    public var enabled: Bool?
    public var mode: PortMode?
    public var vlans: [String]?
    /// For trunks: VLAN that carries untagged traffic. `.some(nil)` removes it.
    public var nativeVlanID: Int??

    public init(port: String, description: String? = nil, enabled: Bool? = nil, mode: PortMode? = nil,
                vlans: [String]? = nil, nativeVlanID: Int?? = nil) {
        self.port = port
        self.description = description
        self.enabled = enabled
        self.mode = mode
        self.vlans = vlans
        self.nativeVlanID = nativeVlanID
    }
}

public enum VLANEdit: Equatable, Sendable {
    case add(name: String, vlanID: Int, description: String?)
    case update(name: String, vlanID: Int?, description: String?)
    case rename(from: String, to: String)
    case delete(name: String)
}

public struct PlannedChange: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case port, vlan }
    public var id = UUID()
    public var kind: Kind
    public var subject: String          // "ge-0/0/2" or VLAN name
    public var summary: String          // plain language, e.g. "description: R640-PVE-01 → SRV02-IDRAC"
    public var commands: [String]
    public var warnings: [String] = []
}

public struct ChangePlan: Equatable, Sendable {
    public var changes: [PlannedChange]
    public var commands: [String] { changes.flatMap(\.commands) }
    public var warnings: [String] { changes.flatMap(\.warnings) }
    public var isEmpty: Bool { commands.isEmpty }
}

/// Turns staged edits into Junos `set`/`delete` commands against a known config.
public enum ChangePlanner {
    public static func plan(ports: [PortEdit], vlans: [VLANEdit], config: JunosConfig) -> ChangePlan {
        var cfg = config
        var changes: [PlannedChange] = []

        for edit in vlans {
            if let c = planVLAN(edit, config: &cfg) { changes.append(c) }
        }
        for edit in ports {
            if let c = planPort(edit, config: &cfg) { changes.append(c) }
        }
        return ChangePlan(changes: changes)
    }

    // MARK: Ports

    static func planPort(_ e: PortEdit, config cfg: inout JunosConfig) -> PlannedChange? {
        let p = e.port
        let eff = cfg.effective(p)
        let own = cfg.interfaces[p] ?? .init()
        var cmds: [String] = []
        var parts: [String] = []
        var warnings: [String] = []
        let es = "interfaces \(p) unit 0 family ethernet-switching"

        if let d = e.description, d != (eff.description ?? "") {
            if d.isEmpty {
                if own.description != nil { cmds.append("delete interfaces \(p) description") }
            } else {
                cmds.append("set interfaces \(p) description \(SetConfigParser.quote(d))")
            }
            parts.append(t("description: %@ → %@", eff.description ?? "—", d.isEmpty ? "—" : d))
        }

        if let on = e.enabled, on == eff.disabled {
            var removedFromRange = false
            if on {
                if own.disabled { cmds.append("delete interfaces \(p) disable") }
                for r in cfg.ranges(containing: p) where r.config.disabled {
                    cmds += removeFromRange(port: p, range: r)
                    parts.append(t("will be enabled (removed from range %@)", r.name))
                    removedFromRange = true
                    if let i = cfg.ranges.firstIndex(where: { $0.name == r.name }) {
                        cfg.ranges[i] = rangeWithout(p, r)
                    }
                }
                if !removedFromRange { parts.append(t("will be enabled")) }
            } else {
                cmds.append("set interfaces \(p) disable")
                parts.append(t("will be disabled"))
            }
        }

        let currentMode = eff.mode ?? .access
        let targetMode = e.mode ?? currentMode
        if e.mode != nil && targetMode != eff.mode {
            cmds.append("set \(es) interface-mode \(targetMode.rawValue)")
            parts.append(t("mode: %@ → %@", label(eff.mode), label(targetMode)))
            if targetMode == .access, eff.nativeVlanID != nil {
                cmds.append("delete interfaces \(p) native-vlan-id")
            }
        }

        if let vl = e.vlans, vl != eff.vlanMembers {
            if targetMode == .access && vl.count > 1 {
                warnings.append(t("%@: an access port can carry only one VLAN.", p))
            }
            for v in vl where cfg.vlan(named: v) == nil {
                warnings.append(t("%@: there is no VLAN named '%@'.", p, v))
            }
            if !eff.hasEthernetSwitching || eff.mode == nil, e.mode == nil {
                cmds.append("set \(es) interface-mode \(targetMode.rawValue)")
            }
            if !own.vlanMembers.isEmpty { cmds.append("delete \(es) vlan members") }
            for v in vl { cmds.append("set \(es) vlan members \(SetConfigParser.quote(v))") }
            parts.append(t("VLAN: %@ → %@", eff.vlanMembers.isEmpty ? "—" : eff.vlanMembers.joined(separator: ", "), vl.isEmpty ? "—" : vl.joined(separator: ", ")))
        }

        if let nv = e.nativeVlanID, nv != eff.nativeVlanID {
            if let n = nv {
                cmds.append("set interfaces \(p) native-vlan-id \(n)")
                parts.append(t("untagged VLAN: %@ → %@", eff.nativeVlanID.map(String.init) ?? "—", String(n)))
                if let name = cfg.vlans.first(where: { $0.vlanID == n })?.name,
                   !(e.vlans ?? eff.vlanMembers).contains(name) {
                    warnings.append(t("%@: untagged VLAN %@ (%@) must also be a member.", p, String(n), name))
                }
            } else if own.nativeVlanID != nil {
                cmds.append("delete interfaces \(p) native-vlan-id")
                parts.append(t("untagged VLAN will be removed"))
            }
        }

        guard !cmds.isEmpty else { return nil }
        return PlannedChange(kind: .port, subject: p, summary: parts.joined(separator: " · "), commands: cmds, warnings: warnings)
    }

    /// Rewrites a range's member-range statements so that `port` is no longer covered.
    static func removeFromRange(port: String, range r: JunosConfig.InterfaceRange) -> [String] {
        var cmds: [String] = []
        if r.members.contains(port) {
            cmds.append("delete interfaces interface-range \(r.name) member \(port)")
        }
        for mr in r.memberRanges where mr.contains(port) {
            cmds.append("delete interfaces interface-range \(r.name) member-range \(mr.start)")
            for seg in segments(of: mr.ports.filter { $0 != port }) {
                if seg.count == 1 {
                    cmds.append("set interfaces interface-range \(r.name) member \(seg[0])")
                } else {
                    cmds.append("set interfaces interface-range \(r.name) member-range \(seg.first!) to \(seg.last!)")
                }
            }
        }
        return cmds
    }

    static func rangeWithout(_ port: String, _ r: JunosConfig.InterfaceRange) -> JunosConfig.InterfaceRange {
        var copy = r
        copy.members.removeAll { $0 == port }
        var newRanges: [JunosConfig.MemberRange] = []
        for mr in r.memberRanges {
            if mr.contains(port) {
                for seg in segments(of: mr.ports.filter { $0 != port }) {
                    if seg.count == 1 { copy.members.append(seg[0]) } else { newRanges.append(.init(start: seg.first!, end: seg.last!)) }
                }
            } else {
                newRanges.append(mr)
            }
        }
        copy.memberRanges = newRanges
        return copy
    }

    /// Groups consecutive port numbers: [2,3,4,7] → [[2,3,4],[7]] (as names).
    static func segments(of ports: [String]) -> [[String]] {
        var out: [[String]] = []
        for p in ports.sorted(by: { (InterfaceName.portNumber($0) ?? 0) < (InterfaceName.portNumber($1) ?? 0) }) {
            if let lastPort = out.last?.last,
               let a = InterfaceName.portNumber(lastPort), let b = InterfaceName.portNumber(p), b == a + 1 {
                out[out.count - 1].append(p)
            } else {
                out.append([p])
            }
        }
        return out
    }

    // MARK: VLANs

    static func planVLAN(_ e: VLANEdit, config cfg: inout JunosConfig) -> PlannedChange? {
        switch e {
        case let .add(name, id, desc):
            var cmds = ["set vlans \(SetConfigParser.quote(name)) vlan-id \(id)"]
            if let d = desc, !d.isEmpty { cmds.append("set vlans \(SetConfigParser.quote(name)) description \(SetConfigParser.quote(d))") }
            var warnings: [String] = []
            if cfg.vlan(named: name) != nil { warnings.append(t("A VLAN named '%@' already exists.", name)) }
            if let other = cfg.vlans.first(where: { $0.vlanID == id }) { warnings.append(t("VLAN %@ is already used by '%@'.", String(id), other.name)) }
            if !(1...4094).contains(id) { warnings.append(t("The VLAN number must be between 1 and 4094.")) }
            cfg.vlans.append(.init(name: name, vlanID: id, description: desc))
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN %@ '%@' will be added", String(id), name), commands: cmds, warnings: warnings)

        case let .update(name, id, desc):
            guard let current = cfg.vlan(named: name) else {
                return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN not found"), commands: [], warnings: [t("There is no VLAN named '%@'.", name)])
            }
            var cmds: [String] = [], parts: [String] = [], warnings: [String] = []
            if let id, id != current.vlanID {
                cmds.append("set vlans \(SetConfigParser.quote(name)) vlan-id \(id)")
                parts.append(t("number: %@ → %@", current.vlanID.map(String.init) ?? "—", String(id)))
                if let other = cfg.vlans.first(where: { $0.vlanID == id && $0.name != name }) {
                    warnings.append(t("VLAN %@ is already used by '%@'.", String(id), other.name))
                }
            }
            if let desc, desc != (current.description ?? "") {
                cmds.append(desc.isEmpty
                    ? "delete vlans \(SetConfigParser.quote(name)) description"
                    : "set vlans \(SetConfigParser.quote(name)) description \(SetConfigParser.quote(desc))")
                parts.append(t("description: %@ → %@", current.description ?? "—", desc.isEmpty ? "—" : desc))
            }
            guard !cmds.isEmpty else { return nil }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN '%@': %@", name, parts.joined(separator: " · ")), commands: cmds, warnings: warnings)

        case let .rename(from, to):
            var cmds = ["rename vlans \(SetConfigParser.quote(from)) to \(SetConfigParser.quote(to))"]
            // Junos does not rewrite references, so move port memberships too.
            for (name, ic) in cfg.interfaces.sorted(by: { $0.key < $1.key }) where ic.vlanMembers.contains(from) {
                let es = "interfaces \(name) unit 0 family ethernet-switching"
                cmds.append("delete \(es) vlan members \(SetConfigParser.quote(from))")
                cmds.append("set \(es) vlan members \(SetConfigParser.quote(to))")
            }
            for r in cfg.ranges where r.config.vlanMembers.contains(from) {
                let es = "interfaces interface-range \(r.name) unit 0 family ethernet-switching"
                cmds.append("delete \(es) vlan members \(SetConfigParser.quote(from))")
                cmds.append("set \(es) vlan members \(SetConfigParser.quote(to))")
            }
            var warnings: [String] = []
            if cfg.vlan(named: to) != nil { warnings.append(t("A VLAN named '%@' already exists.", to)) }
            if let i = cfg.vlans.firstIndex(where: { $0.name == from }) { cfg.vlans[i].name = to }
            return PlannedChange(kind: .vlan, subject: from, summary: t("VLAN '%@' will be renamed to '%@'", from, to), commands: cmds, warnings: warnings)

        case let .delete(name):
            var warnings: [String] = []
            let users = cfg.interfaces.filter { $0.value.vlanMembers.contains(name) }.map(\.key).sorted()
            if !users.isEmpty { warnings.append(t("'%@' is used on %@. Move those ports to another VLAN first.", name, users.joined(separator: ", "))) }
            cfg.vlans.removeAll { $0.name == name }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN '%@' will be deleted", name), commands: ["delete vlans \(SetConfigParser.quote(name))"], warnings: warnings)
        }
    }

    static func label(_ m: PortMode?) -> String {
        switch m {
        case .access: return t("single network (access)")
        case .trunk: return t("multiple networks (trunk)")
        case nil: return "—"
        }
    }
}
