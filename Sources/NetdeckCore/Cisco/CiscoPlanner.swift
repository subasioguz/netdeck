import Foundation

/// Switchport settings of one port as configured, with VLAN numbers (IOS commands use numbers;
/// Netdeck shows names).
public struct CiscoPortConfig: Equatable, Sendable {
    /// false for a routed port (`no switchport`) and for every port of a router.
    public var switchport: Bool
    /// `switchport mode`; nil when not set or dynamic (DTP decides).
    public var mode: PortMode?
    /// `switchport access vlan`; 1 when not set.
    public var accessVLAN: Int
    /// `switchport trunk allowed vlan`; nil = all VLANs.
    public var allowedVLANs: [Int]?
    public var nativeVLAN: Int?
    public var hasEncapsulation: Bool
    /// Member of `Port-channel<N>`.
    public var channelGroup: Int?

    public init(switchport: Bool = true, mode: PortMode? = nil, accessVLAN: Int = 1, allowedVLANs: [Int]? = nil,
                nativeVLAN: Int? = nil, hasEncapsulation: Bool = false, channelGroup: Int? = nil) {
        self.switchport = switchport
        self.mode = mode
        self.accessVLAN = accessVLAN
        self.allowedVLANs = allowedVLANs
        self.nativeVLAN = nativeVLAN
        self.hasEncapsulation = hasEncapsulation
        self.channelGroup = channelGroup
    }
}

/// Platform data the Cisco planner and driver need beyond `JunosConfig`.
public struct CiscoState: Equatable, Sendable {
    /// Front-panel ports by full interface name ("GigabitEthernet1/0/3").
    public var ports: [String: CiscoPortConfig]
    /// `show archive` showed a configured archive path (the revert timer needs one).
    public var archiveConfigured: Bool
    /// The switch uses `switchport trunk encapsulation` (it also speaks ISL): a new trunk needs dot1q set first.
    public var needsTrunkEncapsulation: Bool

    public init() {
        ports = [:]
        archiveConfigured = false
        needsTrunkEncapsulation = false
    }

    public init(ports: [String: CiscoPortConfig], archiveConfigured: Bool, needsTrunkEncapsulation: Bool) {
        self.ports = ports
        self.archiveConfigured = archiveConfigured
        self.needsTrunkEncapsulation = needsTrunkEncapsulation
    }
}

/// Turns staged edits into IOS configuration-mode commands, exactly as typed after `configure terminal`
/// (interface context first, `exit` after it). VLANs are named in Netdeck and numbered on IOS.
public enum CiscoPlanner {
    struct KnownVLAN: Equatable {
        var name: String
        var id: Int
    }

    public static func plan(snapshot: SwitchSnapshot, ports: [PortEdit], vlans: [VLANEdit]) -> ChangePlan {
        let state: CiscoState
        if case let .cisco(s) = snapshot.vendor { state = s } else { state = CiscoState() }
        var known = snapshot.config.vlans.compactMap { v in v.vlanID.map { KnownVLAN(name: v.name, id: $0) } }
        var changes: [PlannedChange] = []
        for edit in vlans {
            if let c = planVLAN(edit, vlans: &known, snapshot: snapshot, portEdits: ports) { changes.append(c) }
        }
        for edit in ports {
            if let c = planPort(edit, vlans: known, snapshot: snapshot, state: state) { changes.append(c) }
        }
        return ChangePlan(changes: changes)
    }

    // MARK: Ports

    static func planPort(_ e: PortEdit, vlans: [KnownVLAN], snapshot: SwitchSnapshot, state: CiscoState) -> PlannedChange? {
        let p = e.port
        let sp = snapshot.port(named: p)
        let ic = snapshot.config.interfaces[p]
        guard sp != nil || ic != nil else { return nil }
        let cfg = state.ports[p] ?? CiscoPortConfig(switchport: sp?.switching ?? false)

        var before: [String] = [], body: [String] = [], after: [String] = []
        var parts: [String] = [], warnings: [String] = []

        func id(_ name: String) -> Int? { vlans.first { $0.name == name }?.id }
        func names(_ ids: [Int]) -> [String] { ids.compactMap { i in vlans.first { $0.id == i }?.name } }
        // An unknown name stays in the command as typed; the warning keeps it from being sent.
        func token(_ name: String) -> String { id(name).map(String.init) ?? name }

        let currentDescription = sp?.description ?? ic?.description ?? ""
        if let d = e.description, d != currentDescription {
            if d.contains("?") { warnings.append(t("%@: IOS doesn't accept '?' in a description.", p)) }
            body.append(d.isEmpty ? " no description" : " description \(d)")
            parts.append(t("description: %@ → %@", currentDescription.isEmpty ? "—" : currentDescription, d.isEmpty ? "—" : d))
        }

        let enabled = !(sp?.configDisabled ?? ic?.disabled ?? false)
        if let on = e.enabled, on != enabled {
            // Shut first when disabling; bring up last when enabling, once the VLANs are right.
            if on {
                after.append(" no shutdown")
                parts.append(t("will be enabled"))
            } else {
                before.append(" shutdown")
                parts.append(t("will be disabled"))
            }
        }

        let shownMode = sp?.mode
        let shownVLANs = sp?.vlans ?? ic?.vlanMembers ?? []
        let modeChanges = e.mode.map { $0 != (shownMode ?? .access) } ?? false
        let vlansChange = e.vlans.map { $0 != shownVLANs } ?? false
        let nativeChanges = e.nativeVlanID.map { $0 != cfg.nativeVLAN } ?? false

        if modeChanges || vlansChange || nativeChanges {
            if !cfg.switchport || !snapshot.hasSwitching {
                warnings.append(t("%@ is a routed port (no switchport). Netdeck doesn't change VLANs on routed ports.", p))
            } else if let group = cfg.channelGroup {
                warnings.append(t("%@ belongs to Port-channel%@; its VLANs follow the port-channel. Netdeck doesn't change them.", p, String(group)))
            } else {
                let currentMode = shownMode ?? cfg.mode ?? .access
                let target = e.mode ?? currentMode
                // What the port carries in the target mode before any VLAN command.
                let configuredMembers: [String] = target == .access
                    ? names([cfg.accessVLAN])
                    : (cfg.allowedVLANs.map(names) ?? vlans.sorted { $0.id < $1.id }.map(\.name))
                let wanted = e.vlans
                let sendVLANs = wanted.map { $0 != configuredMembers } ?? false

                // A port without a configured mode negotiates (DTP); pin the mode when its VLANs change.
                if modeChanges || (sendVLANs && cfg.mode == nil) {
                    if target == .trunk && state.needsTrunkEncapsulation && !cfg.hasEncapsulation {
                        body.append(" switchport trunk encapsulation dot1q")
                    }
                    body.append(" switchport mode \(target.rawValue)")
                    if modeChanges { parts.append(t("mode: %@ → %@", ChangePlanner.label(shownMode), ChangePlanner.label(target))) }
                }

                if let vl = wanted, sendVLANs {
                    for v in vl where id(v) == nil { warnings.append(t("%@: there is no VLAN named '%@'.", p, v)) }
                    if target == .access {
                        if vl.count > 1 { warnings.append(t("%@: an access port can carry only one VLAN.", p)) }
                        if let v = vl.first {
                            body.append(" switchport access vlan \(token(v))")
                        } else {
                            body.append(" no switchport access vlan")
                        }
                    } else {
                        let ids = vl.compactMap(id)
                        let unknown = vl.filter { id($0) == nil }
                        let list = ([ids.isEmpty ? "" : CiscoParsers.compressVLANList(ids)] + unknown).filter { !$0.isEmpty }
                        body.append(" switchport trunk allowed vlan \(list.isEmpty ? "none" : list.joined(separator: ","))")
                    }
                    if vl != shownVLANs {
                        parts.append(t("VLAN: %@ → %@", shownVLANs.isEmpty ? "—" : shownVLANs.joined(separator: ", "),
                                       vl.isEmpty ? "—" : vl.joined(separator: ", ")))
                    }
                }

                if let nv = e.nativeVlanID, nv != cfg.nativeVLAN {
                    if let n = nv {
                        body.append(" switchport trunk native vlan \(n)")
                        parts.append(t("untagged VLAN: %@ → %@", cfg.nativeVLAN.map(String.init) ?? "—", String(n)))
                        if target == .trunk, let name = vlans.first(where: { $0.id == n })?.name,
                           !(wanted ?? configuredMembers).contains(name) {
                            warnings.append(t("%@: untagged VLAN %@ (%@) must also be a member.", p, String(n), name))
                        }
                    } else {
                        body.append(" no switchport trunk native vlan")
                        parts.append(t("untagged VLAN will be removed"))
                    }
                }
            }
        }

        let lines = before + body + after
        guard !lines.isEmpty || !warnings.isEmpty else { return nil }
        let commands: [String] = lines.isEmpty ? [] : ["interface \(p)"] + lines + ["exit"]
        return PlannedChange(kind: .port, subject: p, summary: parts.joined(separator: " · "), commands: commands, warnings: warnings)
    }

    // MARK: VLANs

    static func planVLAN(_ e: VLANEdit, vlans: inout [KnownVLAN], snapshot: SwitchSnapshot, portEdits: [PortEdit]) -> PlannedChange? {
        func notFound(_ name: String) -> PlannedChange {
            PlannedChange(kind: .vlan, subject: name, summary: t("VLAN not found"), commands: [], warnings: [t("There is no VLAN named '%@'.", name)])
        }

        switch e {
        case let .add(name, id, desc):
            var warnings: [String] = []
            if vlans.contains(where: { $0.name == name }) { warnings.append(t("A VLAN named '%@' already exists.", name)) }
            if let other = vlans.first(where: { $0.id == id }) { warnings.append(t("VLAN %@ is already used by '%@'.", String(id), other.name)) }
            if !(1...4094).contains(id) {
                warnings.append(t("The VLAN number must be between 1 and 4094."))
            } else if (1002...1005).contains(id) {
                warnings.append(t("VLANs 1002–1005 are reserved on Cisco switches."))
            }
            warnings += nameProblems(name)
            if let d = desc, !d.isEmpty { warnings.append(t("IOS VLANs have no description. Leave it empty.")) }
            vlans.append(KnownVLAN(name: name, id: id))
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN %@ '%@' will be added", String(id), name),
                                 commands: ["vlan \(id)", " name \(name)", "exit"], warnings: warnings)

        case let .update(name, id, desc):
            guard let current = vlans.first(where: { $0.name == name }) else { return notFound(name) }
            var parts: [String] = [], warnings: [String] = []
            if let id, id != current.id {
                parts.append(t("number: %@ → %@", String(current.id), String(id)))
                warnings.append(t("IOS can't change a VLAN's number. Add a VLAN with the new number and move the ports to it."))
            }
            if let desc, !desc.isEmpty {
                parts.append(t("description: %@ → %@", "—", desc))
                warnings.append(t("IOS VLANs have no description. Leave it empty."))
            }
            guard !parts.isEmpty else { return nil }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN '%@': %@", name, parts.joined(separator: " · ")),
                                 commands: [], warnings: warnings)

        case let .rename(from, to):
            guard let current = vlans.first(where: { $0.name == from }) else { return notFound(from) }
            var warnings: [String] = []
            if vlans.contains(where: { $0.name == to && $0.id != current.id }) { warnings.append(t("A VLAN named '%@' already exists.", to)) }
            if current.id == 1 { warnings.append(t("The default VLAN (1) can't be renamed or deleted.")) }
            warnings += nameProblems(to)
            if let i = vlans.firstIndex(where: { $0.name == from }) { vlans[i].name = to }
            // Ports refer to the number, so nothing else changes.
            return PlannedChange(kind: .vlan, subject: from, summary: t("VLAN '%@' will be renamed to '%@'", from, to),
                                 commands: ["vlan \(current.id)", " name \(to)", "exit"], warnings: warnings)

        case let .delete(name):
            guard let current = vlans.first(where: { $0.name == name }) else { return notFound(name) }
            var warnings: [String] = []
            if current.id == 1 { warnings.append(t("The default VLAN (1) can't be renamed or deleted.")) }
            // Access ports in the VLAN would lose their network. Trunks keep the number in their list harmlessly.
            let users = snapshot.ports.filter { port in
                guard port.switching, port.mode != .trunk, port.vlans.contains(name) else { return false }
                if let edit = portEdits.first(where: { $0.port == port.name }), let moved = edit.vlans {
                    return moved.contains(name) && (edit.mode ?? port.mode) != .trunk
                }
                return true
            }.map { CiscoNames.short($0.name) }
            if !users.isEmpty {
                warnings.append(t("'%@' is used on %@. Move those ports to another VLAN first.", name, users.joined(separator: ", ")))
            }
            vlans.removeAll { $0.id == current.id }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN '%@' will be deleted", name),
                                 commands: ["no vlan \(current.id)"], warnings: warnings)
        }
    }

    /// IOS takes the VLAN name as one word (`name WORD`, at most 32 characters); `?` would open the CLI help.
    static func nameProblems(_ name: String) -> [String] {
        if name.isEmpty || name.count > 32 || name.contains(where: { $0.isWhitespace || $0 == "?" }) {
            return [t("'%@': IOS VLAN names can't contain spaces or '?' and are at most 32 characters.", name)]
        }
        return []
    }
}
