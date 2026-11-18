import Foundation

/// Turns staged edits into AOS-CX configuration-mode commands, as typed after `configure terminal`
/// (interface or VLAN context first, `exit` after it). VLANs are named in Netdeck and numbered on AOS-CX.
///
/// Two AOS-CX rules shape the trunk commands: setting `vlan trunk native` also allows all VLANs, and a
/// trunk whose last allowed VLAN is removed carries all of them. So the allowed list is set after the
/// native VLAN, new VLANs are allowed before old ones are removed, and an empty trunk is refused.
public enum AOSCXPlanner {
    struct KnownVLAN: Equatable {
        var name: String
        var id: Int
    }

    public static func plan(snapshot: SwitchSnapshot, ports: [PortEdit], vlans: [VLANEdit]) -> ChangePlan {
        let state: AOSCXState
        if case let .aoscx(s) = snapshot.vendor { state = s } else { state = AOSCXState() }
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

    static func planPort(_ e: PortEdit, vlans: [KnownVLAN], snapshot: SwitchSnapshot, state: AOSCXState) -> PlannedChange? {
        let p = e.port
        guard let sp = snapshot.port(named: p) else { return nil }
        let cfg = state.ports[p] ?? AOSCXPortConfig(routed: !sp.switching)

        var before: [String] = [], body: [String] = [], after: [String] = []
        var parts: [String] = [], warnings: [String] = []

        func id(_ name: String) -> Int? { vlans.first { $0.name == name }?.id }
        func names(_ ids: [Int]) -> [String] { ids.compactMap { i in vlans.first { $0.id == i }?.name } }
        func list(_ ids: [Int]) -> String { CiscoParsers.compressVLANList(ids) }

        let currentDescription = sp.description ?? ""
        if let d = e.description, d != currentDescription {
            if d.contains("?") { warnings.append(t("%@: '?' can't be typed in a description on this switch.", p)) }
            body.append(d.isEmpty ? "no description" : "description \(d)")
            parts.append(t("description: %@ → %@", currentDescription.isEmpty ? "—" : currentDescription, d.isEmpty ? "—" : d))
        }

        if let on = e.enabled, on != !sp.configDisabled {
            // Shut first when disabling; bring up last when enabling, once the VLANs are right.
            if on {
                after.append("no shutdown")
                parts.append(t("will be enabled"))
            } else {
                before.append("shutdown")
                parts.append(t("will be disabled"))
            }
        }

        let shownMode = sp.mode ?? cfg.mode
        let shownVLANs = sp.vlans
        let modeChanges = e.mode.map { $0 != shownMode } ?? false
        let vlansChange = e.vlans.map { $0 != shownVLANs } ?? false
        let nativeChanges: Bool = {
            guard let nv = e.nativeVlanID else { return false }
            return (nv ?? 1) != cfg.nativeVLAN
        }()

        if modeChanges || vlansChange || nativeChanges {
            if cfg.routed || !sp.switching {
                warnings.append(t("%@ is a routed port. Netdeck doesn't change VLANs on routed ports.", p))
            } else if let lag = cfg.lag {
                warnings.append(t("%@ belongs to %@; its VLANs follow the LAG. Netdeck doesn't change them.", p, "lag\(lag)"))
            } else {
                let target = e.mode ?? shownMode
                if modeChanges { parts.append(t("mode: %@ → %@", ChangePlanner.label(shownMode), ChangePlanner.label(target))) }
                let wanted = e.vlans ?? shownVLANs
                for v in wanted where id(v) == nil { warnings.append(t("%@: there is no VLAN named '%@'.", p, v)) }
                if wanted != shownVLANs {
                    parts.append(t("VLAN: %@ → %@", shownVLANs.isEmpty ? "—" : shownVLANs.joined(separator: ", "),
                                   wanted.isEmpty ? "—" : wanted.joined(separator: ", ")))
                }

                if target == .access {
                    if wanted.count > 1 { warnings.append(t("%@: an access port can carry only one VLAN.", p)) }
                    if let v = wanted.first {
                        if modeChanges || v != names([cfg.accessVLAN]).first {
                            body.append("vlan access \(id(v).map(String.init) ?? v)")
                        }
                    } else {
                        body.append("no vlan access")
                    }
                } else {
                    let wantedIDs = wanted.compactMap(id)
                    if wanted.isEmpty {
                        warnings.append(t("%@: a trunk port must carry at least one VLAN. With none, AOS-CX carries them all.", p))
                    }
                    // The untagged VLAN: as asked, else as it is (1 on a port that wasn't a trunk).
                    let native: Int = {
                        if let nv = e.nativeVlanID { return nv ?? 1 }
                        return shownMode == .trunk ? cfg.nativeVLAN : 1
                    }()
                    // `vlan trunk native` also allows every VLAN; the list is set again right after it.
                    var allowedNow: [Int]? = shownMode == .trunk ? cfg.allowedVLANs : []
                    if modeChanges || native != cfg.nativeVLAN {
                        body.append("vlan trunk native \(native)")
                        allowedNow = nil
                        if nativeChanges {
                            parts.append(t("untagged VLAN: %@ → %@", String(cfg.nativeVLAN), String(native)))
                        }
                    }
                    if let name = names([native]).first, !wanted.contains(name) {
                        warnings.append(t("%@: untagged VLAN %@ (%@) must also be a member.", p, String(native), name))
                    }
                    let unknown = wanted.filter { id($0) == nil }
                    let everything = Set(vlans.map(\.id))
                    if allowedNow == nil {
                        // All VLANs now; a list replaces "all" (unless every VLAN is wanted anyway).
                        if Set(wantedIDs) != everything || !unknown.isEmpty, !wanted.isEmpty {
                            body.append("vlan trunk allowed \(([list(wantedIDs)] + unknown).filter { !$0.isEmpty }.joined(separator: ","))")
                        }
                    } else if let current = allowedNow {
                        let add = wantedIDs.filter { !current.contains($0) }
                        let remove = current.filter { !wantedIDs.contains($0) }
                        if !add.isEmpty || !unknown.isEmpty {
                            body.append("vlan trunk allowed \(([add.isEmpty ? "" : list(add)] + unknown).filter { !$0.isEmpty }.joined(separator: ","))")
                        }
                        // Removing the last VLAN would open the trunk to all of them (refused above).
                        if !remove.isEmpty, !wanted.isEmpty { body.append("no vlan trunk allowed \(list(remove))") }
                    }
                }
            }
        }

        let lines = before + body + after
        guard !lines.isEmpty || !warnings.isEmpty else { return nil }
        let commands: [String] = lines.isEmpty ? [] : ["interface \(p)"] + lines.map { "    " + $0 } + ["exit"]
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
            if !(1...4094).contains(id) { warnings.append(t("The VLAN number must be between 1 and 4094.")) }
            warnings += nameProblems(name)
            vlans.append(KnownVLAN(name: name, id: id))
            var commands = ["vlan \(id)", "    name \(name)"]
            if let d = desc, !d.isEmpty { commands.append("    description \(d)") }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN %@ '%@' will be added", String(id), name),
                                 commands: commands + ["exit"], warnings: warnings)

        case let .update(name, id, desc):
            guard let current = vlans.first(where: { $0.name == name }) else { return notFound(name) }
            var parts: [String] = [], warnings: [String] = [], commands: [String] = []
            if let id, id != current.id {
                parts.append(t("number: %@ → %@", String(current.id), String(id)))
                warnings.append(t("The switch can't change a VLAN's number. Add a VLAN with the new number and move the ports to it."))
            }
            let currentDescription = snapshot.config.vlans.first { $0.name == name }?.description ?? ""
            if let desc, desc != currentDescription {
                parts.append(t("description: %@ → %@", currentDescription.isEmpty ? "—" : currentDescription, desc.isEmpty ? "—" : desc))
                commands = ["vlan \(current.id)", desc.isEmpty ? "    no description" : "    description \(desc)", "exit"]
            }
            guard !parts.isEmpty else { return nil }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN '%@': %@", name, parts.joined(separator: " · ")),
                                 commands: warnings.isEmpty ? commands : [], warnings: warnings)

        case let .rename(from, to):
            guard let current = vlans.first(where: { $0.name == from }) else { return notFound(from) }
            var warnings: [String] = []
            if vlans.contains(where: { $0.name == to && $0.id != current.id }) { warnings.append(t("A VLAN named '%@' already exists.", to)) }
            warnings += nameProblems(to)
            if let i = vlans.firstIndex(where: { $0.name == from }) { vlans[i].name = to }
            // Ports refer to the number, so nothing else changes.
            return PlannedChange(kind: .vlan, subject: from, summary: t("VLAN '%@' will be renamed to '%@'", from, to),
                                 commands: ["vlan \(current.id)", "    name \(to)", "exit"], warnings: warnings)

        case let .delete(name):
            guard let current = vlans.first(where: { $0.name == name }) else { return notFound(name) }
            var warnings: [String] = []
            if current.id == 1 { warnings.append(t("The default VLAN (1) can't be renamed or deleted.")) }
            // Access ports in the VLAN would lose their network.
            let users = snapshot.ports.filter { port in
                guard port.switching, port.mode != .trunk, port.vlans.contains(name) else { return false }
                if let edit = portEdits.first(where: { $0.port == port.name }), let moved = edit.vlans {
                    return moved.contains(name) && (edit.mode ?? port.mode) != .trunk
                }
                return true
            }.map(\.name)
            if !users.isEmpty {
                warnings.append(t("'%@' is used on %@. Move those ports to another VLAN first.", name, users.joined(separator: ", ")))
            }
            vlans.removeAll { $0.id == current.id }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN '%@' will be deleted", name),
                                 commands: ["no vlan \(current.id)"], warnings: warnings)
        }
    }

    /// AOS-CX VLAN names: 1 to 32 letters, digits, '_' and '-'.
    static func nameProblems(_ name: String) -> [String] {
        let ok = !name.isEmpty && name.count <= 32 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return ok ? [] : [t("'%@': AOS-CX VLAN names are 1–32 characters: letters, digits, '_' and '-'.", name)]
    }
}
