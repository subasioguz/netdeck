import AppKit
import NetdeckCore
import SwiftUI

/// What the review sheet is reviewing. Every write to a device starts here (§10.14).
enum ReviewMode: Equatable {
    /// Staged edits → `commit confirmed`.
    case changes
    /// Going back to an older commit → `rollback N` + `commit confirmed`.
    case rollback(index: Int)
    /// Throwing away someone else's uncommitted candidate (`rollback 0` in configuration mode).
    case discardForeign
}

/// Review changes (§3.8). The only place an Apply can start.
struct ReviewSheet: View {
    var session: DeviceSession
    var isSample: Bool
    var mode: ReviewMode
    @State var timer: Int
    @State var showDetails: Bool
    @State private var detailsTab = 0
    @State private var note = ""
    @State private var checking = false
    @State private var applying = false
    @Environment(\.dismiss) private var dismiss

    init(session: DeviceSession, isSample: Bool, timer: Int, showDetails: Bool = false, mode: ReviewMode = .changes) {
        self.session = session
        self.isSample = isSample
        self.mode = mode
        _timer = State(initialValue: timer)
        _showDetails = State(initialValue: showDetails)
    }

    private var plan: ChangePlan { session.plan }

    enum CheckState { case ok, running, failed, skipped, later }

    private var foreignState: CheckState {
        if session.foreignCandidateDiff != nil { return .failed }
        if isSample || session.isOffline { return .skipped }
        return checking ? .running : (session.preview == nil ? .running : .ok)
    }
    private var commitCheckState: CheckState {
        if isSample || session.isOffline { return .skipped }
        if checking || session.preview == nil { return .running }
        return session.preview?.checkPassed == true ? .ok : .failed
    }
    private var canApply: Bool {
        !isSample && !session.isOffline && !plan.isEmpty && session.pending == nil && !applying
            && foreignState == .ok && commitCheckState == .ok && plan.changes.allSatisfy { $0.warnings.isEmpty }
    }

    var body: some View {
        switch mode {
        case .changes: changesBody
        case let .rollback(index):
            RollbackReview(session: session, isSample: isSample, index: index, timer: $timer, showDetails: $showDetails)
        case .discardForeign:
            DiscardForeignReview(session: session, isSample: isSample)
        }
    }

    private var changesBody: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            Rectangle().fill(Theme.border).frame(height: 1)
            NDScroll {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        MicroHeading(text: t("What will change"))
                        ForEach(plan.changes) { c in ChangeRow(change: c) { remove(c) } }
                    }
                    HStack(alignment: .top, spacing: 12) { timerBox; checksBox }
                        .fixedSize(horizontal: false, vertical: true)
                    details
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) { FieldLabel(text: t("Note")); Text(t("written to the switch history")).font(Typo.caption).foregroundStyle(Theme.text3) }
                        NDTextField(placeholder: plan.changes.first.map { $0.subject } ?? "", text: $note)
                    }
                }
                .padding(24)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            footer.padding(.horizontal, 24).frame(height: 64)
        }
        .frame(width: 800)
        .frame(maxHeight: 862)
        .background(Theme.surface)
        .task {
            guard !isSample, !session.isOffline else { return }
            checking = true
            await session.runPreview()
            checking = false
        }
    }

    private var header: some View {
        ReviewSheetHeader(icon: "checkmark.shield", title: t("Review changes"),
                          subtitle: Format.plural(plan.changes.count,
                                                  t("%@ · %@ change · compared with the current switch config (%@)", session.profile.name, "1",
                                                    session.snapshot.map { Format.time($0.takenAt) } ?? "—"),
                                                  t("%@ · %@ changes · compared with the current switch config (%@)", session.profile.name, String(plan.changes.count),
                                                    session.snapshot.map { Format.time($0.takenAt) } ?? "—")),
                          isSample: isSample)
    }

    private var timerBox: some View { SafetyTimerBox(timer: $timer) }

    private var checksBox: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) { Image(systemName: "checkmark.shield"); Text(t("Before applying")) }.font(Typo.bodyStrong).foregroundStyle(Theme.text1)
            check(.ok, t("The current config will be backed up"))
            check(foreignState, foreignState == .failed ? t("Someone else has uncommitted changes on the switch") : t("No one else has uncommitted changes on the switch"))
            check(commitCheckState, commitCheckState == .failed ? t("The switch didn't accept the commands") : t("Syntax check passed (commit check)"))
            if isSample {
                Text(t("This is a sample switch. Nothing is sent; Apply is turned off.")).font(Typo.caption).foregroundStyle(Theme.accentInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
    }

    private func check(_ state: CheckState, _ text: String) -> some View { ReviewCheck(state: state, text: text) }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.2)) { showDetails.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(showDetails ? 0 : -90))
                    Text(t("Technical details")).font(Typo.bodyStrong)
                }
                .foregroundStyle(Theme.text1).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showDetails {
                let code = detailsTab == 0 ? plan.commands.joined(separator: "\n") : (session.preview?.diff ?? "")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Segmented(options: [(0, t("Junos commands") + " \(plan.commands.count)", nil), (1, t("Switch diff"), nil)], selection: $detailsTab, compact: true)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        } label: { Label(t("Copy"), systemImage: "doc.on.doc") }
                            .buttonStyle(PlainLinkStyle())
                    }
                    Text(code.isEmpty ? "—" : code)   // device text, never translated
                        .font(Typo.mono).foregroundStyle(Theme.text1).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface2))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(t("Esc to close · your changes are kept")).font(Typo.caption).foregroundStyle(Theme.text3)
            Spacer()
            Button(t("Cancel")) { dismiss() }.buttonStyle(SecondaryButtonStyle(large: true)).keyboardShortcut(.cancelAction)
            Button {
                applying = true
                Task {
                    await session.apply(confirmMinutes: timer, note: note)
                    applying = false
                    if session.pending != nil { dismiss() }
                }
            } label: {
                HStack(spacing: 7) {
                    if applying { ProgressView().controlSize(.small) } else { Image(systemName: "paperplane") }
                    Text(t("Apply · %@ min trial", String(timer)))
                }
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
            .disabled(!canApply)
        }
    }

    private func remove(_ change: PlannedChange) {
        if change.kind == .port { session.unstage(port: change.subject); return }
        if let i = session.vlanEdits.firstIndex(where: { VLANEditName($0) == change.subject }) { session.unstageVLAN(at: i) }
    }
}

private func VLANEditName(_ e: VLANEdit) -> String {
    switch e {
    case let .add(name, _, _), let .update(name, _, _), let .delete(name): return name
    case let .rename(_, to): return to
    }
}

/// One change in plain words: port pill, before → after, notes (§3.8).
struct ChangeRow: View {
    var change: PlannedChange
    var onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 5) {
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                Text(change.subject).font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(Theme.primary))
            .fixedSize()
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in line(part) }
                ForEach(change.warnings, id: \.self) { w in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                        Text(w).foregroundStyle(Theme.warnInk)
                    }
                    .font(Typo.caption)
                }
            }
            Spacer(minLength: 8)
            Button(action: onRemove) { Label(t("Remove"), systemImage: "xmark") }.buttonStyle(PlainLinkStyle(color: Theme.text3))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var parts: [String] { change.summary.components(separatedBy: " · ") }

    /// "description: OLD → NEW" becomes label, struck old value and bold new value.
    @ViewBuilder
    private func line(_ part: String) -> some View {
        if let colon = part.range(of: ": "), let arrow = part.range(of: " → ", range: colon.upperBound..<part.endIndex) {
            let label = String(part[..<colon.lowerBound])
            let old = String(part[colon.upperBound..<arrow.lowerBound]), new = String(part[arrow.upperBound...])
            HStack(spacing: 6) {
                Text(label.prefix(1).uppercased() + label.dropFirst()).font(Typo.bodyStrong).foregroundStyle(Theme.text1)
                Text(old).strikethrough().foregroundStyle(Theme.text3).lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
                Text(new).font(Typo.bodyStrong).foregroundStyle(Theme.text1).lineLimit(1)
            }
            .font(Typo.body)
        } else {
            Text(part.prefix(1).uppercased() + part.dropFirst()).font(Typo.bodyStrong).foregroundStyle(Theme.text1)
        }
    }
}

// MARK: - Shared pieces of the review sheets

/// 40 pt black icon tile, title and one-line subtitle.
struct ReviewSheetHeader: View {
    var icon: String
    var title: String
    var subtitle: String
    var isSample: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.primary).frame(width: 40, height: 40)
                .overlay(Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.onPrimary))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.sheetTitle).foregroundStyle(Theme.text1)
                Text(subtitle).font(Typo.callout).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer()
            if isSample { Pill(text: t("Sample switch"), kind: .accent, icon: "eye") }
        }
    }
}

/// Safety timer box: 3 / 5 / 10 minute segments and what the trial means.
struct SafetyTimerBox: View {
    @Binding var timer: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) { Image(systemName: "timer"); Text(t("Safety timer")) }.font(Typo.bodyStrong).foregroundStyle(Theme.text1)
            Segmented(options: [3, 5, 10].map { ($0, t("%@ min", String($0)), nil) }, selection: $timer)
            Text(t("The changes run as a %@-minute trial. If you don't confirm, the switch rolls back on its own, even if you lose the connection.", String(timer)))
                .font(Typo.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
    }
}

/// One line of the "Before applying" box.
struct ReviewCheck: View {
    var state: ReviewSheet.CheckState
    var text: String
    var note: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch state {
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                case .skipped: Image(systemName: "minus.circle").foregroundStyle(Theme.text4)
                case .later: Image(systemName: "clock").foregroundStyle(Theme.accent)
                case .running: ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(Typo.body).foregroundStyle(state == .skipped ? Theme.text3 : Theme.text1).lineLimit(2)
                if let note { Text(note).font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(2) }
            }
        }
    }
}
