import Darwin
import NetdeckCore
import SwiftUI

// MARK: - This Mac

/// MAC addresses of this Mac's own interfaces, read locally with `getifaddrs` (AF_LINK entries).
/// Nothing is sent anywhere; the switch's MAC table is only compared against this list.
enum LocalMACs {
    static let addresses: Set<String> = read()

    /// The sample switch's MAC table lists this address as "This Mac" (see `DemoData`).
    static let sampleAddress = "64:4b:f0:00:00:08"

    static func isThisMac(_ mac: String, sample: Bool) -> Bool {
        let m = mac.lowercased()
        return addresses.contains(m) || (sample && m == sampleAddress)
    }

    private static func read() -> Set<String> {
        var out = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return out }
        defer { freeifaddrs(head) }
        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) ?? 8
        var cursor = head
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let raw = UnsafeRawPointer(sa)
            let dl = raw.load(as: sockaddr_dl.self)
            guard dl.sdl_alen == 6 else { continue }
            let start = dataOffset + Int(dl.sdl_nlen)
            let bytes = (0..<6).map { raw.load(fromByteOffset: start + $0, as: UInt8.self) }
            guard bytes.contains(where: { $0 != 0 }) else { continue }
            out.insert(bytes.map { String(format: "%02x", $0) }.joined(separator: ":"))
        }
        return out
    }
}

// MARK: - Icons for named devices

enum DeviceIcon {
    /// The six icons of the picker (§3.6): server, router, laptop, board, devices, ethernet.
    static let choices = ["server.rack", "wifi.router", "laptopcomputer", "cpu", "laptopcomputer.and.iphone", "cable.connector"]

    static func guess(name: String?, thisMac: Bool) -> String {
        if thisMac { return "laptopcomputer" }
        let n = (name ?? "").lowercased()
        if n.isEmpty { return "laptopcomputer.and.iphone" }
        if n.contains("mac") || n.contains("laptop") || n.contains("book") { return "laptopcomputer" }
        if n.contains("modem") || n.contains("router") || n.contains("gateway") { return "wifi.router" }
        if n.contains("idrac") || n.contains("ipmi") || n.contains("srv") || n.contains("server") || n.contains("bmc") { return "server.rack" }
        return "laptopcomputer.and.iphone"
    }

    static func avatar(for symbol: String, name: String?) -> Avatar {
        switch symbol {
        case "server.rack": return (name ?? "").contains("2") ? .mint : .sky
        case "wifi.router": return .peach
        case "laptopcomputer": return .lavender
        case "cpu": return .butter
        case "cable.connector": return .rose
        default: return .slate
        }
    }

    /// A switch-friendly port description from a friendly name: "Server 1 iDRAC" → "SERVER-1-IDRAC".
    static func switchDescription(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
        var out = ""
        for ch in folded.unicodeScalars {
            if ch.isASCII && CharacterSet.alphanumerics.contains(ch) { out.unicodeScalars.append(ch) }
            else if !out.isEmpty && !out.hasSuffix("-") { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

// MARK: - Model

/// One MAC address from the switch's table, with what Netdeck knows about it.
struct SeenDevice: Identifiable, Equatable {
    var mac: String
    var port: SwitchPort
    var vlan: String
    var alias: String?
    var icon: String
    var avatar: Avatar
    var vendor: String?
    var thisMac: Bool
    var lldp: String?
    var id: String { mac }
    var named: Bool { alias != nil || thisMac }
    var displayName: String? { alias ?? (thisMac ? t("This Mac") : nil) }

    @MainActor
    static func all(_ snap: SwitchSnapshot, session: DeviceSession, sample: Bool) -> [SeenDevice] {
        snap.ports.flatMap { p in
            p.macs.map { e in
                let thisMac = LocalMACs.isThisMac(e.mac, sample: sample)
                let alias = session.alias(for: e.mac)
                let icon = session.aliasIcon(for: e.mac) ?? DeviceIcon.guess(name: alias, thisMac: thisMac)
                let lldp = p.macs.count == 1 ? p.lldp.first?.systemName : nil
                return SeenDevice(mac: e.mac.lowercased(), port: p, vlan: e.vlan, alias: alias, icon: icon,
                                  avatar: alias == nil && !thisMac && session.aliasIcon(for: e.mac) == nil ? .slate : DeviceIcon.avatar(for: icon, name: alias),
                                  vendor: Vendors.lookup(e.mac), thisMac: thisMac, lldp: lldp)
            }
        }
    }
}

// MARK: - Header

struct ConnectedHeader: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession

    var body: some View {
        let snap = session.snapshot
        let macs = Set(snap?.macTable.map { $0.mac.lowercased() } ?? []).count
        let ports = snap?.ports.filter { !$0.macs.isEmpty }.count ?? 0
        let chip = switch (macs == 1, ports == 1) {
        case (true, true): t("%@ device · on %@ port", "1", "1")
        case (true, false): t("%@ device · on %@ ports", "1", String(ports))
        case (false, true): t("%@ devices · on %@ port", String(macs), "1")
        case (false, false): t("%@ devices · on %@ ports", String(macs), String(ports))
        }
        SectionHeader(title: t("Connected devices"), chip: chip,
                      subtitle: t("The switch's MAC table and LLDP neighbors. Names you give are stored only on this Mac.")) {
            SearchField(text: Binding(get: { model.connectedState[device.id]?.search ?? "" },
                                      set: { model.connectedState[device.id, default: ConnectedViewState()].search = $0 }))
            ReadAgainButton(session: session)
        }
    }
}

/// The header search box; ⌘F focuses it.
private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text3)
            TextField(t("Search MAC, name or vendor"), text: $text)
                .textFieldStyle(.plain).font(Typo.body).focused($focused)
            if text.isEmpty {
                Text("⌘F").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                    .padding(.horizontal, 5).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surface3))
            } else {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text4) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 280, height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? Theme.accent : Theme.borderStrong, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.accent.opacity(focused ? 0.22 : 0), lineWidth: 3).padding(-1.5))
        .background {
            Button("") { focused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).allowsHitTesting(false)
        }
    }
}

// MARK: - Screen (§3.6)

struct ConnectedScreen: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession

    private var state: ConnectedViewState { model.connectedState[device.id] ?? ConnectedViewState() }
    private func update(_ change: (inout ConnectedViewState) -> Void) {
        var s = state
        change(&s)
        model.connectedState[device.id] = s
    }

    var body: some View {
        if let snap = session.snapshot {
            let all = SeenDevice.all(snap, session: session, sample: model.isSample(device.id))
            let selected = all.first { $0.mac == state.selectedMAC?.lowercased() }
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    toolbar(snap, all: all)
                    DeviceTable(groups: groups(all), expanded: state.expanded, selected: selected?.mac, colors: model.colors(for: device.id),
                                session: session, select: select, expand: { port in update { $0.expanded.insert(port) } })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .card()
                if let selected {
                    DeviceDetail(device: selected, session: session, colors: model.colors(for: device.id),
                                 siblings: all.filter { $0.port.name == selected.port.name }.count) {
                        update { $0.selectedMAC = nil }
                    }
                    .id(selected.mac)
                    .frame(width: 372)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .card()
                }
            }
        }
    }

    private func select(_ d: SeenDevice) {
        update { $0.selectedMAC = d.mac }
        model.portsState[device.id, default: PortsViewState()].selected = d.port.slotKey
    }

    private func groups(_ all: [SeenDevice]) -> [(SwitchPort, [SeenDevice])] {
        let q = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [(SwitchPort, [SeenDevice])] = []
        for d in all {
            if let f = state.filter, d.port.name != f { continue }
            if state.hideUnnamed && !d.named { continue }
            if !q.isEmpty {
                let hay = [d.mac, d.mac.replacingOccurrences(of: ":", with: ""), d.displayName ?? "", d.vendor ?? "", d.port.name, d.port.description ?? ""]
                    .joined(separator: " ").lowercased()
                if !hay.contains(q) { continue }
            }
            if let i = out.firstIndex(where: { $0.0.name == d.port.name }) { out[i].1.append(d) } else { out.append((d.port, [d])) }
        }
        // This Mac first, then named devices, then the rest in table order.
        return out.map { ($0.0, $0.1.enumerated().sorted { a, b in
            let ra = a.element.thisMac ? 0 : (a.element.named ? 1 : 2), rb = b.element.thisMac ? 0 : (b.element.named ? 1 : 2)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)) }
    }

    private func toolbar(_ snap: SwitchSnapshot, all: [SeenDevice]) -> some View {
        let ports = snap.ports.filter { !$0.macs.isEmpty }
        return HStack(spacing: 10) {
            FilterSegments(options: [(nil, t("All"), all.count)] + ports.map { ($0.name, $0.name, $0.macs.count) },
                           selection: Binding(get: { state.filter }, set: { v in update { $0.filter = v } }))
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    if snap.lldp.isEmpty { Pill(text: t("LLDP: no neighbors"), kind: .outline) }
                    hideUnnamed
                }
                hideUnnamed
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
    }
}

extension ConnectedScreen {
    fileprivate var hideUnnamed: some View {
        Button { update { $0.hideUnnamed.toggle() } } label: {
            HStack(spacing: 6) {
                if state.hideUnnamed { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                Text(t("Hide unnamed")).lineLimit(1)
            }
            .foregroundStyle(state.hideUnnamed ? Theme.text1 : Theme.text2)
            .fixedSize()
        }
        .buttonStyle(GhostButtonStyle())
    }
}

/// Segments with a muted count after each label ("All 12 · ge-0/0/0 10 …").
private struct FilterSegments: View {
    var options: [(String?, String, Int)]
    @Binding var selection: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.0 == selection
                Button { selection = o.0 } label: {
                    HStack(spacing: 6) {
                        Text(o.1).foregroundStyle(on ? Theme.text1 : Theme.text2)
                        Text(String(o.2)).foregroundStyle(Theme.text3).monospacedDigit()
                    }
                    .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface)
                                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface3))
        .fixedSize()
    }
}

// MARK: - Table (§4.8)

private enum Col {
    static let mac: CGFloat = 162, vendor: CGFloat = 114, ip: CGFloat = 98, port: CGFloat = 78, action: CGFloat = 28
}

private struct DeviceTable: View {
    var groups: [(SwitchPort, [SeenDevice])]
    var expanded: Set<String>
    var selected: String?
    var colors: VLANColorMap
    var session: DeviceSession
    var select: (SeenDevice) -> Void
    var expand: (String) -> Void

    static let visible = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(t("Device")).frame(maxWidth: .infinity, alignment: .leading)
                Text(t("MAC address")).frame(width: Col.mac, alignment: .leading)
                Text(t("Vendor")).frame(width: Col.vendor, alignment: .leading)
                Text(t("IP")).frame(width: Col.ip, alignment: .leading)
                Text(t("Port")).frame(width: Col.port, alignment: .leading)
                Color.clear.frame(width: Col.action)
            }
            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text3).lineLimit(1)
            .padding(.leading, 20).padding(.trailing, 16)
            .frame(height: 30)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            NDScroll {
                VStack(spacing: 0) {
                    ForEach(groups, id: \.0.name) { port, devices in
                        GroupRow(port: port, devices: devices, colors: colors, session: session)
                        let open = expanded.contains(port.name) || devices.count <= Self.visible + 1
                        ForEach(open ? devices : Array(devices.prefix(Self.visible))) { d in
                            SeenDeviceRow(device: d, selected: d.mac == selected) { select(d) }
                        }
                        if !open {
                            Button { expand(port.name) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                                    Text(t("Show %@ more MACs", String(devices.count - Self.visible)))
                                }
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accentInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 30).frame(height: 38)
                                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct GroupRow: View {
    var port: SwitchPort
    var devices: [SeenDevice]
    var colors: VLANColorMap
    var session: DeviceSession

    var body: some View {
        let vlan = (session.edit(for: port.name)?.vlans ?? port.vlans).first
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(port.linkUp ? Color(hex: 0x2FCB6A) : Theme.text4)
                .frame(width: 8, height: 8)
                .shadow(color: port.linkUp ? Color(hex: 0x2FCB6A).opacity(0.6) : .clear, radius: 3)
            Text(port.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text1).fixedSize()
            if let d = port.description, !d.isEmpty { Text(d).font(.system(size: 12.5)).foregroundStyle(Theme.text3).lineLimit(1).layoutPriority(-1) }
            if let vlan {
                let id = session.snapshot?.config.vlan(named: vlan)?.vlanID
                VLANChip(name: vlan, vlanID: id, color: colors.color(vlan), size: .small)
            }
            if let behind { Text(behind).font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.tail).layoutPriority(-2) }
            Spacer(minLength: 8)
            Text(port.macs.count == 1 ? t("1 MAC") : t("%@ MACs", String(port.macs.count)))
                .font(Typo.caption).foregroundStyle(Theme.text3).monospacedDigit().fixedSize()
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .frame(height: 40)
        .background(Theme.surface2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    /// What is behind the port: its LLDP name, or the vendor when one device is plugged in.
    private var behind: String? {
        if let n = port.lldp.first?.systemName, !n.isEmpty { return n }
        if port.macs.count == 1, let v = port.macs.first.flatMap({ Vendors.lookup($0.mac) }) { return v }
        return nil
    }
}

private struct SeenDeviceRow: View {
    var device: SeenDevice
    var selected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    AvatarCircle(symbol: device.icon, avatar: device.avatar, size: 26)
                    if let name = device.displayName {
                        let title = Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text1).lineLimit(1)
                        if device.thisMac {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) { title.fixedSize(); Pill(text: t("Netdeck runs here"), kind: .accent).fixedSize() }
                                title.help(t("Netdeck runs here"))
                            }
                        } else {
                            title
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil").font(.system(size: 12, weight: .medium))
                            Text(t("Give it a name")).lineLimit(1)
                        }
                        .font(.system(size: 13)).foregroundStyle(Theme.text4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(device.mac).font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text1)
                    .frame(width: Col.mac, alignment: .leading)
                vendor.frame(width: Col.vendor, alignment: .leading)
                Text("—").foregroundStyle(Theme.text3).frame(width: Col.ip, alignment: .leading)
                Text(device.port.name).foregroundStyle(selected ? Theme.text1 : Theme.text3).monospacedDigit()
                    .frame(width: Col.port, alignment: .leading)
                Image(systemName: selected ? "pencil" : "ellipsis")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(selected ? Theme.text1 : Theme.text2)
                    .frame(width: Col.action, alignment: .trailing)
            }
            .font(.system(size: 13)).lineLimit(1)
            .padding(.leading, 20).padding(.trailing, 16)
            .frame(height: 46)
            .background(selected ? Theme.accentSoft.opacity(0.6) : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([device.displayName ?? t("Give it a name"), device.mac, device.port.name].joined(separator: ", "))
    }

    @ViewBuilder private var vendor: some View {
        if let v = device.vendor, v != t("Randomized MAC") {
            HStack(spacing: 8) {
                Text(String(v.prefix(1))).font(.system(size: 10, weight: .bold)).foregroundStyle(Avatar.sky.ink)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Avatar.sky.fill))
                Text(v).foregroundStyle(Theme.text1).lineLimit(1)
            }
        } else {
            Text(device.vendor ?? t("Unknown")).foregroundStyle(Theme.text3).lineLimit(1)
        }
    }
}

// MARK: - Right panel

private struct DeviceDetail: View {
    var device: SeenDevice
    var session: DeviceSession
    var colors: VLANColorMap
    var siblings: Int
    var close: () -> Void

    @State private var name: String

    init(device: SeenDevice, session: DeviceSession, colors: VLANColorMap, siblings: Int, close: @escaping () -> Void) {
        self.device = device
        self.session = session
        self.colors = colors
        self.siblings = siblings
        self.close = close
        _name = State(initialValue: device.alias ?? "")
    }

    private var icon: String { session.aliasIcon(for: device.mac) ?? device.icon }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(t("Device")).font(.system(size: 17, weight: .semibold)).tracking(-0.2).foregroundStyle(Theme.text1)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.top, 16)
            NDScroll {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        AvatarCircle(symbol: icon, avatar: DeviceIcon.avatar(for: icon, name: name.isEmpty ? device.displayName : name), size: 44)
                        NDTextField(placeholder: device.thisMac ? t("This Mac") : t("Give it a name"), text: $name)
                            .onChange(of: name) { _, v in session.setAlias(v, icon: session.aliasIcon(for: device.mac), for: device.mac) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        FieldLabel(text: t("Icon"))
                        HStack(spacing: 6) {
                            ForEach(DeviceIcon.choices, id: \.self) { symbol in
                                let on = symbol == icon
                                Button { session.setAlias(session.alias(for: device.mac), icon: symbol, for: device.mac) } label: {
                                    Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(on ? Theme.text1 : Theme.text2)
                                        .frame(width: 34, height: 34)
                                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.surface2 : .clear))
                                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(on ? Theme.text1 : Theme.borderStrong, lineWidth: on ? 1.5 : 1))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    values
                    suggestion
                    Text(t("Name and icon are stored only on this Mac, never on the switch."))
                        .font(Typo.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 20)
            }
        }
    }

    private var values: some View {
        VStack(spacing: 0) {
            row(t("MAC")) { Text(device.mac).font(.system(size: 12.5, weight: .semibold, design: .monospaced)) }
            row(t("Vendor")) { Text(device.vendor ?? t("Unknown")).foregroundStyle(device.vendor == nil ? Theme.text3 : Theme.text1) }
            row(t("IP")) { Text("—").foregroundStyle(Theme.text3) }
            row(t("Port")) {
                HStack(spacing: 6) {
                    Text(device.port.name).monospacedDigit()
                    let id = session.snapshot?.config.vlan(named: device.vlan)?.vlanID
                    VLANChip(name: device.vlan, vlanID: id, color: colors.color(device.vlan), size: .small)
                }
            }
            row(t("LLDP"), last: true) {
                Text(device.lldp ?? t("The device doesn't announce itself")).fontWeight(.regular).foregroundStyle(device.lldp == nil ? Theme.text3 : Theme.text1)
            }
        }
    }

    private func row<V: View>(_ label: String, last: Bool = false, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(Theme.text3)
            Spacer(minLength: 8)
            value().fontWeight(.medium).foregroundStyle(Theme.text1).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .font(.system(size: 12.5))
        .frame(height: 32)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.border).frame(height: 1) } }
    }

    /// Offered when the only device on a port has a name the port description doesn't match.
    @ViewBuilder private var suggestion: some View {
        let alias = session.alias(for: device.mac)
        let current = device.port.description ?? ""
        let staged = session.edit(for: device.port.name)?.description
        if let alias, siblings == 1, device.port.macs.count == 1 {
            let proposed = DeviceIcon.switchDescription(for: alias)
            if !proposed.isEmpty, proposed != DeviceIcon.switchDescription(for: current), staged != proposed {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "tag").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accentInk).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Port description differs: %@", current.isEmpty ? "—" : current))
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text1)
                        Text(t("Change the switch description to \"%@\" too? It is added to staged changes and only applied after you confirm.", proposed))
                            .font(Typo.caption).foregroundStyle(Theme.text2).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
                        Button(t("Add to changes")) { session.stage(PortEdit(port: device.port.name, description: proposed)) }
                            .buttonStyle(SmallSecondaryButtonStyle())
                            .padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentSoft))
            }
        }
    }
}

/// 26-high secondary button used inside info boxes.
struct SmallSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(configuration.isPressed ? Theme.surface3 : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
            .fixedSize()
    }
}
