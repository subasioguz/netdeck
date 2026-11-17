import Foundation

/// Turns the switch's hierarchical diff (`show | compare`, `show system rollback compare N M`)
/// into flat `set` lines, so both kinds of diff can be summarized the same way.
public enum ConfigCompare {
    public static func setDiff(fromCompare text: String) -> SetDiff.Result {
        var removed: [String] = [], added: [String] = []
        var context: [String] = []
        struct Frame { var name: String; var sign: Character?; var emitted = false }
        var stack: [Frame] = []

        func emit(_ sign: Character, _ path: [String]) {
            let line = "set " + path.joined(separator: " ")
            if sign == "+" { added.append(line) } else { removed.append(line) }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[edit") {
                let inner = trimmed.dropFirst("[edit".count).dropLast(trimmed.hasSuffix("]") ? 1 : 0)
                context = SetConfigParser.tokenize(String(inner))
                stack = []
                continue
            }
            guard let first = line.first else { continue }
            let sign: Character? = (first == "+" || first == "-") ? first : nil
            var body = (sign == nil ? trimmed : String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            if body.isEmpty || body.hasPrefix("#") || body.hasPrefix("/*") || body == "..." { continue }
            for marker in ["inactive: ", "protect: "] where body.hasPrefix(marker) { body.removeFirst(marker.count) }
            if body.hasSuffix("{ ... }") { continue }   // unchanged, collapsed by the switch

            if body.hasSuffix("{") {
                let name = body.dropLast().trimmingCharacters(in: .whitespaces)
                stack.append(Frame(name: name, sign: sign ?? stack.last?.sign))
                continue
            }
            if body == "}" {
                guard let frame = stack.popLast() else { continue }
                if let s = frame.sign, !frame.emitted {
                    emit(s, context + stack.map(\.name) + [frame.name])
                }
                continue
            }
            guard body.hasSuffix(";") else { continue }
            let statement = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
            guard let effective = sign ?? stack.last?.sign else { continue }   // unchanged context line
            let base = context + stack.map(\.name)
            // Leaf lists print as "members [ a b ];" → one set line per value.
            if let open = statement.range(of: " [ "), statement.hasSuffix(" ]") {
                let key = String(statement[..<open.lowerBound])
                let values = statement[open.upperBound...].dropLast(2).split(separator: " ").map(String.init)
                for v in values { emit(effective, base + [key, v]) }
            } else {
                emit(effective, base + [statement])
            }
            for i in stack.indices { stack[i].emitted = true }
        }
        return SetDiff.Result(removed: removed, added: added)
    }
}

/// What a diff means in plain words (History & backups, rollback review). The UI turns each
/// item into a sentence; anything not recognized becomes `.other` with the raw statement.
public struct DiffSummaryItem: Equatable, Sendable {
    public enum Sign: Equatable, Sendable { case changed, added, removed }

    public enum Kind: Equatable, Sendable {
        /// Taken out of a disabled interface-range, so the port is enabled now.
        case leftDisabledRange(port: String, range: String)
        /// Put into a disabled interface-range, so the port is disabled now.
        case joinedDisabledRange(port: String, range: String)
        case description(port: String, value: String)
        case descriptionRemoved(port: String)
        case accessVLAN(port: String, vlan: String)
        case joinedVLAN(port: String, vlan: String)
        case leftVLAN(port: String, vlan: String)
        case mode(port: String, trunk: Bool)
        case edge(port: String)
        case notEdge(port: String)
        case disabled(port: String)
        case enabled(port: String)
        case vlanAdded(name: String, id: Int?)
        case vlanRemoved(name: String)
        case other(subject: String, statement: String)
    }

    public var sign: Sign
    public var kind: Kind
}

public enum DiffSummary {
    /// `current` is the configuration that tells which interface-ranges are disabled.
    public static func items(_ diff: SetDiff.Result, current: JunosConfig?) -> [DiffSummaryItem] {
        let removed = diff.removed.map(SetConfigParser.tokenize)
        let added = diff.added.map(SetConfigParser.tokenize)
        var usedRemoved = Set<Int>(), usedAdded = Set<Int>()
        var out: [DiffSummaryItem] = []

        func isPort(_ s: String) -> Bool { InterfaceName.portNumber(s) != nil && s.contains("/") }

        // Interface-range membership (member-range a to b / member x).
        var rangeNames: [String] = []
        func rangePorts(_ lines: [[String]], used: inout Set<Int>) -> [String: Set<String>] {
            var out: [String: Set<String>] = [:]
            for (i, t) in lines.enumerated() where t.count >= 6 && t[1] == "interfaces" && t[2] == "interface-range" {
                let name = t[3]
                if t[4] == "member-range", t.count >= 8 {
                    out[name, default: []].formUnion(JunosConfig.MemberRange(start: t[5], end: t[7]).ports)
                } else if t[4] == "member" {
                    out[name, default: []].insert(t[5])
                } else { continue }
                used.insert(i)
                if !rangeNames.contains(name) { rangeNames.append(name) }
            }
            return out
        }
        let oldRanges = rangePorts(removed, used: &usedRemoved)
        let newRanges = rangePorts(added, used: &usedAdded)
        let disabledRanges = Set(current?.ranges.filter { $0.config.disabled }.map(\.name) ?? [])
            .union(added.filter { $0.count == 5 && $0[1] == "interfaces" && $0[2] == "interface-range" && $0[4] == "disable" }.map { $0[3] })
        for name in rangeNames {
            let before = oldRanges[name] ?? [], after = newRanges[name] ?? []
            let left = before.subtracting(after).sorted(by: sortPorts), joined = after.subtracting(before).sorted(by: sortPorts)
            if disabledRanges.contains(name) {
                out += left.map { DiffSummaryItem(sign: .changed, kind: .leftDisabledRange(port: $0, range: name)) }
                out += joined.map { DiffSummaryItem(sign: .changed, kind: .joinedDisabledRange(port: $0, range: name)) }
            } else {
                out += left.map { DiffSummaryItem(sign: .removed, kind: .other(subject: $0, statement: "interface-range \(name)")) }
                out += joined.map { DiffSummaryItem(sign: .added, kind: .other(subject: $0, statement: "interface-range \(name)")) }
            }
        }

        // Per-port statements.
        func find(_ lines: [[String]], _ used: Set<Int>, _ match: ([String]) -> Bool) -> [Int] {
            lines.indices.filter { !used.contains($0) && match(lines[$0]) }
        }
        func portOf(_ t: [String]) -> String? { t.count > 3 && t[1] == "interfaces" && isPort(t[2]) ? t[2] : nil }
        let ports = (added + removed).compactMap(portOf).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        for port in ports {
            // Description
            let dAdd = find(added, usedAdded) { portOf($0) == port && $0.count >= 5 && $0[3] == "description" }
            let dRem = find(removed, usedRemoved) { portOf($0) == port && $0.count >= 5 && $0[3] == "description" }
            if let i = dAdd.first {
                out.append(.init(sign: dRem.isEmpty ? .added : .changed, kind: .description(port: port, value: added[i][4])))
            } else if !dRem.isEmpty {
                out.append(.init(sign: .removed, kind: .descriptionRemoved(port: port)))
            }
            usedAdded.formUnion(dAdd); usedRemoved.formUnion(dRem)

            // Disable / enable on the port itself
            let disAdd = find(added, usedAdded) { portOf($0) == port && $0.count == 4 && $0[3] == "disable" }
            let disRem = find(removed, usedRemoved) { portOf($0) == port && $0.count == 4 && $0[3] == "disable" }
            if !disAdd.isEmpty { out.append(.init(sign: .changed, kind: .disabled(port: port))) }
            if !disRem.isEmpty { out.append(.init(sign: .changed, kind: .enabled(port: port))) }
            usedAdded.formUnion(disAdd); usedRemoved.formUnion(disRem)

            // Mode and VLAN membership
            func isSwitching(_ t: [String]) -> Bool {
                portOf(t) == port && t.count >= 8 && t[3] == "unit" && t[5] == "family" && t[6] == "ethernet-switching"
            }
            let modeAdd = find(added, usedAdded) { isSwitching($0) && $0[7] == "interface-mode" && $0.count >= 9 }
            let modeRem = find(removed, usedRemoved) { isSwitching($0) && $0[7] == "interface-mode" }
            let memAdd = find(added, usedAdded) { isSwitching($0) && $0.count >= 10 && $0[7] == "vlan" && $0[8] == "members" }
            let memRem = find(removed, usedRemoved) { isSwitching($0) && $0.count >= 10 && $0[7] == "vlan" && $0[8] == "members" }
            let newMode = modeAdd.first.map { added[$0][8] } ?? current?.interfaces[port]?.mode.map { $0 == .trunk ? "trunk" : "access" }
            let newMembers = memAdd.map { added[$0][9] }, oldMembers = memRem.map { removed[$0][9] }
            if newMode == "access", newMembers.count == 1 {
                out.append(.init(sign: oldMembers.isEmpty ? .added : .changed, kind: .accessVLAN(port: port, vlan: newMembers[0])))
                usedAdded.formUnion(modeAdd)
                usedRemoved.formUnion(modeRem)
            } else {
                if let i = modeAdd.first {
                    out.append(.init(sign: modeRem.isEmpty ? .added : .changed, kind: .mode(port: port, trunk: added[i][8] == "trunk")))
                    usedAdded.formUnion(modeAdd); usedRemoved.formUnion(modeRem)
                }
                out += newMembers.filter { !oldMembers.contains($0) }.map { .init(sign: .added, kind: .joinedVLAN(port: port, vlan: $0)) }
                // The mode going away together with the VLAN membership is part of leaving the VLAN.
                if modeAdd.isEmpty, !memRem.isEmpty, newMembers.isEmpty { usedRemoved.formUnion(modeRem) }
            }
            out += oldMembers.filter { !newMembers.contains($0) }.map { .init(sign: .removed, kind: .leftVLAN(port: port, vlan: $0)) }
            usedAdded.formUnion(memAdd); usedRemoved.formUnion(memRem)
            // A bare "family ethernet-switching" that only came along with the above.
            let famAdd = find(added, usedAdded) { isSwitching($0) && $0.count == 7 }
            usedAdded.formUnion(famAdd)
            usedRemoved.formUnion(find(removed, usedRemoved) { isSwitching($0) && $0.count == 7 })
        }

        // RSTP edge
        let edgeAdd = find(added, usedAdded) { $0.count == 6 && $0[1] == "protocols" && $0[2] == "rstp" && $0[3] == "interface" && $0[5] == "edge" }
        let edgeRem = find(removed, usedRemoved) { $0.count == 6 && $0[1] == "protocols" && $0[2] == "rstp" && $0[3] == "interface" && $0[5] == "edge" }
        out += edgeAdd.map { .init(sign: .added, kind: .edge(port: added[$0][4])) }
        out += edgeRem.map { .init(sign: .removed, kind: .notEdge(port: removed[$0][4])) }
        usedAdded.formUnion(edgeAdd); usedRemoved.formUnion(edgeRem)
        // "interface X" containers that only held the edge flag.
        for (i, t) in added.enumerated() where !usedAdded.contains(i) && t.count == 5 && t[1] == "protocols" && t[2] == "rstp" && t[3] == "interface"
            && edgeAdd.contains(where: { added[$0][4] == t[4] }) { usedAdded.insert(i) }

        // VLANs
        let vlanNamesAdded = Set(added.filter { $0.count >= 3 && $0[1] == "vlans" }.map { $0[2] })
        let vlanNamesRemoved = Set(removed.filter { $0.count >= 3 && $0[1] == "vlans" }.map { $0[2] })
        for name in vlanNamesAdded.subtracting(vlanNamesRemoved).sorted() {
            let id = added.first { $0.count >= 5 && $0[1] == "vlans" && $0[2] == name && $0[3] == "vlan-id" }.flatMap { Int($0[4]) }
            guard id != nil else { continue }
            out.append(.init(sign: .added, kind: .vlanAdded(name: name, id: id)))
            usedAdded.formUnion(added.indices.filter { added[$0].count >= 3 && added[$0][1] == "vlans" && added[$0][2] == name })
        }
        for name in vlanNamesRemoved.subtracting(vlanNamesAdded).sorted() {
            guard removed.contains(where: { $0.count >= 5 && $0[1] == "vlans" && $0[2] == name && $0[3] == "vlan-id" }) else { continue }
            out.append(.init(sign: .removed, kind: .vlanRemoved(name: name)))
            usedRemoved.formUnion(removed.indices.filter { removed[$0].count >= 3 && removed[$0][1] == "vlans" && removed[$0][2] == name })
        }

        // Everything else, statement by statement. A path present on both sides is a change.
        func split(_ t: [String]) -> (String, String) {
            let body = Array(t.dropFirst())
            let n = body.count >= 3 && (body[0] == "interfaces" || body[0] == "vlans" || body[0] == "protocols") ? 2 : 1
            return (body.prefix(n).joined(separator: " "), body.dropFirst(n).joined(separator: " "))
        }
        let leftoverRemoved = removed.indices.filter { !usedRemoved.contains($0) }
        let leftoverAdded = added.indices.filter { !usedAdded.contains($0) }
        let removedKeys = Set(leftoverRemoved.map { removed[$0].dropLast().joined(separator: " ") })
        for i in leftoverAdded {
            let (subject, statement) = split(added[i])
            let changed = removedKeys.contains(added[i].dropLast().joined(separator: " "))
            out.append(.init(sign: changed ? .changed : .added, kind: .other(subject: subject, statement: statement)))
        }
        let addedKeys = Set(leftoverAdded.map { added[$0].dropLast().joined(separator: " ") })
        for i in leftoverRemoved where !addedKeys.contains(removed[i].dropLast().joined(separator: " ")) {
            let (subject, statement) = split(removed[i])
            out.append(.init(sign: .removed, kind: .other(subject: subject, statement: statement)))
        }
        return out
    }

    /// The same diff seen from the other side (what going back to the older version does).
    public static func reversed(_ diff: SetDiff.Result) -> SetDiff.Result {
        SetDiff.Result(removed: diff.added, added: diff.removed)
    }

    static func sortPorts(_ a: String, _ b: String) -> Bool {
        InterfaceName.sortKey(a).lexicographicallyPrecedes(InterfaceName.sortKey(b))
    }
}
