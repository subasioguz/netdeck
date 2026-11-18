import NetdeckCore
import SwiftUI

// MARK: - Model: VLANs as they will look after the staged edits

/// The VLAN list with staged `VLANEdit`s folded in. Every change made on this screen is staged by
/// rewriting the edits that belong to one room (`restage`), so the review sheet, the staged bar
/// and the "Was … · Undo" lines all read the same list.
@MainActor
struct VLANRooms {
    struct Row: Identifiable, Equatable {
        var original: String?            // name on the switch; nil = added in Netdeck, not sent yet
        var name: String
        var vlanID: Int?
        var description: String?
        var originalDescription: String?
        var deleted = false
        var builtIn = false              // "default" (VLAN 1): exists without being configured

        var id: String { original ?? "+\(vlanID ?? 0)" }
        var isNew: Bool { original == nil }
        var renamed: Bool { original.map { $0 != name } ?? false }
        var descriptionChanged: Bool { !isNew && (description ?? "") != (originalDescription ?? "") }
        var isStaged: Bool { isNew || deleted || renamed || descriptionChanged }
        var colorKey: String { original ?? name }
    }

    var rows: [Row] = []
    /// For each staged VLAN edit (same index as `session.vlanEdits`), the row it belongs to.
    var owners: [String] = []

    init(snapshot: SwitchSnapshot, edits: [VLANEdit]) {
        rows = snapshot.config.vlans.map {
            Row(original: $0.name, name: $0.name, vlanID: $0.vlanID, description: $0.description, originalDescription: $0.description)
        }
        if !rows.contains(where: { $0.name == "default" || $0.vlanID == 1 }) {
            rows.append(Row(original: "default", name: "default", vlanID: 1, builtIn: true))
        }
        for e in edits {
            switch e {
            case let .add(name, id, desc):
                rows.append(Row(original: nil, name: name, vlanID: id, description: desc))
                owners.append(rows[rows.count - 1].id)
            case let .update(name, id, desc):
                guard let i = index(named: name) else { owners.append(""); continue }
                if let id { rows[i].vlanID = id }
                if let desc { rows[i].description = desc }
                owners.append(rows[i].id)
            case let .rename(from, to):
                guard let i = index(named: from) else { owners.append(""); continue }
                rows[i].name = to
                owners.append(rows[i].id)
            case let .delete(name):
                guard let i = index(named: name) else { owners.append(""); continue }
                owners.append(rows[i].id)
                if rows[i].isNew { rows.remove(at: i) } else { rows[i].deleted = true }
            }
        }
    }

    private func index(named name: String) -> Int? { rows.firstIndex { $0.name == name && !$0.deleted } }

    /// Replaces the staged edits of one room with the ones that reach the given state.
    static func restage(_ session: DeviceSession, row: Row, name: String, vlanID: Int?, description: String?, deleted: Bool) {
        guard let snap = session.snapshot else { return }
        let owners = VLANRooms(snapshot: snap, edits: session.vlanEdits).owners
        for i in owners.indices.reversed() where owners[i] == row.id { session.unstageVLAN(at: i) }
        if let original = row.original {
            guard !row.builtIn else { return }
            if deleted { session.stage(.delete(name: original)); return }
            let d = description ?? ""
            if d != (row.originalDescription ?? "") { session.stage(.update(name: original, vlanID: nil, description: d)) }
            if name != original { session.stage(.rename(from: original, to: name)) }
        } else if !deleted, let vlanID {
            let d = description?.trimmingCharacters(in: .whitespaces) ?? ""
            session.stage(.add(name: name, vlanID: vlanID, description: d.isEmpty ? nil : d))
        }
    }

    /// Junos VLAN names: letters, digits, '-', '_' and '.', starting with a letter or digit.
    static func isValidName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, s.count <= 64, CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }
}

/// Port membership of one room, staged edits included.
struct RoomPorts {
    var members: [SwitchPort] = []     // in the room now and staying
    var joining: [SwitchPort] = []     // join with a staged change

    @MainActor
    init(row: VLANRooms.Row, snapshot: SwitchSnapshot, session: DeviceSession) {
        for p in snapshot.ports {
            let now = row.original.map { p.vlans.contains($0) } ?? false
            var after = now
            if let staged = session.edit(for: p.name)?.vlans {
                after = staged.contains(row.name) || (row.original.map { staged.contains($0) } ?? false)
            }
            if now && after { members.append(p) } else if after { joining.append(p) }
        }
    }

    var all: [SwitchPort] { members + joining }
}

// MARK: - Header

struct VLANsHeader: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession

    var body: some View {
        let count = session.snapshot.map { VLANRooms(snapshot: $0, edits: session.vlanEdits).rows.count } ?? 0
        SectionHeader(title: t("VLANs"), chip: Format.plural(count, t("%@ VLAN · %@", "1", session.snapshot?.hostname ?? device.name),
                                                                t("%@ VLANs · %@", String(count), session.snapshot?.hostname ?? device.name)),
                      subtitle: t("Rooms inside the switch. Every port belongs to one room, or to several.")) {
            ReadAgainButton(session: session)
            Button { VLANsScreen.addVLAN(model: model, deviceID: device.id, session: session) } label: {
                Label(t("New VLAN"), systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!session.canStage)
        }
    }
}

// MARK: - Screen (§3.5)

struct VLANsScreen: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession

    var body: some View {
        if let snap = session.snapshot {
            let rooms = VLANRooms(snapshot: snap, edits: session.vlanEdits)
            let ordered = Self.order(rooms.rows, snapshot: snap, session: session)
            let internet = Self.internetVLAN(snap)
            let selected = rooms.rows.first { $0.id == model.vlansState[device.id]?.selected } ?? ordered.first
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    ExplanationCard(internet: internet) {
                        model.portsState[device.id, default: PortsViewState()].mode = .rooms
                        model.selection = .device(device.id, .ports)
                    }
                    NDScroll {
                        RoomGrid(rows: ordered, selected: selected?.id, internet: internet, snapshot: snap, session: session, deviceID: device.id)
                            .padding(.bottom, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if let selected {
                    VLANDetail(row: selected, snapshot: snap, session: session, deviceID: device.id,
                               otherNames: Set(rooms.rows.filter { $0.id != selected.id }.map(\.name)))
                        .id(selected.id)
                        .frame(width: 396)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .card()
                }
            }
        }
    }

    /// Rooms in use first (in the order of their first port), then empty rooms by number.
    static func order(_ rows: [VLANRooms.Row], snapshot: SwitchSnapshot, session: DeviceSession) -> [VLANRooms.Row] {
        let index = Dictionary(uniqueKeysWithValues: snapshot.ports.enumerated().map { ($0.element.name, $0.offset) })
        let first: [String: Int] = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row.id, RoomPorts(row: row, snapshot: snapshot, session: session).all.compactMap { index[$0.name] }.min() ?? Int.max)
        })
        return rows.sorted { a, b in
            let fa = first[a.id] ?? .max, fb = first[b.id] ?? .max
            if fa != fb { return fa < fb }
            return (a.vlanID ?? 0) < (b.vlanID ?? 0)
        }
    }

    /// The room the modem is in: the port with a link and several devices behind it.
    static func internetVLAN(_ snap: SwitchSnapshot) -> String? {
        snap.ports.filter { $0.linkUp && $0.macs.count >= 4 }.max { $0.macs.count < $1.macs.count }?.vlans.first
    }

    /// Stages a new VLAN with the next free round number and the next unused palette color.
    static func addVLAN(model: AppModel, deviceID: String, session: DeviceSession) {
        guard let snap = session.snapshot else { return }
        let rows = VLANRooms(snapshot: snap, edits: session.vlanEdits).rows
        let usedIDs = Set(rows.compactMap(\.vlanID))
        let id = stride(from: 10, through: 4090, by: 10).first { !usedIDs.contains($0) } ?? ((usedIDs.max() ?? 1) + 1)
        var name = "vlan-\(id)"
        var n = 2
        while rows.contains(where: { $0.name == name }) { name = "vlan-\(id)-\(n)"; n += 1 }
        let colors = model.colors(for: deviceID)
        let used = Set(rows.compactMap { colors.indexByName[$0.colorKey] })
        let color = (0..<VLANColor.palette.count).first { !used.contains($0) } ?? (rows.count % VLANColor.palette.count)
        session.stage(.add(name: name, vlanID: id, description: nil))
        model.setColor(color, vlan: name, deviceID: deviceID)
        model.vlansState[deviceID] = VLANsViewState(selected: "+\(id)")
    }

    static func shortName(_ port: String) -> String {
        guard let dash = port.firstIndex(of: "-"), let last = port.split(separator: "/").last else { return port }
        return String(port[..<dash]) + "-" + last
    }
}

// MARK: - Explanation card

private struct ExplanationCard: View {
    var internet: String?
    var learnMore: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            illustration
            VStack(alignment: .leading, spacing: 2) {
                Text(t("A VLAN is a room inside the switch.")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text1)
                Text(explanation).font(Typo.callout).foregroundStyle(Theme.text2).lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(t("Learn more"), action: learnMore).buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .card()
    }

    private var explanation: AttributedString {
        guard let internet else { return AttributedString(t("Devices in the same room see each other; devices in other rooms don't.")) }
        let full = t("Devices in the same room see each other; devices in other rooms don't. The internet is only in the room where the modem is connected: %@ today.", internet)
        var a = AttributedString(full)
        if let r = a.range(of: internet, options: .backwards) {
            a[r].font = .system(size: 12.5, weight: .semibold)
            a[r].foregroundColor = Theme.text1
        }
        return a
    }

    private var illustration: some View {
        let violet = VLANColor.palette[0], orange = VLANColor.palette[1], sky = VLANColor.palette[2]
        func room(_ c: VLANColor, _ x: CGFloat, _ y: CGFloat, _ h: CGFloat) -> some View {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.soft)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(c.base.opacity(0.3), lineWidth: 1))
                .frame(width: 62, height: h).offset(x: x, y: y)
        }
        func dot(_ x: CGFloat, _ y: CGFloat) -> some View {
            Circle().fill(violet.base).frame(width: 9, height: 9).shadow(color: .black.opacity(0.15), radius: 1, y: 1).offset(x: x, y: y)
        }
        return ZStack(alignment: .topLeading) {
            room(violet, 0, 4, 56)
            room(orange, 70, 4, 26)
            room(sky, 70, 34, 26)
            dot(12, 16); dot(30, 30); dot(16, 42)
        }
        .frame(width: 132, height: 64, alignment: .topLeading)
    }
}

/// Text-only button (`.btn.ghost` in the mockups).
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(configuration.isPressed ? Theme.surface3 : .clear))
            .contentShape(Rectangle())
    }
}

// MARK: - Room cards

private struct RoomGrid: View {
    @Environment(AppModel.self) private var model
    var rows: [VLANRooms.Row]
    var selected: String?
    var internet: String?
    var snapshot: SwitchSnapshot
    var session: DeviceSession
    var deviceID: String

    var body: some View {
        let colors = model.colors(for: deviceID)
        let cells: [VLANRooms.Row?] = rows.map { $0 } + [nil]
        VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: cells.count, by: 3)), id: \.self) { start in
                HStack(spacing: 12) {
                    ForEach(start..<start + 3, id: \.self) { i in
                        if i < cells.count {
                            if let row = cells[i] {
                                RoomCard(row: row, color: colors.color(row.colorKey), selected: row.id == selected,
                                         internet: row.original != nil && row.original == internet,
                                         ports: RoomPorts(row: row, snapshot: snapshot, session: session), session: session)
                                    .onTapGesture { model.vlansState[deviceID] = VLANsViewState(selected: row.id) }
                            } else {
                                NewRoomCard { VLANsScreen.addVLAN(model: model, deviceID: deviceID, session: session) }
                            }
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 158)
                        }
                    }
                }
            }
        }
    }
}

private struct RoomCard: View {
    var row: VLANRooms.Row
    var color: VLANColor
    var selected: Bool
    var internet: Bool
    var ports: RoomPorts
    var session: DeviceSession

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ColorSquare(color: color, size: 30, inner: 12, radius: 9)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text1)
                            .strikethrough(row.deleted).lineLimit(1)
                        if row.isStaged { Circle().fill(Theme.accent).frame(width: 6, height: 6).help(t("Staged change")) }
                    }
                    Text(subtitle).font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let id = row.vlanID {
                    Text(String(id)).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(color.ink)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.soft))
                }
            }
            FlowLayout(spacing: 5) {
                let shown = ports.all.prefix(ports.all.count > 8 ? 7 : 8)
                ForEach(shown, id: \.name) { p in PortChip(port: p, joining: ports.joining.contains(p)) }
                if ports.all.count > shown.count { PortChip(more: ports.all.count - shown.count) }
            }
            .frame(maxHeight: 49, alignment: .top)
            .clipped()
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 158)
        .background(alignment: .leading) { Rectangle().fill(color.base).frame(width: 4) }
        .clipShape(shape)
        .card()
        .overlay { if selected { shape.strokeBorder(Theme.text1, lineWidth: 1.5) } }
        .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 12, y: 8)
        .opacity(row.deleted ? 0.6 : 1)
        .contentShape(shape)
        .help([row.name, row.description].compactMap { $0 }.joined(separator: " · "))
    }

    private var subtitle: String {
        if row.builtIn { return t("Default · no internet") }
        let d = row.description ?? ""
        return d.isEmpty ? "—" : d
    }

    /// Bottom line; drops the avatars, then the text, when the card is narrow (1280-wide windows).
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerLine(avatars: true, text: true)
            footerLine(avatars: false, text: true)
            footerLine(avatars: false, text: false)
        }
        .font(Typo.caption).foregroundStyle(Theme.text3)
        .frame(minHeight: 24)
    }

    private func footerLine(avatars: Bool, text: Bool) -> some View {
        let up = ports.members.filter { $0.linkUp }
        let warnings = ports.all.filter { $0.warning != nil }.count
        let hasPill = internet || warnings > 0
        return HStack(spacing: 6) {
            if avatars && !up.isEmpty {
                HStack(spacing: -6) {
                    ForEach(up.prefix(3), id: \.name) { p in
                        let peer = PortPeer.of(p, session: session)
                        AvatarCircle(symbol: peer?.symbol ?? "cable.connector", avatar: peer?.avatar ?? .slate, size: 22)
                            .background(Circle().fill(Theme.surface).padding(-2))
                    }
                }
            }
            if text || !hasPill {
                Group {
                    if !up.isEmpty {
                        Text(up.count == 1 ? t("%@ device", "1") : t("%@ devices", String(up.count)))
                            .help(Format.plural(ports.all.count, t("%@ port · %@ up", "1", String(up.count)),
                                                t("%@ ports · %@ up", String(ports.all.count), String(up.count))))
                    } else if !ports.all.isEmpty {
                        Text(Format.plural(ports.all.count, t("%@ port", "1"), t("%@ ports", String(ports.all.count)))
                             + (warnings > 0 ? "" : " · " + t("no devices connected")))
                    } else {
                        Text(t("Empty room · no ports in this VLAN"))
                    }
                }
                .lineLimit(hasPill ? 1 : 2)
                .fixedSize(horizontal: hasPill, vertical: false)
            }
            Spacer(minLength: 0)
            if internet { Pill(text: t("Internet"), kind: .good, icon: "paperplane") }
            else if warnings > 0 {
                Pill(text: Format.plural(warnings, t("%@ warning", "1"), t("%@ warnings", String(warnings))), kind: .warn, icon: "exclamationmark.triangle")
            }
        }
    }
}

private struct PortChip: View {
    var label: String
    var led: Color
    var joining = false

    init(port: SwitchPort, joining: Bool) {
        label = VLANsScreen.shortName(port.name)
        led = port.linkUp ? Color(hex: 0x2FCB6A) : (port.warning != nil ? Theme.warn : Theme.text4)
        self.joining = joining
    }

    init(more: Int) {
        label = "+\(more)"
        led = .clear
    }

    var body: some View {
        HStack(spacing: 5) {
            if led != .clear { RoundedRectangle(cornerRadius: 2).fill(led).frame(width: 6, height: 6) }
            Text(label).monospacedDigit()
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(joining ? Theme.accentInk : Theme.text2)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(joining ? Theme.accentSoft : Theme.surface3))
        .overlay {
            if joining { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
        }
        .help(joining ? t("Joins this room") : label)
    }
}

private struct NewRoomCard: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                Text(t("New VLAN"))
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text2)
            .frame(maxWidth: .infinity).frame(height: 158)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct ColorSquare: View {
    var color: VLANColor
    var size: CGFloat
    var inner: CGFloat
    var radius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(color.soft)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.base).frame(width: inner, height: inner))
    }
}

// MARK: - Right panel: edit the selected room

private struct VLANDetail: View {
    @Environment(AppModel.self) private var model
    var row: VLANRooms.Row
    var snapshot: SwitchSnapshot
    var session: DeviceSession
    var deviceID: String
    var otherNames: Set<String>

    @State private var name: String
    @State private var desc: String
    @State private var number: String

    init(row: VLANRooms.Row, snapshot: SwitchSnapshot, session: DeviceSession, deviceID: String, otherNames: Set<String>) {
        self.row = row
        self.snapshot = snapshot
        self.session = session
        self.deviceID = deviceID
        self.otherNames = otherNames
        _name = State(initialValue: row.name)
        _desc = State(initialValue: row.description ?? "")
        _number = State(initialValue: row.vlanID.map(String.init) ?? "")
    }

    var body: some View {
        let colors = model.colors(for: deviceID)
        let color = colors.color(row.colorKey)
        let ports = RoomPorts(row: row, snapshot: snapshot, session: session)
        VStack(alignment: .leading, spacing: 0) {
            header(color: color, ports: ports)
            NDScroll {
                VStack(alignment: .leading, spacing: 14) {
                    nameAndNumber
                    descriptionField
                    colorPicker(colors: colors)
                    VStack(alignment: .leading, spacing: 7) {
                        FieldLabel(text: t("Ports in this room"))
                        VStack(alignment: .leading, spacing: 9) {
                            MiniPortMap(snapshot: snapshot, members: Set(ports.members.map(\.name)), joining: Set(ports.joining.map(\.name)), color: color)
                            Text(t("Filled: in this room · outlined: joins with a staged change"))
                                .font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1).minimumScaleFactor(0.85)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                    }
                    portList(ports)
                    deleteRow(ports)
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
            }
        }
    }

    private func header(color: VLANColor, ports: RoomPorts) -> some View {
        HStack(spacing: 12) {
            ColorSquare(color: color, size: 34, inner: 14, radius: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 17, weight: .semibold)).tracking(-0.2).foregroundStyle(Theme.text1).lineLimit(1)
                Text(subtitle(ports)).font(Typo.callout).foregroundStyle(Theme.text3).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 8)
            if row.isStaged { Pill(text: t("Staged change"), kind: .accent, dot: true) }
            Menu {
                Button(t("Delete VLAN"), role: .destructive) { delete() }.disabled(!canDelete(ports))
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(GhostButtonStyle()).fixedSize()
        }
        .padding(.horizontal, 20).padding(.top, 16)
    }

    private func subtitle(_ ports: RoomPorts) -> String {
        let id = row.vlanID.map { "VLAN \($0)" } ?? "VLAN"
        return id + " · " + Format.plural(ports.all.count, t("%@ port", "1"), t("%@ ports", String(ports.all.count)))
    }

    private var nameAndNumber: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: t("Name"))
                if row.builtIn {
                    LockedField(text: row.name)
                } else {
                    NDTextField(placeholder: t("Name"), text: $name, changed: row.renamed)
                        .onChange(of: name) { _, v in
                            let n = v.trimmingCharacters(in: .whitespaces)
                            guard n != row.name, VLANRooms.isValidName(n), !otherNames.contains(n) else { return }
                            restage(name: n)
                            if row.isNew { model.setColor(model.colors(for: deviceID).indexByName[row.colorKey] ?? 0, vlan: n, deviceID: deviceID) }
                            else if let i = model.colors(for: deviceID).indexByName[row.colorKey] { model.setColor(i, vlan: n, deviceID: deviceID) }
                        }
                    if row.renamed, let original = row.original {
                        WasRow(old: original) { name = original; restage(name: original) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: t("Number"))
                if row.isNew {
                    NDTextField(placeholder: "1–4094", text: $number, changed: true)
                        .onSubmit {
                            guard let n = Int(number.trimmingCharacters(in: .whitespaces)), (1...4094).contains(n) else { number = row.vlanID.map(String.init) ?? ""; return }
                            restage(vlanID: n)
                            model.vlansState[deviceID] = VLANsViewState(selected: "+\(n)")
                        }
                } else {
                    LockedField(text: row.vlanID.map(String.init) ?? "—")
                }
            }
            .frame(width: 110)
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: t("Description"))
            if row.builtIn {
                LockedField(text: t("Default · no internet"))
            } else {
                NDTextField(placeholder: t("Description"), text: $desc, changed: row.descriptionChanged)
                    .onChange(of: desc) { _, v in
                        guard v != (row.description ?? "") else { return }
                        restage(description: v)
                    }
                if row.descriptionChanged {
                    WasRow(old: (row.originalDescription ?? "").isEmpty ? "—" : row.originalDescription ?? "") {
                        desc = row.originalDescription ?? ""
                        restage(description: row.originalDescription ?? "")
                    }
                }
            }
        }
    }

    private func colorPicker(colors: VLANColorMap) -> some View {
        let current = colors.indexByName[row.colorKey] ?? -1
        let options: [(Int, VLANColor)] = VLANColor.palette.enumerated().map { ($0.offset, $0.element) } + [(-1, .slate)]
        return VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: t("Color"))
            HStack(spacing: 8) {
                ForEach(options, id: \.0) { index, c in
                    let on = index == current || (current >= VLANColor.palette.count && index == -1)
                    Button {
                        model.setColor(index, vlan: row.colorKey, deviceID: deviceID)
                        if row.renamed { model.setColor(index, vlan: row.name, deviceID: deviceID) }
                    } label: {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.base).frame(width: 24, height: 24)
                            .padding(2)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Theme.text1 : .clear, lineWidth: 2).padding(-2))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(c.name)
                    .accessibilityLabel(c.name)
                }
            }
            Text(t("Colors are only shown in Netdeck. They are not written to the switch."))
                .font(Typo.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func portList(_ ports: RoomPorts) -> some View {
        if !ports.all.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(ports.all.enumerated()), id: \.element.name) { i, p in
                    let joining = ports.joining.contains(p)
                    HStack(spacing: 10) {
                        Text(p.name).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(joining ? Theme.accentInk : Theme.text1)
                            .frame(width: 74, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                        if joining {
                            Circle().fill(Theme.accent).frame(width: 7, height: 7)
                            Text(t("Joins this room")).foregroundStyle(Theme.accentInk).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(t("Staged change")).font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1)
                        } else {
                            let peer = PortPeer.of(p, session: session)
                            AvatarCircle(symbol: peer?.symbol ?? "cable.connector", avatar: peer?.avatar ?? .slate, size: 22)
                            Text(peer?.name ?? p.description ?? t("No cable")).foregroundStyle(peer == nil ? Theme.text3 : Theme.text1)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            status(p)
                        }
                    }
                    .font(.system(size: 12.5))
                    .frame(height: 38)
                    .overlay(alignment: .bottom) { if i < ports.all.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) } }
                }
            }
        }
    }

    private func status(_ p: SwitchPort) -> some View {
        let (text, color): (String, Color) = switch p.state {
        case .up: (t("Up"), Theme.good)
        case .warning: (t("Warning"), Theme.warn)
        case .disabled: (t("Disabled"), Theme.text4)
        case .down, .empty: (t("No link"), Theme.text4)
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1)
    }

    @ViewBuilder private func deleteRow(_ ports: RoomPorts) -> some View {
        if !row.builtIn {
            if row.deleted {
                WasRow(old: row.name) { restage(deleted: false) }
                    .padding(.top, 2)
            } else {
                HStack(spacing: 10) {
                    Button(action: delete) { Label(t("Delete VLAN"), systemImage: "trash") }
                        .buttonStyle(DangerButtonStyle())
                        .disabled(!canDelete(ports))
                    if !canDelete(ports) {
                        Text(Format.plural(ports.all.count, t("Move the port in this room to another VLAN before deleting it."),
                                           t("Move the %@ ports in this room to another VLAN before deleting it.", String(ports.all.count))))
                            .font(Typo.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func canDelete(_ ports: RoomPorts) -> Bool { !row.builtIn && ports.all.isEmpty }

    private func delete() {
        if row.isNew {
            restage(deleted: true)
            model.vlansState[deviceID] = VLANsViewState(selected: nil)
        } else {
            restage(deleted: true)
        }
    }

    private func restage(name: String? = nil, vlanID: Int? = nil, description: String? = nil, deleted: Bool? = nil) {
        VLANRooms.restage(session, row: row, name: name ?? row.name, vlanID: vlanID ?? row.vlanID,
                          description: description ?? row.description, deleted: deleted ?? row.deleted)
    }
}

/// A read-only field with a lock (VLAN number, built-in VLAN).
private struct LockedField: View {
    var text: String
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(Typo.body).foregroundStyle(Theme.text2).monospacedDigit().lineLimit(1)
            Image(systemName: "lock").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
    }
}

/// Outlined red button (`.btn.danger`).
struct DangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.dangerInk)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(configuration.isPressed ? Theme.dangerSoft : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.dangerLine, lineWidth: 1))
            .opacity(enabled ? 1 : 0.5)
            .fixedSize()
    }
}

// MARK: - Mini port map (§4.14)

struct MiniPortMap: View {
    var snapshot: SwitchSnapshot
    var members: Set<String>
    var joining: Set<String>
    var color: VLANColor

    private let cell: CGFloat = 8, gap: CGFloat = 2, blockGap: CGFloat = 7

    var body: some View {
        let copper = Dictionary(snapshot.ports.filter { $0.kind == .copper }.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        let sfp = snapshot.ports.filter { $0.kind == .sfp }.sorted { $0.number < $1.number }
        let blocks = max(1, Int(ceil(Double((copper.keys.max() ?? 47) + 1) / 12)))
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: blockGap) {
                ForEach(0..<blocks, id: \.self) { b in
                    VStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: gap) {
                                ForEach(0..<6, id: \.self) { col in
                                    square(copper[b * 12 + col * 2 + row], width: cell, height: cell)
                                }
                            }
                        }
                    }
                }
            }
            if !sfp.isEmpty {
                Rectangle().fill(Theme.borderStrong).frame(width: 1, height: 12).padding(.horizontal, 8)
                HStack(spacing: gap) {
                    ForEach(sfp, id: \.name) { p in square(p, width: 11, height: 9) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(members.sorted().joined(separator: ", "))
    }

    @ViewBuilder private func square(_ p: SwitchPort?, width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        if let p, members.contains(p.name) {
            shape.fill(color.base).frame(width: width, height: height)
        } else if let p, joining.contains(p.name) {
            shape.fill(color.soft).overlay(shape.strokeBorder(color.base, lineWidth: 1.5)).frame(width: width, height: height)
        } else {
            shape.fill(Theme.surface3).overlay(shape.strokeBorder(Theme.border, lineWidth: 1)).frame(width: width, height: height)
        }
    }
}
