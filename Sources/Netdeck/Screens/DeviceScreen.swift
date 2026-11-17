import NetdeckCore
import SwiftUI

struct DeviceScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var device: DeviceProfile
    var session: DeviceSession
    var section: DeviceSection

    /// What the main area shows: a section, or the connection board that stands in for all of them.
    private enum Content { case basic, appliance(ApplianceSnapshot), history, board(ConnectionBoard.Mode), section }

    private var content: Content {
        if model.isAppliance(device.id) {
            switch session.phase {
            case .connecting: return .board(.connecting)
            case .failed: return .board(.failed(session.failure ?? .other(session.lastError ?? t("Couldn't connect"))))
            default: return session.appliance.map(Content.appliance) ?? .board(.idle)
            }
        }
        let basic = model.isBasic(device.id)
        if basic {
            return section == .history && (session.detection ?? device.detected)?.platform.exportsConfig == true ? .history : .basic
        }
        switch session.phase {
        case .connecting where !model.isSample(device.id): return .board(.connecting)
        case .failed: return .board(.failed(session.failure ?? .other(session.lastError ?? t("Couldn't connect"))))
        default: break
        }
        if let diff = session.foreignCandidateDiff, model.readOnlyAcknowledged[device.id] != diff, section != .history {
            return .board(.foreign(diff))
        }
        if section == .history { return .history }
        if session.snapshot == nil && !model.isSample(device.id) { return .board(.idle) }
        return .section
    }

    var body: some View {
        let content = self.content
        VStack(spacing: 12) {
            switch (content, section) {
            case (.history, _): HistoryHeader(device: device, session: session)
            case (.section, .vlans) where session.snapshot != nil: VLANsHeader(device: device, session: session)
            case (.section, .connected) where session.snapshot != nil: ConnectedHeader(device: device, session: session)
            default: DeviceHeader(device: device, session: session, isSample: model.isSample(device.id))
            }
            let others = model.waiting.filter { $0.id != device.id }
            if !others.isEmpty { GlobalConfirmationBanner(waiting: others) }
            ForEach(model.trialEnds.filter { $0.device.id != device.id }, id: \.device.id) { e in
                TrialEndBanner(device: e.device, session: e.session, end: e.end, global: true)
            }
            if let p = session.pending {
                DeviceCountdownBanner(session: session, pending: p, deviceID: device.id)
            } else if let end = session.trialEnd {
                TrialEndBanner(device: device, session: session, end: end, global: false)
            }
            Group {
                switch content {
                case .basic: BasicOverviewScreen(device: device, session: session)
                case let .appliance(a): ApplianceScreen(device: device, session: session, appliance: a)
                case .history: HistoryScreen(device: device, session: session)
                case let .board(mode): ConnectionBoard(device: device, session: session, mode: mode)
                case .section:
                    switch section {
                    case .ports:
                        if session.snapshot != nil { PortsScreen(device: device, session: session) } else { SectionPlaceholder(section: section) }
                    case .vlans:
                        if session.snapshot != nil { VLANsScreen(device: device, session: session) } else { SectionPlaceholder(section: section) }
                    case .connected:
                        if session.snapshot != nil { ConnectedScreen(device: device, session: session) } else { SectionPlaceholder(section: section) }
                    case .history: HistoryScreen(device: device, session: session)
                    case .overview:
                        if session.snapshot != nil { PortsScreen(device: device, session: session) } else { SectionPlaceholder(section: section) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            if session.pendingChangeCount > 0 && session.pending == nil {
                StagedChangesBar(session: session, isSample: model.isSample(device.id)) {
                    model.sheet = .review(deviceID: device.id)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.trialEnds.map(\.device.id))
    }
}

// MARK: - Header row (52)

/// Header row of a section with its own title (VLANs, Connected devices): title, outline chip,
/// one-line explanation, and the section's controls on the right.
struct SectionHeader<Trailing: View>: View {
    var title: String
    var chip: String
    var subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(title).font(Typo.title1).tracking(-0.4).foregroundStyle(Theme.text1).lineLimit(1)
                    Pill(text: chip, kind: .outline).monospacedDigit()
                }
                Text(subtitle).font(Typo.callout).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .frame(height: 52)
        .padding(.horizontal, 4)
    }
}

/// "Read again" as used in every section header (⌘R).
struct ReadAgainButton: View {
    var session: DeviceSession
    var body: some View {
        Button { Task { await session.refresh() } } label: {
            Label(t("Read again"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(session.isOffline || session.isBusy)
        .keyboardShortcut("r", modifiers: .command)
    }
}

struct DeviceHeader: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession
    var isSample: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(device.name).font(Typo.title1).tracking(-0.4).foregroundStyle(Theme.text1)
                    DeviceStatusPill(device: device, session: session, isSample: isSample)
                }
                Text(subtitle).font(Typo.callout).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let snap = session.snapshot {
                switch session.phase {
                case .connecting, .failed:
                    Text(t("Last successful read %@", Format.inlineDay(snap.takenAt))).font(Typo.caption).foregroundStyle(Theme.text3).monospacedDigit()
                default:
                    Text(t("Last read %@", Format.time(snap.takenAt))).font(Typo.caption).foregroundStyle(Theme.text3).monospacedDigit()
                }
            }
            if case .failed = session.phase, !isSample {
                Button { model.connect(device.id) } label: { Label(t("Try again"), systemImage: "arrow.clockwise") }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut("r", modifiers: .command)
            } else if !model.isBasic(device.id) {
                Button { model.read(device.id) } label: {
                    Label(t("Read again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isSample || session.isBusy)
                .keyboardShortcut("r", modifiers: .command)
            }
            Menu {
                Button(t("Remove"), role: .destructive) { model.remove(device.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(IconButtonStyle()).fixedSize()
        }
        .frame(height: 52)
        .padding(.horizontal, 4)
    }

    private var subtitle: String {
        if let a = session.appliance {
            return [a.model, a.osVersion, a.serial].compactMap { $0 }.joined(separator: " · ")
        }
        guard let snap = session.snapshot else {
            let det = session.detection ?? device.detected
            if let det, let serial = det.serial { return det.summary + " · " + serial }
            return det?.summary ?? device.kind.title
        }
        var parts = [snap.model]
        if let v = snap.osVersion { parts.append("\(snap.platform.osName) \(v)") }
        if let s = snap.hardware.serial { parts.append(s) }
        return parts.joined(separator: " · ")
    }
}

struct DeviceStatusPill: View {
    var device: DeviceProfile
    var session: DeviceSession?
    var isSample: Bool

    var body: some View {
        if let p = session?.pending {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Pill(text: t("Awaiting confirmation · %@", Format.countdown(p.deadline.timeIntervalSince(ctx.date))), kind: .warn, dot: true)
                    .monospacedDigit()
            }
        } else if isSample {
            Pill(text: t("Sample switch"), kind: .accent, icon: "eye")
        } else {
            switch session?.phase ?? .disconnected {
            case .ready, .working: Pill(text: t("Connected · %@", connectionWord), kind: .good, dot: true)
            case .connecting: Pill(text: t("Connecting · %@", connectionWord), kind: .accent, dot: true)
            case .failed: Pill(text: t("Couldn't connect"), kind: .danger, dot: true)
            case .unsupported: Pill(text: t("Basic support"), kind: .accent)
            case .disconnected: Pill(text: t("Not connected"), kind: .outline, dot: true)
            }
        }
    }

    private var connectionWord: String {
        switch device.connection.type { case .serial: return t("serial console"); case .ssh: return t("SSH"); case .api: return t("API (HTTPS)") }
    }
}

// MARK: - Banners (§3.9)

struct DeviceCountdownBanner: View {
    @Environment(AppModel.self) private var model
    var session: DeviceSession
    var pending: DeviceSession.PendingCommit
    var deviceID: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = pending.deadline.timeIntervalSince(ctx.date)
            let total = pending.deadline.timeIntervalSince(pending.appliedAt)
            let critical = left <= 60
            HStack(spacing: 16) {
                CountdownRing(remaining: left, total: total, size: 72)
                VStack(alignment: .leading, spacing: 6) {
                    confirmTitle(Format.countdown(left), critical: critical)
                    Text(Format.plural(pending.summary.count,
                                       t("%@ change was applied as a %@-minute trial. If everything looks fine, confirm. If you lost the connection, do nothing; the switch rolls back on its own.",
                                         "1", String(Int((total / 60).rounded()))),
                                       t("%@ changes were applied as a %@-minute trial. If everything looks fine, confirm. If you lost the connection, do nothing; the switch rolls back on its own.",
                                         String(pending.summary.count), String(Int((total / 60).rounded())))))
                        .font(Typo.callout).foregroundStyle(Theme.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Pill(text: t("Switch responds"), kind: .good, dot: true)
                        if let up = upPortsText { Pill(text: t("%@ still up", up), kind: .outline) }
                        if let b = session.backups.first { Pill(text: t("Backup taken · %@", Format.time(b.date)), kind: .outline, icon: "externaldrive") }
                    }
                }
                Spacer(minLength: 8)
                Button(t("Roll back now")) { model.rollBack(deviceID) }.buttonStyle(SecondaryButtonStyle(large: true))
                Button { model.confirm(deviceID) } label: { Label(t("Confirm"), systemImage: "checkmark") }
                    .buttonStyle(PrimaryButtonStyle(large: true))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(minHeight: 96)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(critical ? Theme.dangerSoft : Theme.warnSoft))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(critical ? Theme.dangerLine : Theme.warnLine, lineWidth: 1))
        }
    }

    private func confirmTitle(_ time: String, critical: Bool) -> some View {
        // "Confirm within **4:32** or the switch rolls back": the time is emphasized inside the translated sentence.
        let full = t("Confirm within %@ or the switch rolls back", time)
        var attr = AttributedString(full)
        if let r = attr.range(of: time) {
            attr[r].foregroundColor = critical ? Theme.dangerInk : Theme.warnInk
            attr[r].font = Font.system(size: 16, weight: .bold).monospacedDigit()
        }
        return Text(attr).font(Typo.banner).foregroundStyle(Theme.text1)
    }

    private var upPortsText: String? {
        let names = session.snapshot?.ports.filter { $0.linkUp }.map(\.name) ?? []
        guard let first = names.first else { return nil }
        let rest = names.dropFirst().compactMap { $0.split(separator: "/").last.map(String.init) }
        return ([first] + rest).joined(separator: ", ")
    }
}

struct GlobalConfirmationBanner: View {
    @Environment(AppModel.self) private var model
    var waiting: [AppModel.Waiting]

    var body: some View {
        if let first = waiting.first {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = first.pending.deadline.timeIntervalSince(ctx.date)
                let total = first.pending.deadline.timeIntervalSince(first.pending.appliedAt)
                let critical = left <= 60
                HStack(spacing: 12) {
                    CountdownRing(remaining: left, total: total, size: 32, showText: false)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(waiting.count == 1 ? t("%@ is waiting for your confirmation", first.device.name)
                                                    : t("%@ devices are waiting for your confirmation", String(waiting.count)))
                            Text("· " + Format.countdown(left)).foregroundStyle(critical ? Theme.dangerInk : Theme.warnInk).monospacedDigit()
                        }
                        .font(Typo.bodyStrong).foregroundStyle(Theme.text1)
                        Text(t("If you don't confirm, the switch rolls back at %@. Other devices are not affected.", Format.time(first.pending.deadline)))
                            .font(Typo.caption).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if waiting.count == 1 {
                        Button { model.selection = .device(first.id, .ports) } label: {
                            HStack(spacing: 4) { Text(t("Open %@", first.device.name)); Image(systemName: "arrow.right") }
                        }
                        .buttonStyle(PlainLinkStyle(color: Theme.warnInk))
                        Button(t("Roll back now")) { model.rollBack(first.id) }.buttonStyle(SecondaryButtonStyle())
                        Button(t("Confirm")) { model.confirm(first.id) }.buttonStyle(PrimaryButtonStyle())
                    } else {
                        ForEach(waiting) { w in
                            Menu(w.device.name) {
                                Button(t("Open %@", w.device.name)) { model.selection = .device(w.id, .ports) }
                                Button(t("Roll back now")) { model.rollBack(w.id) }
                                Button(t("Confirm")) { model.confirm(w.id) }
                            }
                            .fixedSize()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 56)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(critical ? Theme.dangerSoft : Theme.warnSoft))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(critical ? Theme.dangerLine : Theme.warnLine, lineWidth: 1))
            }
        }
    }
}

/// How a trial ended (§3.9): green "Changes are permanent" for 3 s after Confirm, grey "The switch
/// rolled back" when the timer ran out (until closed). `global` is the 56 pt banner on other screens.
struct TrialEndBanner: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession
    var end: DeviceSession.TrialEnd
    var global: Bool

    var body: some View {
        let confirmed: Bool = { if case .confirmed = end { return true }; return false }()
        HStack(spacing: 12) {
            Circle().fill(confirmed ? Theme.good : Theme.text3).frame(width: 32, height: 32)
                .overlay(Image(systemName: confirmed ? "checkmark" : "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.surface))
            HStack(spacing: 6) {
                if global {
                    Text(device.name).fixedSize()
                    Text("·").foregroundStyle(Theme.text3)
                }
                Text(message).foregroundStyle(global ? Theme.text2 : Theme.text1).lineLimit(1).truncationMode(.tail).help(message)
            }
            .font(Typo.bodyStrong).foregroundStyle(Theme.text1)
            Spacer(minLength: 8)
            if !confirmed {
                if global {
                    Button { model.selection = .device(device.id, .ports) } label: {
                        HStack(spacing: 4) { Text(t("Open %@", device.name)); Image(systemName: "arrow.right") }
                    }
                    .buttonStyle(PlainLinkStyle(color: Theme.text2))
                } else if !session.isOffline {
                    Button { model.read(device.id) } label: { Label(t("Read again"), systemImage: "arrow.clockwise") }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(session.isBusy)
                }
                Button { session.clearTrialEnd() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle()).help(t("Close"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(confirmed ? Theme.goodSoft : Theme.surface3))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(confirmed ? Theme.goodLine : Theme.borderStrong, lineWidth: 1))
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        switch end {
        case .confirmed: return t("Changes are permanent · saved as #0 in the history")
        case let .timedOut(deadline, restaged):
            return restaged > 0 ? t("The switch rolled back (%@). Your changes are staged again.", Format.time(deadline))
                                : t("The confirm timer ran out; the switch went back to its previous configuration.")
        }
    }
}

// MARK: - Staged-changes bar (§4.9)

struct StagedChangesBar: View {
    var session: DeviceSession
    var isSample: Bool
    var onReview: () -> Void
    @State private var confirmDiscard = false

    var body: some View {
        let n = session.pendingChangeCount
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent).frame(width: 28, height: 28)
                .overlay(Text(String(n)).font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text(n == 1 ? t("%@ change staged, not sent to the switch yet", String(n)) : t("%@ changes staged, not sent to the switch yet", String(n)))
                    .font(Typo.bodyStrong).foregroundStyle(Theme.onStagedBar).lineLimit(1)
                Text(isSample ? t("This is a sample switch. Nothing is sent; Apply is turned off.")
                              : t("Nothing changes on the switch until you review and confirm."))
                    .font(Typo.caption).foregroundStyle(Theme.onStagedBar.opacity(0.6)).lineLimit(1)
            }
            .layoutPriority(1)
            ViewThatFits(in: .horizontal) {
                pills(session.plan.changes.prefix(4))
                pills(session.plan.changes.prefix(2))
                Color.clear.frame(width: 0)
            }
            Spacer(minLength: 8)
            Button(t("Discard all")) { confirmDiscard = true }
                .buttonStyle(BarButtonStyle(filled: false))
                .popover(isPresented: $confirmDiscard, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(Format.plural(n, t("Discard %@ staged change? Nothing was sent to the switch.", "1"),
                                           t("Discard %@ staged changes? Nothing was sent to the switch.", String(n)))).font(Typo.body)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button(t("Cancel")) { confirmDiscard = false }.buttonStyle(SecondaryButtonStyle())
                            Button(t("Discard all")) { session.discardStaged(); confirmDiscard = false }
                                .buttonStyle(SecondaryButtonStyle(destructive: true))
                        }
                    }
                    .padding(16).frame(width: 300)
                }
            Button(action: onReview) {
                HStack(spacing: 6) { Text(t("Review changes")); Image(systemName: "arrow.right") }
            }
            .buttonStyle(BarButtonStyle(filled: true))
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.stagedBar))
        .shadow(color: .black.opacity(0.18), radius: 15, y: 10)
    }

    private func pills(_ changes: ArraySlice<PlannedChange>) -> some View {
        HStack(spacing: 6) {
            ForEach(changes) { c in
                HStack(spacing: 5) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text(c.subject).font(.system(size: 11.5, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(Theme.onStagedBar.opacity(0.9))
                .padding(.horizontal, 9).frame(height: 24)
                .background(Capsule().fill(Theme.onStagedBar.opacity(0.08)))
                .fixedSize()
            }
        }
    }
}

struct BarButtonStyle: ButtonStyle {
    var filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(filled ? Theme.stagedBar : Theme.onStagedBar)
            .padding(.horizontal, 14).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(filled ? Theme.onStagedBar : Theme.onStagedBar.opacity(0.08)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}
