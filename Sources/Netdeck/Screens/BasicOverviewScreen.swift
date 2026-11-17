import NetdeckCore
import SwiftUI

/// Basic-support device screen (§3.11): a device Netdeck recognized but has no full driver for yet.
/// No faceplate, no ports, no staging; only what was read, in the visual language of the
/// add-device "basic support" result card (07c).
struct BasicOverviewScreen: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession

    private var detection: Detection? { session.detection ?? device.detected }
    private var platform: Platform { detection?.platform ?? device.effectivePlatform ?? .unknown }
    private var kind: DeviceKind { detection?.kind ?? device.kind }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).frame(height: 54)
            stage.padding(.horizontal, 12)
            HStack(alignment: .top, spacing: 0) {
                facts.padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(Theme.border).frame(width: 1)
                side.padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(width: 380).frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card()
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(t("Overview")).font(Typo.cardTitle).foregroundStyle(Theme.text1)
                Text(t("Basic information")).font(Typo.caption).foregroundStyle(Theme.text3)
            }
            Spacer()
        }
    }

    /// The stage keeps the board's shape; instead of a faceplate it shows the device as a type tile.
    private var stage: some View {
        ZStack {
            StageBackground()
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.darkTile)
                    .frame(width: 84, height: 84)
                    .overlay(Image(systemName: kind.symbol).font(.system(size: 34, weight: .medium)).foregroundStyle(Theme.onDarkTile))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
                VStack(spacing: 3) {
                    Text(title).font(.system(size: 17, weight: .semibold)).tracking(-0.2).foregroundStyle(Theme.text1)
                    Text(subtitle).font(Typo.callout).foregroundStyle(Theme.text3)
                }
            }
        }
        .frame(height: 236)
    }

    private var title: String {
        [platform == .unknown ? nil : platform.vendor, detection?.model].compactMap { $0 }.joined(separator: " ")
            .nilIfEmpty ?? device.name
    }

    private var subtitle: String {
        var parts: [String] = []
        if let v = detection?.osVersion { parts.append("\(platform.osName) \(v)") }
        parts.append(kind.title)
        if let h = detection?.hostname, h != device.name { parts.append(h) }
        return parts.joined(separator: " · ")
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicroHeading(text: t("Basic information"))
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    tile(t("Model"), detection?.model)
                    tile(t("OS version"), detection?.osVersion.map { "\(platform.osName) \($0)" })
                    tile(t("Uptime"), detection?.uptime.map(Self.uptime))
                }
                GridRow {
                    tile(t("Serial"), detection?.serial, mono: true)
                    tile(t("Last read"), (session.detectedAt ?? session.snapshot?.takenAt).map(Format.relativeDay))
                    tile(t("Shown as"), t("Info card, no panel"))
                }
            }
            MicroHeading(text: t("Not available with basic support")).padding(.top, 10)
            VStack(spacing: 0) {
                unavailable("rectangle.connected.to.line.below", t("Front panel and ports"))
                unavailable("square.3.layers.3d", t("VLANs"))
                unavailable("laptopcomputer.and.iphone", t("Connected devices"))
                unavailable("pencil", t("Changes, with the safety timer"), last: true)
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            Spacer(minLength: 0)
        }
    }

    private func unavailable(_ symbol: String, _ title: String, last: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text3).frame(width: 18)
            Text(title).font(Typo.body).foregroundStyle(Theme.text2)
            Spacer()
            Pill(text: t("Coming soon"), kind: .outline, small: true)
        }
        .frame(height: 40)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.border).frame(height: 1) } }
    }

    private func tile(_ label: String, _ value: String?, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Typo.caption).foregroundStyle(Theme.text3)
            Text(value ?? t("Unknown"))
                .font(mono && value != nil ? .system(size: 13, weight: .medium, design: .monospaced) : .system(size: 13, weight: .semibold))
                .foregroundStyle(value == nil ? Theme.text3 : Theme.text1).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accentInk)
                    .padding(.top, 1)
                Text(t("Full support for %@ is coming. Netdeck only reads this device; it never changes it.", platform == .unknown ? device.name : platform.vendor))
                    .font(Typo.callout).foregroundStyle(Theme.text1).lineSpacing(2.5).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentSoft))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
            ConnectionFacts(device: device, session: session)
        }
    }

    /// RouterOS prints "12d4h3m"; show it as "12 d 4 h" in the UI language's digits.
    static func uptime(_ raw: String) -> String {
        guard raw.range(of: #"^(\d+w)?(\d+d)?(\d+h)?(\d+m)?(\d+s)?$"#, options: .regularExpression) != nil else { return raw }
        var weeks = 0, days = 0, hours = 0, minutes = 0, number = ""
        for ch in raw {
            if ch.isNumber { number.append(ch); continue }
            let n = Int(number) ?? 0
            switch ch { case "w": weeks = n; case "d": days = n; case "h": hours = n; case "m": minutes = n; default: break }
            number = ""
        }
        days += weeks * 7
        if days > 0 { return days == 1 ? t("%@ day %@ h", "1", String(hours)) : t("%@ days %@ h", String(days), String(hours)) }
        return t("%@ h %@ min", String(hours), String(minutes))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
