import NetdeckCore
import SwiftUI

/// Overview of a device read over an HTTPS API: a server BMC (Redfish) or a NAS (Synology, TrueNAS).
/// Read only, apart from server power commands behind a confirmation. Same card language as the
/// basic-support screen: a stage with the type tile on top, what was read below, connection facts on the right.
struct ApplianceScreen: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession
    var appliance: ApplianceSnapshot
    /// The power command waiting for the user's confirmation.
    @State private var asking: ApplianceSnapshot.PowerAction?
    /// The last power command sent from here, for the "accepted" note.
    @State private var sent: ApplianceSnapshot.PowerAction?

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).frame(height: 54)
            stage.padding(.horizontal, 12)
            HStack(alignment: .top, spacing: 0) {
                NDScroll {
                    content.padding(.horizontal, 24).padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(Theme.border).frame(width: 1)
                side.padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(width: 380).frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card()
        .alert(asking.map { $0.question(device.name) } ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
               presenting: asking) { action in
            Button(action.title, role: .destructive) {
                sent = action
                model.power(device.id, action)
            }
            Button(t("Cancel"), role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { action in
            Text(action.consequence)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(t("Overview")).font(Typo.cardTitle).foregroundStyle(Theme.text1)
                Text(t("Read over the device's API · %@", Format.time(appliance.takenAt))).font(Typo.caption).foregroundStyle(Theme.text3)
            }
            Spacer()
            if case let .working(step) = session.phase {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(step).font(Typo.caption).foregroundStyle(Theme.text3)
                }
            }
            HealthPill(health: appliance.worstHealth)
            if appliance.power != .unknown {
                Pill(text: appliance.power == .on ? t("Powered on") : t("Powered off"), kind: appliance.power == .on ? .good : .outline,
                     dot: appliance.power == .on)
            }
            let choices = powerChoices
            if !choices.isEmpty, !model.isSample(device.id) {
                Menu {
                    let gentle = choices.filter { !$0.isForced }, forced = choices.filter(\.isForced)
                    ForEach(gentle, id: \.self) { a in Button(a.title) { asking = a } }
                    if !gentle.isEmpty, !forced.isEmpty { Divider() }
                    ForEach(forced, id: \.self) { a in Button(a.title) { asking = a } }
                } label: {
                    Label(t("Power"), systemImage: "power")
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(SecondaryButtonStyle()).fixedSize()
                .disabled(session.isBusy)
            }
        }
    }

    /// The commands that make sense in the current state: "Turn on" only while off, the rest only while on.
    private var powerChoices: [ApplianceSnapshot.PowerAction] {
        appliance.powerActions.filter { a in
            switch appliance.power {
            case .on: return a != .on
            case .off: return a == .on
            case .unknown: return true
            }
        }
    }

    private var stage: some View {
        ZStack {
            StageBackground()
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.darkTile)
                    .frame(width: 84, height: 84)
                    .overlay(Image(systemName: appliance.kind.symbol).font(.system(size: 34, weight: .medium)).foregroundStyle(Theme.onDarkTile))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
                VStack(spacing: 3) {
                    Text(title).font(.system(size: 17, weight: .semibold)).tracking(-0.2).foregroundStyle(Theme.text1)
                    Text(subtitle).font(Typo.callout).foregroundStyle(Theme.text3)
                }
            }
        }
        .frame(height: 200)
    }

    private var title: String {
        let parts = [appliance.platform.namesVendor ? appliance.platform.vendor : nil, appliance.model].compactMap { $0 }
        return parts.isEmpty ? device.name : parts.joined(separator: " ")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let v = appliance.osVersion { parts.append(v) }
        parts.append(appliance.kind.title)
        if let h = appliance.hostname, h != device.name { parts.append(h) }
        return parts.joined(separator: " · ")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = session.lastError, !session.isBusy {
                notice(error, icon: "exclamationmark.octagon.fill", tint: Theme.danger, ink: Theme.dangerInk,
                       fill: Theme.dangerSoft, line: Theme.dangerLine) { session.clearError() }
            } else if sent != nil, !session.isBusy {
                notice(t("The server accepted the power command. Its power state can take a minute to change; read again to see it."),
                       icon: "power", tint: Theme.accent, ink: Theme.accentInk, fill: Theme.accentSoft, line: Theme.border) { sent = nil }
            }
            if !appliance.alerts.isEmpty { alerts }
            section(t("Summary")) {
                let tiles = summaryTiles
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(Array(stride(from: 0, to: tiles.count, by: 3)), id: \.self) { i in
                        GridRow {
                            ForEach(i..<min(i + 3, tiles.count), id: \.self) { j in tile(tiles[j].label, tiles[j].value, mono: tiles[j].label == t("Serial")) }
                        }
                    }
                }
            }
            if !appliance.pools.isEmpty {
                section(appliance.kind == .server ? t("Storage") : t("Storage pools")) {
                    VStack(spacing: 8) { ForEach(appliance.pools) { PoolRow(pool: $0) } }
                }
            }
            if !appliance.disks.isEmpty {
                section(t("Disks · %@", String(appliance.disks.count))) {
                    table {
                        ForEach(appliance.disks) { d in
                            row(health: d.health, title: d.name, detail: [d.model, d.type, d.sizeBytes.map(Self.bytes), d.pool].compactMap { $0 }.joined(separator: " · "),
                                trailing: d.temperature.map { Self.celsius($0) })
                        }
                    }
                }
            }
            let temps = appliance.sensors.filter { $0.kind == .temperature }, fans = appliance.sensors.filter { $0.kind == .fan }
            if !temps.isEmpty || !fans.isEmpty {
                section(t("Sensors")) {
                    HStack(alignment: .top, spacing: 12) {
                        if !temps.isEmpty {
                            table { ForEach(temps) { s in row(health: s.health, title: s.name, detail: nil, trailing: s.reading.map(Self.celsius)) } }
                        }
                        if !fans.isEmpty {
                            table { ForEach(fans) { s in row(health: s.health, title: s.name, detail: nil, trailing: s.reading.map { Self.reading($0, unit: s.unit) }) } }
                        }
                    }
                }
            }
            if !appliance.components.isEmpty {
                section(t("Power supplies and components")) {
                    table { ForEach(appliance.components) { c in row(health: c.health, title: c.name, detail: c.detail, trailing: nil) } }
                }
            }
            if !appliance.interfaces.isEmpty {
                section(t("Network interfaces")) {
                    table {
                        ForEach(appliance.interfaces) { i in
                            row(health: i.linkUp == true ? .ok : .unknown, title: i.name,
                                detail: ([i.mac?.lowercased()] + i.addresses.map { Optional($0) }).compactMap { $0 }.joined(separator: " · "),
                                trailing: i.linkUp == false ? t("No link") : i.speedMbps.map(Self.speed))
                        }
                    }
                }
            }
            if !appliance.firmware.isEmpty {
                section(t("Firmware")) {
                    VStack(spacing: 0) { ForEach(appliance.firmware) { ValueRow(label: $0.label, value: $0.value, mono: true) } }
                }
            }
        }
    }

    private var summaryTiles: [ApplianceSnapshot.Fact] {
        var out: [ApplianceSnapshot.Fact] = [
            .init(label: t("Model"), value: appliance.model ?? "—"),
            .init(label: t("Serial"), value: appliance.serial ?? "—"),
            .init(label: t("Software"), value: appliance.osVersion ?? "—"),
        ]
        if let up = appliance.uptimeSeconds { out.append(.init(label: t("Uptime"), value: BasicOverviewScreen.uptime(ApplianceSnapshot.uptimeText(up).replacingOccurrences(of: " ", with: "")))) }
        out += appliance.facts
        return out
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text(Format.plural(appliance.alerts.count, t("%@ alert on the device", "1"), t("%@ alerts on the device", String(appliance.alerts.count))))
                    .font(Typo.bodyStrong).foregroundStyle(Theme.warnInk)
            }
            ForEach(Array(appliance.alerts.prefix(6).enumerated()), id: \.offset) { _, a in
                Text(a).font(Typo.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)   // device text
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warnSoft))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warnLine, lineWidth: 1))
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.goodInk).padding(.top, 1)
                Text(appliance.powerActions.isEmpty
                     ? t("Netdeck only reads this device over its API. It never changes settings or power.")
                     : t("Netdeck reads this device over its API and never changes its settings. Power commands go out only after you confirm them."))
                    .font(Typo.callout).foregroundStyle(Theme.text1).lineSpacing(2.5).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.goodSoft))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.goodLine, lineWidth: 1))
            ConnectionFacts(device: device, session: session)
            Spacer(minLength: 0)
        }
    }

    // MARK: Pieces

    /// One dismissable line above the content: a failed power command, or one the server accepted.
    private func notice(_ text: String, icon: String, tint: Color, ink: Color, fill: Color, line: Color,
                        dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).padding(.top, 1)
            Text(text).font(Typo.callout).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)   // device text when an error
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.text3).help(t("Close"))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(line, lineWidth: 1))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MicroHeading(text: title)
            content()
        }
    }

    private func table<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func row(health: ApplianceSnapshot.Health, title: String, detail: String?, trailing: String?) -> some View {
        HStack(spacing: 10) {
            Circle().fill(HealthPill.color(health)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typo.bodyStrong).foregroundStyle(Theme.text1).lineLimit(1)
                if let detail, !detail.isEmpty { Text(detail).font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text2) }
        }
        .frame(minHeight: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1).opacity(0.7) }
    }

    private func tile(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Typo.caption).foregroundStyle(Theme.text3)
            Text(value).font(mono ? .system(size: 13, weight: .medium, design: .monospaced) : .system(size: 13, weight: .semibold))
                .foregroundStyle(value == "—" ? Theme.text3 : Theme.text1).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface2))
    }

    // MARK: Formatting

    /// Decimal units (as disks are sold), in the UI language's number format.
    static func bytes(_ n: Int64) -> String {
        n.formatted(.byteCount(style: .decimal).locale(L10n.locale))
    }

    static func celsius(_ v: Double) -> String { String(format: "%.0f °C", v) }

    static func reading(_ v: Double, unit: String) -> String {
        unit.isEmpty ? String(format: "%.0f", v) : String(format: "%.0f %@", v, unit)
    }

    static func speed(_ mbps: Int) -> String { mbps >= 1000 && mbps % 1000 == 0 ? "\(mbps / 1000)G" : "\(mbps)M" }
}

/// One storage pool or volume: name, layout, status pill and a usage bar.
private struct PoolRow: View {
    var pool: ApplianceSnapshot.StoragePool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(pool.name).font(Typo.bodyStrong).foregroundStyle(Theme.text1)
                if let layout = pool.layout { Text(layout).font(Typo.caption).foregroundStyle(Theme.text3) }
                Spacer()
                HealthPill(health: pool.health, text: pool.status)
            }
            if let size = pool.sizeBytes, size > 0, pool.usedBytes == nil {
                Text(ApplianceScreen.bytes(size)).font(Typo.caption).foregroundStyle(Theme.text3).monospacedDigit()
            } else if let size = pool.sizeBytes, size > 0 {
                let used = pool.usedBytes ?? 0
                let fraction = min(1, max(0, Double(used) / Double(size)))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface3)
                        Capsule().fill(fraction > 0.9 ? Theme.warn : Theme.accent).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
                Text(t("%@ used of %@", ApplianceScreen.bytes(used), ApplianceScreen.bytes(size)))
                    .font(Typo.caption).foregroundStyle(Theme.text3).monospacedDigit()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Health as a pill: Healthy / Warning / Critical / Unknown (or the device's own word).
struct HealthPill: View {
    var health: ApplianceSnapshot.Health
    var text: String?

    var body: some View {
        switch health {
        case .ok: Pill(text: text ?? t("Healthy"), kind: .good, dot: true)
        case .warning: Pill(text: text ?? t("Warning"), kind: .warn, icon: "exclamationmark.triangle.fill")
        case .critical: Pill(text: text ?? t("Critical"), kind: .danger, dot: true)
        case .unknown: Pill(text: text ?? t("Unknown"), kind: .outline)
        }
    }

    static func color(_ h: ApplianceSnapshot.Health) -> Color {
        switch h {
        case .ok: return Theme.good
        case .warning: return Theme.warn
        case .critical: return Theme.danger
        case .unknown: return Theme.text4
        }
    }
}

/// Plain names and the one-sentence consequence for the confirmation.
extension ApplianceSnapshot.PowerAction {
    var title: String {
        switch self {
        case .on: return t("Turn on")
        case .gracefulShutdown: return t("Shut down")
        case .gracefulRestart: return t("Restart")
        case .forceRestart: return t("Force restart")
        case .forceOff: return t("Force off")
        case .powerCycle: return t("Power cycle")
        }
    }

    /// Cuts the power or resets without asking the operating system.
    var isForced: Bool { self == .forceRestart || self == .forceOff || self == .powerCycle }

    func question(_ name: String) -> String {
        switch self {
        case .on: return t("Turn on %@?", name)
        case .gracefulShutdown: return t("Shut down %@?", name)
        case .gracefulRestart: return t("Restart %@?", name)
        case .forceRestart: return t("Force restart %@?", name)
        case .forceOff: return t("Force off %@?", name)
        case .powerCycle: return t("Power cycle %@?", name)
        }
    }

    var consequence: String {
        switch self {
        case .on: return t("The server powers on and starts its operating system.")
        case .gracefulShutdown: return t("The operating system is asked to shut down. Everything running on the server stops.")
        case .gracefulRestart: return t("The operating system is asked to restart. Everything running on the server stops until it is back.")
        case .forceRestart: return t("The server restarts at once, without shutting down the operating system. Unsaved data is lost.")
        case .forceOff: return t("The server turns off at once, like pulling the power cord. Unsaved data is lost.")
        case .powerCycle: return t("The server turns off at once and back on, like pulling the power cord and plugging it in again. Unsaved data is lost.")
        }
    }
}
