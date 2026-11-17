import AppKit
import NetdeckCore
import SwiftUI

// The board while a device has no fresh read: connecting (§3.12), a connection error (§3.13, one
// card at a time), someone else's uncommitted changes, or not connected yet. The stage shows a
// skeleton faceplate (or the last known panel when it is younger than a day); the inspector area
// below holds the progress or the error card. Nothing here talks to a device on its own: buttons go
// through `AppModel.connect` / `read`, or open a review sheet.

struct ConnectionBoard: View {
    enum Mode {
        case connecting
        case failed(ConnectionFailure)
        case foreign(String)
        case idle
    }

    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession
    var mode: Mode

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).frame(height: 54)
            BoardStage(device: device, session: session, mode: mode).padding(.horizontal, 12)
            HStack(alignment: .top, spacing: 0) {
                left.padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(Theme.border).frame(width: 1)
                right.padding(.horizontal, 24).padding(.vertical, 20)
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
                Text(model.isAppliance(device.id) ? t("Overview") : t("Front panel")).font(Typo.cardTitle).foregroundStyle(Theme.text1)
                if BoardStage.isEX4300(device: device, session: session) {
                    Text(t("48 copper ports (1G) · 4 SFP+ slots (10G)")).font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(1)
                }
            }
            .layoutPriority(1)
            switch mode {
            case .connecting: Pill(text: model.isAppliance(device.id) ? t("Reading…") : t("Reading ports…"), kind: .outline)
            case .foreign: Pill(text: t("Apply is off"), kind: .warn, icon: "lock")
            default: EmptyView()
            }
            Spacer(minLength: 8)
            if case .connecting = mode, BoardStage.isEX4300(device: device, session: session) {
                Segmented(options: [(PanelFace.front, t("Front"), nil), (.rear, t("Rear"), nil)], selection: .constant(.front), compact: true)
                    .disabled(true).opacity(0.55)
            }
        }
    }

    @ViewBuilder
    private var left: some View {
        switch mode {
        case .connecting: ConnectingProgress(device: device, session: session)
        case let .failed(f): ErrorCard(device: device, session: session, failure: f)
        case let .foreign(diff): ForeignChangesCard(device: device, session: session, diff: diff)
        case .idle: IdleCard(device: device, session: session)
        }
    }

    @ViewBuilder
    private var right: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch mode {
            case .connecting:
                if case .serial = session.profile.connection {
                    InfoBox(title: t("Why does this take a while?"),
                            text: t("A serial console carries about 1 KB per second, so a full read takes around 20 seconds. With a cable on the management port (MGMT) and SSH it drops to a few seconds."))
                }
                ReadOnlyBox()
            case let .foreign(diff):
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("In the uncommitted changes")).font(Typo.bodyStrong).foregroundStyle(Theme.text1)
                    DiffSummaryList(items: DiffSummary.items(ConfigCompare.setDiff(fromCompare: diff), current: session.snapshot?.config),
                                    snapshot: session.snapshot, colors: model.colors(for: device.id), limit: 5)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                ConnectionFacts(device: device, session: session)
            default:
                ConnectionFacts(device: device, session: session)
                ReadOnlyBox()
            }
        }
    }
}

// MARK: - Stage

struct BoardStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var device: DeviceProfile
    var session: DeviceSession
    var mode: ConnectionBoard.Mode

    static let height: CGFloat = 236
    private let top: CGFloat = 34, legend: CGFloat = 44, side: CGFloat = 20

    static func isEX4300(device: DeviceProfile, session: DeviceSession) -> Bool {
        let model = session.snapshot?.model ?? session.detection?.model ?? device.detected?.model ?? ""
        return model.uppercased().hasPrefix("EX4300-48")
    }

    /// The last read, if it is younger than a day (§3.12).
    private var lastKnown: SwitchSnapshot? {
        guard let s = session.snapshot, Date().timeIntervalSince(s.takenAt) < 86_400 else { return nil }
        return s
    }

    private var isForeign: Bool { if case .foreign = mode { return true }; return false }
    private var isConnecting: Bool { if case .connecting = mode { return true }; return false }

    var body: some View {
        if model.isAppliance(device.id) { applianceStage } else { panelStage }
    }

    /// Servers and NAS have no faceplate: the device's type tile on the stage.
    private var applianceStage: some View {
        ZStack {
            StageBackground()
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.darkTile).frame(width: 84, height: 84)
                .overlay(Image(systemName: device.kind.symbol).font(.system(size: 34, weight: .medium)).foregroundStyle(Theme.onDarkTile))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
                .opacity(isConnecting ? 0.6 : 1)
        }
        .frame(height: Self.height)
    }

    private var panelStage: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let panelW = w - side * 2
            let shown = panelPorts
            let panelH = panelW / FrontGeometry.aspect(shown, hasCables: false)
            let s = PanelScale(width: panelW, ports: shown)
            let cw = FrontGeometry.chassisWidth(shown)
            ZStack(alignment: .topLeading) {
                StageBackground()
                FloorShadow().frame(width: panelW * 0.9, height: 18)
                    .position(x: w / 2, y: top + s.y(FrontGeometry.chassisHeight) - 4)
                    .opacity(lastKnown != nil && !isForeign ? 0.5 : 1)
                panel
                    .frame(width: panelW, height: panelH)
                    .overlay {
                        if isConnecting && !reduceMotion && !RenderMode.active {
                            Sheen().frame(width: s.rect(CGRect(x: 0, y: 0, width: cw, height: 118)).width,
                                          height: s.rect(CGRect(x: 0, y: 0, width: cw, height: 118)).height)
                                .position(x: s.x(cw / 2), y: s.y(59))
                        }
                    }
                    .offset(x: side, y: top)
                if let snap = lastKnown, !isForeign {
                    HStack(spacing: 5) {
                        Image(systemName: "clock").font(.system(size: 10.5, weight: .semibold))
                        Text(t("Last known state · %@", Format.relativeDay(snap.takenAt)))
                    }
                    .font(Typo.chip).foregroundStyle(Theme.text2)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().strokeBorder(Theme.borderStrong, lineWidth: 1))
                    .offset(x: 16, y: 8)
                }
                if let note {
                    Text(note).font(Typo.callout).foregroundStyle(Theme.text3).lineLimit(1)
                        .frame(height: legend, alignment: .center)
                        .offset(x: 18, y: Self.height - legend)
                }
            }
        }
        .frame(height: Self.height)
    }

    /// Ports of the panel on the board: the last known (or foreign-candidate) reading, else the skeleton.
    private var panelPorts: [PanelPort] {
        if let snap = isForeign ? session.snapshot : lastKnown {
            return PanelBuilder.ports(snapshot: snap, session: session, colors: model.colors(for: device.id))
        }
        return Self.skeletonPorts
    }

    @ViewBuilder
    private var panel: some View {
        if let snap = isForeign ? session.snapshot : lastKnown {
            FrontPanelView(model: snap.model, vendor: snap.platform.vendor, hostname: device.name,
                           ports: panelPorts, showsCables: false)
                .opacity(isForeign ? 1 : 0.5)
        } else {
            let platform = session.detection?.platform ?? device.effectivePlatform
            FrontPanelView(model: session.detection?.model ?? device.detected?.model ?? "",
                           vendor: platform.map { $0 == .unknown ? "" : $0.vendor } ?? "", hostname: device.name,
                           ports: Self.skeletonPorts, skeleton: true, showsCables: false)
        }
    }

    private var note: String? {
        if isForeign { return nil }
        if lastKnown != nil { return nil }
        if session.snapshot != nil {
            return t("The panel fills in when reading finishes. The last known state is hidden because it is older than a day.")
        }
        return isConnecting ? t("The panel fills in when reading finishes.") : t("The panel fills in after the first successful read.")
    }

    /// Port outlines only: 48 copper mouths and 4 empty cages, nothing lit.
    static let skeletonPorts: [PanelPort] = PanelBuilder.arrange((0..<48).map {
        var p = PanelPort(slotKey: "0/0/\($0)", name: "ge-0/0/\($0)", kind: .copper, index: $0, look: .down, vlanBars: [])
        p.label = String($0)
        return p
    } + (0..<4).map {
        var p = PanelPort(slotKey: "0/2/\($0)", name: "xe-0/2/\($0)", kind: .sfp, index: $0, look: .empty, vlanBars: [])
        p.label = String($0)
        return p
    }, junos: JunosModel("EX4300-48T"))
}

/// A faint light band crossing the skeleton while connecting. Only shown while the board is in the
/// connecting state and Reduce Motion is off.
private struct Sheen: View {
    @State private var x: CGFloat = -0.35
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.09), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.22)
                .offset(x: x * g.size.width)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .onAppear { withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) { x = 1.1 } }
    }
}

// MARK: - Connecting progress (§3.12, §4.12)

private struct ConnectingProgress: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession

    struct Step {
        var title: String
        var sub: String
        var lower: Double
        var upper: Double
    }

    private var fraction: Double {
        if case let .connecting(_, f) = session.phase { return min(max(f, 0), 1) }
        return 0
    }
    private var liveTitle: String {
        if case let .connecting(step, _) = session.phase { return step }
        return ""
    }

    /// The UI's steps over the session's progress fractions (open → login → 8 read steps).
    private var steps: [Step] {
        let p = session.profile
        let first: Step
        switch p.connection {
        case let .serial(path, baud):
            first = Step(title: t("Connected to the serial port"), sub: "\(path) · " + t("%@ baud", String(baud)), lower: 0, upper: 0.05)
        case let .ssh(host, port):
            first = Step(title: t("Connected to the device"), sub: "\(p.username)@\(host)" + (port == 22 ? "" : ":\(port)"), lower: 0, upper: 0.05)
        case let .api(url):
            first = Step(title: t("Connected to the device"), sub: url, lower: 0, upper: 0.05)
        }
        let det = session.detection ?? device.detected
        let login = [p.username, det?.osVersion.map { "\((det?.platform ?? .juniperJunos).osName) \($0)" }, det?.model].compactMap { $0 }
        let configSub = fraction >= 0.1 && fraction < 0.2125 ? "show version" : "show configuration | display set"
        return [
            first,
            Step(title: t("Logged in"), sub: login.joined(separator: " · "), lower: 0.05, upper: 0.1),
            Step(title: t("Reading the configuration"), sub: configSub, lower: 0.1, upper: 0.325),
            Step(title: t("Ports"), sub: t("Link state and speeds"), lower: 0.325, upper: 0.4375),
            Step(title: t("MAC table"), sub: t("Who is on which port"), lower: 0.4375, upper: 1.0001),
        ]
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                        .font(Typo.percent).tracking(-0.5).foregroundStyle(Theme.text1).monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Reading %@", device.name)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text1)
                        Text(subline(now: ctx.date)).font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(1).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    if model.canCancelRead(device.id) {
                        Button(t("Cancel")) { model.cancelRead(device.id) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                ProgressBar(fraction: fraction).padding(.top, 14).padding(.bottom, 18)
                let all = steps
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(all.enumerated()), id: \.offset) { i, step in
                        stepRow(step, last: i == all.count - 1, now: ctx.date)
                    }
                }
            }
        }
    }

    private func subline(now: Date) -> String {
        let eta = remaining(now: now).map { String(max(1, Int($0.rounded()))) }
        switch session.profile.connection {
        case let .serial(_, baud):
            return eta.map { t("%@ · %@ baud · about %@ s left", t("Serial console"), String(baud), $0) }
                ?? t("%@ · %@ baud", t("Serial console"), String(baud))
        case let .ssh(host, _):
            return eta.map { t("%@ · about %@ s left", "SSH · " + host, $0) } ?? "SSH · " + host
        case let .api(url):
            return url
        }
    }

    private func remaining(now: Date) -> TimeInterval? {
        guard fraction >= 0.1, let start = session.progressMarks.first?.at else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 1 else { return nil }
        return elapsed / fraction * (1 - fraction)
    }

    private enum StepState { case done, running, queued }

    private func state(_ s: Step) -> StepState {
        if fraction >= s.upper { return .done }
        if fraction >= s.lower { return .running }
        return .queued
    }

    /// When the progress first reached `fraction`, from the session's marks.
    private func reached(_ f: Double) -> Date? { session.progressMarks.first { $0.fraction >= f - 0.0001 }?.at }

    private func time(_ s: Step, _ st: StepState, now: Date) -> String {
        switch st {
        case .queued: return ""
        case .done:
            guard let a = reached(s.lower), let b = reached(s.upper) else { return "" }
            return Self.seconds(b.timeIntervalSince(a))
        case .running:
            guard let a = reached(s.lower) else { return "" }
            return t("%@ s", String(max(0, Int(now.timeIntervalSince(a)))))
        }
    }

    static func seconds(_ d: TimeInterval) -> String {
        let value = d < 10 ? d.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))
                           : String(Int(d.rounded()))
        return t("%@ s", value)
    }

    private func stepRow(_ s: Step, last: Bool, now: Date) -> some View {
        let st = state(s)
        return HStack(alignment: .top, spacing: 14) {
            StepCircle(state: st == .done ? .done : (st == .running ? .running : .queued))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 13, weight: st == .queued ? .medium : .semibold))
                    .foregroundStyle(st == .queued ? Theme.text3 : Theme.text1)
                Text(st == .running && s.lower >= 0.4375 && !liveTitle.isEmpty ? liveTitle : s.sub)
                    .font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(1)
                if st == .running && s.lower >= 0.1 {
                    ProgressBar(fraction: (fraction - s.lower) / (s.upper - s.lower)).frame(width: 320).padding(.top, 6)
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 8)
            Text(time(s, st, now: now)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text3).padding(.top, 3)
        }
        .padding(.bottom, last ? 0 : 12)
        .background(alignment: .topLeading) {
            // Rail to the next step: green under finished steps (§4.12).
            if !last {
                RoundedRectangle(cornerRadius: 1).fill(st == .done ? Theme.good.opacity(0.5) : Theme.border)
                    .frame(width: 2).padding(.top, 26).padding(.bottom, 2).padding(.leading, 11)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// §4.12 progress step circle.
struct StepCircle: View {
    enum State { case done, running, queued, failed }
    var state: State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var spin = false

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Theme.good)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            case .failed:
                Circle().fill(Theme.danger)
                Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
            case .queued:
                Circle().fill(Theme.surface)
                Circle().strokeBorder(Theme.borderStrong, lineWidth: 2)
            case .running:
                Circle().fill(Theme.surface)
                Circle().strokeBorder(Theme.accentSoft, lineWidth: 2)
                Circle().trim(from: 0, to: 0.25).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(1)
                    .rotationEffect(.degrees(spin ? 380 : 20))
                    .onAppear {
                        guard !reduceMotion, !RenderMode.active else { return }
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
            }
        }
        .frame(width: 24, height: 24)
    }
}

struct ProgressBar: View {
    var fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface3)
                Capsule().fill(Theme.accent).frame(width: max(6, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Right column boxes

private struct InfoBox: View {
    var title: String
    var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typo.bodyStrong).foregroundStyle(Theme.text1)
            Text(text).font(Typo.callout).foregroundStyle(Theme.text2).lineSpacing(2.5).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

struct ReadOnlyBox: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield").font(.system(size: 13, weight: .semibold))
                Text(t("Read only")).font(Typo.bodyStrong)
            }
            .foregroundStyle(Theme.goodInk)
            Text(t("Nothing on the switch changes while connecting. Changes are only sent after you review and confirm them."))
                .font(Typo.callout).foregroundStyle(Theme.text2).lineSpacing(2.5).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.goodSoft))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.goodLine, lineWidth: 1))
    }
}

/// How Netdeck reaches the device: type, port or address, speed, user, last read.
struct ConnectionFacts: View {
    var device: DeviceProfile
    var session: DeviceSession

    var body: some View {
        let p = session.profile
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: p.connection.type == .serial ? "powerplug" : "terminal").font(.system(size: 12, weight: .medium))
                Text(p.connection.type == .serial ? t("Serial console") : (p.connection.type == .ssh ? t("SSH") : t("API (HTTPS)")))
                    .font(Typo.bodyStrong)
            }
            .foregroundStyle(Theme.text1).padding(.bottom, 6)
            switch p.connection {
            case let .serial(path, baud):
                fact(t("Port"), (path as NSString).lastPathComponent, mono: true)
                fact(t("Speed (baud)"), String(baud))
            case let .ssh(host, port):
                fact(t("Address"), port == 22 ? host : "\(host):\(port)", mono: true)
            case let .api(url):
                fact(t("Address"), url, mono: true)
            }
            fact(t("Username"), p.username, mono: true)
            fact(t("Last read"), (session.snapshot?.takenAt ?? session.detectedAt).map(Format.relativeDay) ?? "—", last: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func fact(_ label: String, _ value: String, mono: Bool = false, last: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label).font(Typo.callout).foregroundStyle(Theme.text3)
            Spacer(minLength: 8)
            Text(value).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text1).lineLimit(1).truncationMode(.middle)
        }
        .frame(height: 30)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.border).frame(height: 1) } }
    }
}

// MARK: - Error cards (§3.13)

/// Words of one error card (§3.13), shared by the device screen's cards and the compact card of
/// the Add device sheet.
struct FailureCopy {
    enum Tone { case danger, warn, neutral }
    var symbol: String
    var tone: Tone
    var title: String
    var text: String
    var tag: String
    /// Device output, never translated (`Login incorrect`).
    var raw: String?
    var checklist: [String] = []

    init(symbol: String, tone: Tone, title: String, text: String, tag: String, raw: String? = nil, checklist: [String] = []) {
        self.symbol = symbol
        self.tone = tone
        self.title = title
        self.text = text
        self.tag = tag
        self.raw = raw
        self.checklist = checklist
    }

    init(_ failure: ConnectionFailure, profile p: DeviceProfile) {
        let target: String = {
            if case let .ssh(host, port) = p.connection { return port == 22 ? host : "\(host):\(port)" }
            if case let .api(url) = p.connection { return URL(string: url)?.host ?? url }
            return p.name
        }()
        switch failure {
        case .wrongPassword:
            self.init(symbol: "key", tone: .danger, title: t("The switch didn't accept the password"),
                      text: t("The saved password for \"%@\" was rejected. It may have changed on the switch. Netdeck doesn't retry on its own, to avoid a lockout.", p.username),
                      tag: t("Wrong password"),
                      raw: p.connection.type == .ssh ? "Permission denied" : (p.connection.type == .api ? "401 Unauthorized" : "Login incorrect"))
        case let .cableNotFound(path):
            self.init(symbol: "powerplug", tone: .warn, title: t("Serial cable not found"),
                      text: t("%@ isn't visible right now. The USB serial adapter may be unplugged or on another port.", path),
                      tag: t("Cable not plugged in"),
                      checklist: [t("Make sure the adapter is plugged into the Mac."),
                                  t("The other end goes into the CON port on the back of the switch."),
                                  t("The port list refreshes on its own once it is plugged in.")])
        case let .portBusy(path):
            self.init(symbol: "terminal", tone: .warn, title: t("The port is open in another app (screen, minicom)"),
                      text: t("%@ is held by another app. Close screen, minicom or any other terminal using it, then try again.", path),
                      tag: t("Port busy"),
                      checklist: [t("Quit screen or minicom, or close the terminal window that uses the cable."),
                                  t("Only one app at a time can talk to a serial console.")])
        case let .notResponding(seconds):
            if case let .serial(_, baud) = p.connection {
                self.init(symbol: "timer", tone: .neutral, title: t("The switch isn't responding"),
                          text: t("The port opened but no prompt came for %@ seconds. The switch may be booting (an EX4300 takes a few minutes) or the speed (baud) is wrong.", String(seconds)),
                          tag: t("No response"),
                          checklist: [t("Is the SYS light on the front of the switch green?"),
                                      baud == 9600 ? t("The speed should be 9600 (the Junos default).")
                                                   : t("The speed is %@ now; the Junos default is 9600.", String(baud))])
            } else {
                self.init(symbol: "timer", tone: .neutral, title: t("The switch isn't responding"),
                          text: t("The connection opened but no prompt came for %@ seconds. The device may still be starting up.", String(seconds)),
                          tag: t("No response"))
            }
        case let .sshUnreachable(detail):
            self.init(symbol: "network.slash", tone: .neutral, title: t("SSH: the address can't be reached"),
                      text: t("Netdeck couldn't reach %@. Check that the device is on, the address is right and this Mac is on the same network.", target),
                      tag: t("Unreachable"), raw: Self.lastLine(detail))
        case let .hostKeyChanged(detail):
            self.init(symbol: "lock.open.trianglebadge.exclamationmark", tone: .danger, title: t("SSH: the host key changed"),
                      text: t("%@ presented a different key than last time. That happens after a reinstall, but it can also mean someone is in between. Netdeck won't connect until the old key is removed from its known hosts file.", target),
                      tag: t("Host key changed"), raw: Self.lastLine(detail))
        case let .apiUnreachable(detail):
            self.init(symbol: "network.slash", tone: .neutral, title: t("HTTPS: the address can't be reached"),
                      text: t("Netdeck couldn't reach %@. Check that the device is on, the address and port are right (Synology uses 5001) and this Mac is on the same network.", target),
                      tag: t("Unreachable"), raw: Self.lastLine(detail))
        case let .certificateChanged(host):
            self.init(symbol: "lock.open.trianglebadge.exclamationmark", tone: .danger, title: t("HTTPS: the certificate changed"),
                      text: t("%@ presented a different security certificate than last time. That happens after a reset or a certificate renewal, but it can also mean someone is in between. Trust the new certificate only if you know why it changed.", host),
                      tag: t("Certificate changed"))
        case let .droppedWhileReading(detail):
            self.init(symbol: "bolt.slash", tone: .neutral, title: t("The connection dropped while reading"),
                      text: t("The device stopped answering in the middle of the read. Nothing was changed on it. Check the cable or the network and try again."),
                      tag: t("Connection dropped"), raw: Self.lastLine(detail))
        case let .other(message):
            self.init(symbol: "exclamationmark.triangle", tone: .danger, title: t("Couldn't connect"), text: message, tag: "")
        }
    }
}

extension FailureCopy {
    /// The last non-empty line of device output (`ssh: connect to host … timed out`).
    nonisolated static func lastLine(_ detail: String) -> String {
        detail.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? detail
    }
}

/// Tile, title, explanation and the small tag of one error card.
private struct ErrorHead: View {
    typealias Tone = FailureCopy.Tone
    var symbol: String
    var tone: Tone
    var title: String
    var text: String
    var tag: String
    /// Smaller tile and title, for the card inside the Add device sheet.
    var compact = false

    init(symbol: String, tone: Tone, title: String, text: String, tag: String, compact: Bool = false) {
        self.symbol = symbol
        self.tone = tone
        self.title = title
        self.text = text
        self.tag = tag
        self.compact = compact
    }

    init(_ copy: FailureCopy, compact: Bool = false) {
        self.init(symbol: copy.symbol, tone: copy.tone, title: copy.title, text: copy.text, tag: copy.tag, compact: compact)
    }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 14 : 14) {
            RoundedRectangle(cornerRadius: compact ? 11 : 13, style: .continuous).fill(fill).frame(width: compact ? 40 : 44, height: compact ? 40 : 44)
                .overlay(Image(systemName: symbol).font(.system(size: compact ? 17 : 19, weight: .medium)).foregroundStyle(ink))
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: compact ? 13.5 : 16, weight: .semibold)).tracking(compact ? 0 : -0.15).foregroundStyle(Theme.text1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Text(tag).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Text(text).font(compact ? Typo.caption : Typo.callout).foregroundStyle(Theme.text2).lineSpacing(compact ? 1.5 : 2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Error cards keep one readable column; tag, text, fields and buttons share its right edge.
    static let maxWidth: CGFloat = 720

    private var fill: Color {
        switch tone { case .danger: return Theme.dangerSoft; case .warn: return Theme.warnSoft; case .neutral: return Theme.surface3 }
    }
    private var ink: Color {
        switch tone { case .danger: return Theme.dangerInk; case .warn: return Theme.warnInk; case .neutral: return Theme.text2 }
    }
}

/// Raw device output, never translated (`Login incorrect`).
private struct RawLine: View {
    var text: String
    var lines = 1
    var body: some View {
        Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text3)
            .lineLimit(lines).truncationMode(.tail)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .textSelection(.enabled)
    }
}

private struct Checklist: View {
    var items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 9) {
                    Text(String(i + 1)).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.text2)
                        .frame(width: 18, height: 18).background(Circle().fill(Theme.surface3))
                    Text(item).font(Typo.callout).foregroundStyle(Theme.text2)
                }
            }
        }
    }
}

private struct ErrorCard: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession
    var failure: ConnectionFailure

    @State private var password = ""
    @State private var saveError: String?
    @State private var editingUser = false
    @State private var userDraft = ""
    @State private var ports: [String] = SerialTransport.availablePorts()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
            actions.padding(.top, 6)
        }
        .frame(maxWidth: ErrorHead.maxWidth, alignment: .leading)
    }

    // MARK: Content per failure

    @ViewBuilder
    private var content: some View {
        let copy = FailureCopy(failure, profile: session.profile)
        ErrorHead(copy)
        if let raw = copy.raw { RawLine(text: raw) }
        switch failure {
        case .wrongPassword:
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: t("New password"))
                HStack(spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
                    SecureField("", text: $password).textFieldStyle(.plain).font(Typo.body)
                        .onSubmit(saveAndConnect)
                    Text(t("Saved to the Keychain")).font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 10).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.accent.opacity(0.22), lineWidth: 3).padding(-1.5))
                if let saveError { Text(saveError).font(Typo.caption).foregroundStyle(Theme.dangerInk) }
            }
        case .cableNotFound:
            HStack(alignment: .center, spacing: 20) {
                Checklist(items: copy.checklist).layoutPriority(1)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                RearPanelView(hostname: device.name, psuPresent: [true, false], consoleConnected: false, selected: .con)
                rearCaption
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .task { await watchPorts() }
        default:
            if !copy.checklist.isEmpty { Checklist(items: copy.checklist) }
        }
    }

    private var rearCaption: some View {
        let full = t("Rear panel · the cable goes into the CON port")
        var a = AttributedString(full)
        if let r = a.range(of: "CON") {
            a[r].font = .system(size: 12, weight: .bold)
            a[r].foregroundColor = Theme.text1
        }
        return Text(a).font(Typo.caption).foregroundStyle(Theme.text3)
    }

    static func lastLine(_ detail: String) -> String { FailureCopy.lastLine(detail) }

    // MARK: Actions per failure

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch failure {
            case .wrongPassword:
                Button(t("Change user")) { userDraft = session.profile.username; editingUser = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .popover(isPresented: $editingUser, arrowEdge: .top) { userPopover }
                Spacer()
                Button(t("Save and connect"), action: saveAndConnect).buttonStyle(PrimaryButtonStyle())
                    .disabled(password.isEmpty).keyboardShortcut(.defaultAction)
            case .cableNotFound:
                portPicker
                Button { ports = SerialTransport.availablePorts() } label: { Label(t("Rescan"), systemImage: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle())
            case .notResponding:
                if case let .serial(path, baud) = session.profile.connection {
                    NDMenu {
                        ForEach([9600, 19200, 38400, 57600, 115200], id: \.self) { b in
                            Button { session.updateConnection(.serial(path: path, baud: b)) } label: {
                                if b == baud { Label(t("%@ baud", String(b)), systemImage: "checkmark") } else { Text(t("%@ baud", String(b))) }
                            }
                        }
                    } label: {
                        Text(t("Change speed")).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text1)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
                    }
                }
                Spacer()
                tryAgain
            case .certificateChanged:
                Spacer()
                Button(t("Trust the new certificate")) {
                    if case let .api(url) = session.profile.connection { APIPins.forget(url: url) }
                    model.connect(device.id)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(session.isBusy)
            default:
                Spacer()
                tryAgain
            }
        }
    }

    private var tryAgain: some View {
        Button { model.connect(device.id) } label: { Label(t("Try again"), systemImage: "arrow.clockwise") }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(session.isBusy || model.isSample(device.id))
    }

    private var portPicker: some View {
        let current = session.profile.serialPath
        let visible = current.map { ports.contains($0) } ?? false
        return NDMenu {
            if ports.isEmpty { Text(t("No serial adapters found")) }
            ForEach(ports, id: \.self) { path in
                Button((path as NSString).lastPathComponent) {
                    if case let .serial(_, baud) = session.profile.connection { session.updateConnection(.serial(path: path, baud: baud)) }
                }
            }
        } label: {
            PickerField(icon: "powerplug", text: visible ? ((current ?? "") as NSString).lastPathComponent : t("Choose port"),
                        placeholder: !visible, mono: visible)
                .frame(height: 32)
        }
    }

    private var userPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(text: t("Username"))
            NDTextField(placeholder: "root", text: $userDraft, mono: true).frame(width: 220)
            HStack {
                Spacer()
                Button(t("Cancel")) { editingUser = false }.buttonStyle(SecondaryButtonStyle())
                Button(t("Save")) {
                    session.updateConnection(username: userDraft)
                    editingUser = false
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(userDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func saveAndConnect() {
        guard !password.isEmpty else { return }
        do {
            try model.saveAndConnect(device.id, password: password)
            saveError = nil
            password = ""
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Lists /dev/cu.* every two seconds while the card is visible. Only a directory listing:
    /// no port is ever opened here.
    private func watchPorts() async {
        while !Task.isCancelled {
            let now = SerialTransport.availablePorts()
            if now != ports { ports = now }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// The error card of §3.13 in compact form, for the Add device sheet: tile, title, text, the raw
/// device line and the checklist. Fixing happens in the form above it; "Test connection" retries.
struct CompactFailureCard: View {
    var failure: ConnectionFailure
    var profile: DeviceProfile

    var body: some View {
        let copy = FailureCopy(failure, profile: profile)
        VStack(alignment: .leading, spacing: 10) {
            ErrorHead(copy, compact: true)
            if copy.raw != nil || !copy.checklist.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if let raw = copy.raw { RawLine(text: raw) }
                    if !copy.checklist.isEmpty { Checklist(items: copy.checklist) }
                }
                .padding(.leading, 54)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(line, lineWidth: 1))
    }

    private var fill: Color {
        switch FailureCopy(failure, profile: profile).tone {
        case .danger: return Theme.dangerSoft.opacity(0.6)
        case .warn: return Theme.warnSoft.opacity(0.7)
        case .neutral: return Theme.surface2
        }
    }
    private var line: Color {
        switch FailureCopy(failure, profile: profile).tone {
        case .danger: return Theme.dangerLine
        case .warn: return Theme.warnLine
        case .neutral: return Theme.border
        }
    }
}

// MARK: - Foreign candidate changes (§3.13 card 3, §6.5)

private struct ForeignChangesCard: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession
    var diff: String
    @State private var showDiff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ErrorHead(symbol: "exclamationmark.triangle", tone: .warn, title: t("The switch has uncommitted changes"),
                      text: t("Another session is editing the configuration and hasn't committed. Netdeck won't write over someone else's work. Until you decide, it only reads and applying stays off."),
                      tag: t("Switch busy"))
            if showDiff {
                DiffCodeView(lines: DiffLine.parse(compare: diff))
                    .frame(height: min(CGFloat(DiffLine.parse(compare: diff).count) * 20 + 22, 220))
            } else {
                RawLine(text: firstLines, lines: 2)
            }
            HStack(spacing: 8) {
                Button { showDiff.toggle() } label: { Label(t("Show diff"), systemImage: "arrow.left.arrow.right") }
                    .buttonStyle(SecondaryButtonStyle())
                Button(t("Discard these changes…")) { model.sheet = .discardForeign(deviceID: device.id) }
                    .buttonStyle(DangerButtonStyle())
                Spacer()
                Button(t("Continue read-only")) { model.readOnlyAcknowledged[device.id] = diff }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: ErrorHead.maxWidth, alignment: .leading)
    }

    private var firstLines: String {
        diff.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(2).joined(separator: "\n")
    }
}

// MARK: - Not connected yet

private struct IdleCard: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ErrorHead(symbol: "powerplug", tone: .neutral, title: t("Not connected"),
                      text: t("Netdeck reads %@ when you connect: ports, VLANs, connected devices and history. Nothing on the device changes while reading.", device.name),
                      tag: "")
            HStack {
                Spacer()
                Button { model.connect(device.id) } label: { Label(t("Connect and read"), systemImage: "arrow.clockwise") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(session.isBusy)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: ErrorHead.maxWidth, alignment: .leading)
    }
}
