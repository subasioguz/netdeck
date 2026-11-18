import Foundation

/// Turns staged edits into AOS-S configuration commands, as typed after `configure terminal`. Port names and
/// state go in the interface context; VLAN membership is set from the VLAN side in one line each
/// (`vlan 20 untagged 5`, `vlan 30 tagged 5`, `no vlan 30 tagged 5`). A port is untagged in at most one VLAN:
/// making it untagged in another moves it. New memberships come before old ones are removed, so a port is
/// never left without a VLAN on the way.
public enum AOSSPlanner {
    struct KnownVLAN: Equatable {
        var name: String
        var id: Int
    }

    public static func plan(snapshot: SwitchSnapshot, ports: [PortEdit], vlans: [VLANEdit]) -> ChangePlan {
        let state: AOSSState
        if case let .aoss(s) = snapshot.vendor { state = s } else { state = AOSSState() }
        var known = snapshot.config.vlans.compactMap { v in v.vlanID.map { KnownVLAN(name: v.name, id: $0) } }
        var changes: [PlannedChange] = []
        for edit in vlans {
            if let c = planVLAN(edit, vlans: &known, snapshot: snapshot, portEdits: ports) { changes.append(c) }
        }
        for edit in ports {
            if let c = planPort(edit, vlans: known, snapshot: snapshot, state: state) { changes.append(c) }
        }
        // Without `cfg-restore` the switch can't put the old configuration back: read only.
        if !state.canRestoreWithoutReboot, !changes.isEmpty {
            changes[0].warnings.append(t("This switch's firmware (%@) can't restore a configuration without restarting; that needs 16.05 or later. Netdeck reads it but doesn't change it.",
                                         state.softwareRevision ?? "?"))
        }
        return ChangePlan(changes: changes)
    }

    // MARK: Ports

    static func planPort(_ e: PortEdit, vlans: [KnownVLAN], snapshot: SwitchSnapshot, state: AOSSState) -> PlannedChange? {
        let p = e.port
        guard let sp = snapshot.port(named: p) else { return nil }
        let cfg = state.ports[p] ?? AOSSPortConfig()

        var before: [String] = [], named: [String] = [], membership: [String] = [], after: [String] = []
        var parts: [String] = [], warnings: [String] = []
        func id(_ name: String) -> Int? { vlans.first { $0.name == name }?.id }
        func name(_ id: Int) -> String? { vlans.first { $0.id == id }?.name }

        let currentDescription = sp.description ?? ""
        if let d = e.description, d != currentDescription {
            if d.contains("\"") { warnings.append(t("%@: a description can't contain '\"'.", p)) }
            named.append(d.isEmpty ? "no name" : "name \"\(d)\"")
            parts.append(t("description: %@ → %@", currentDescription.isEmpty ? "—" : currentDescription, d.isEmpty ? "—" : d))
        }

        if let on = e.enabled, on != !sp.configDisabled {
            if on {
                after.append("enable")
                parts.append(t("will be enabled"))
            } else {
                before.append("disable")
                parts.append(t("will be disabled"))
            }
        }

        let shownMode = sp.mode ?? cfg.mode
        let shownVLANs = sp.vlans
        let modeChanges = e.mode.map { $0 != shownMode } ?? false
        let vlansChange = e.vlans.map { $0 != shownVLANs } ?? false
        let nativeChanges: Bool = {
            guard let nv = e.nativeVlanID else { return false }
            return nv != cfg.untagged
        }()

        if modeChanges || vlansChange || nativeChanges {
            if let trunk = cfg.trunk {
                warnings.append(t("%@ belongs to %@; its VLANs follow the LAG. Netdeck doesn't change them.", p, trunk))
            } else {
                let target = e.mode ?? shownMode
                if modeChanges { parts.append(t("mode: %@ → %@", ChangePlanner.label(shownMode), ChangePlanner.label(target))) }
                let wanted = e.vlans ?? shownVLANs
                for v in wanted where id(v) == nil { warnings.append(t("%@: there is no VLAN named '%@'.", p, v)) }
                if wanted.isEmpty { warnings.append(t("%@: the port must stay a member of at least one VLAN.", p)) }
                if wanted != shownVLANs {
                    parts.append(t("VLAN: %@ → %@", shownVLANs.isEmpty ? "—" : shownVLANs.joined(separator: ", "),
                                   wanted.isEmpty ? "—" : wanted.joined(separator: ", ")))
                }
                let wantedIDs = wanted.compactMap(id)

                // The untagged VLAN after the change, and the tagged ones.
                let untagged: Int?
                if target == .access {
                    if wanted.count > 1 { warnings.append(t("%@: an access port can carry only one VLAN.", p)) }
                    untagged = wantedIDs.first
                } else if let nv = e.nativeVlanID {
                    untagged = nv
                    if let n = nv, let nm = name(n), !wanted.contains(nm) {
                        warnings.append(t("%@: untagged VLAN %@ (%@) must also be a member.", p, String(n), nm))
                    }
                } else if let u = cfg.untagged, wantedIDs.contains(u) {
                    untagged = u
                } else {
                    untagged = nil
                }
                let tagged = target == .access ? [] : wantedIDs.filter { $0 != untagged }
                if target == .trunk, nativeChanges {
                    parts.append(t("untagged VLAN: %@ → %@", cfg.untagged.map(String.init) ?? "—", untagged.map(String.init) ?? "—"))
                }

                // Untagged first (it moves the port from its old untagged VLAN), then tagged additions, then removals.
                if let u = untagged, u != cfg.untagged {
                    if cfg.tagged.contains(u) { membership.append("no vlan \(u) tagged \(p)") }
                    membership.append("vlan \(u) untagged \(p)")
                }
                for v in tagged where !cfg.tagged.contains(v) { membership.append("vlan \(v) tagged \(p)") }
                for v in cfg.tagged where !tagged.contains(v) && v != untagged { membership.append("no vlan \(v) tagged \(p)") }
                if untagged == nil, let u = cfg.untagged, !wanted.isEmpty { membership.append("no vlan \(u) untagged \(p)") }
                // Names that aren't VLANs stay in the commands as typed; the warning keeps them from being sent.
                for v in wanted where id(v) == nil { membership.append("vlan \(v) \(target == .access ? "untagged" : "tagged") \(p)") }
            }
        }

        var commands: [String] = []
        let first = before + named
        if !first.isEmpty { commands += ["interface \(p)"] + first.map { "   " + $0 } + ["   exit"] }
        commands += membership
        if !after.isEmpty { commands += ["interface \(p)"] + after.map { "   " + $0 } + ["   exit"] }
        guard !commands.isEmpty || !warnings.isEmpty else { return nil }
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
            if let d = desc, !d.isEmpty { warnings.append(t("This switch's VLANs have no description. Leave it empty.")) }
            vlans.append(KnownVLAN(name: name, id: id))
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN %@ '%@' will be added", String(id), name),
                                 commands: ["vlan \(id)", "   name \"\(name)\"", "   exit"], warnings: warnings)

        case let .update(name, id, desc):
            guard let current = vlans.first(where: { $0.name == name }) else { return notFound(name) }
            var parts: [String] = [], warnings: [String] = []
            if let id, id != current.id {
                parts.append(t("number: %@ → %@", String(current.id), String(id)))
                warnings.append(t("The switch can't change a VLAN's number. Add a VLAN with the new number and move the ports to it."))
            }
            if let desc, !desc.isEmpty {
                parts.append(t("description: %@ → %@", "—", desc))
                warnings.append(t("This switch's VLANs have no description. Leave it empty."))
            }
            guard !parts.isEmpty else { return nil }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN '%@': %@", name, parts.joined(separator: " · ")),
                                 commands: [], warnings: warnings)

        case let .rename(from, to):
            guard let current = vlans.first(where: { $0.name == from }) else { return notFound(from) }
            var warnings: [String] = []
            if vlans.contains(where: { $0.name == to && $0.id != current.id }) { warnings.append(t("A VLAN named '%@' already exists.", to)) }
            warnings += nameProblems(to)
            if let i = vlans.firstIndex(where: { $0.name == from }) { vlans[i].name = to }
            return PlannedChange(kind: .vlan, subject: from, summary: t("VLAN '%@' will be renamed to '%@'", from, to),
                                 commands: ["vlan \(current.id)", "   name \"\(to)\"", "   exit"], warnings: warnings)

        case let .delete(name):
            guard let current = vlans.first(where: { $0.name == name }) else { return notFound(name) }
            var warnings: [String] = []
            if current.id == 1 { warnings.append(t("The default VLAN (1) can't be renamed or deleted.")) }
            // Ports whose only VLAN this is would be left without one.
            let users = snapshot.ports.filter { port in
                guard port.mode != .trunk, port.vlans == [name] else { return false }
                if let edit = portEdits.first(where: { $0.port == port.name }), let moved = edit.vlans { return moved.contains(name) }
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

    /// AOS-S VLAN names are quoted: at most 32 characters, no double quote.
    static func nameProblems(_ name: String) -> [String] {
        name.isEmpty || name.count > 32 || name.contains("\"")
            ? [t("'%@': VLAN names on this switch are 1–32 characters and can't contain '\"'.", name)] : []
    }
}
