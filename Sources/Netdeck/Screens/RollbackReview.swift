import AppKit
import NetdeckCore
import SwiftUI

// Review modes for writes that don't come from staged edits: going back to an older version, and
// discarding someone else's uncommitted changes. Same sheet frame and safety pieces as Review changes.

// MARK: - Go back to a version

struct RollbackReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var session: DeviceSession
    var isSample: Bool
    var index: Int
    @Binding var timer: Int
    @Binding var showDetails: Bool
    @State private var detailsTab = 0
    @State private var fetched: String?
    @State private var going = false

    private var commit: CommitEntry? { session.snapshot?.commits.first { $0.index == index } }

    /// What going back does, as the switch prints it (`show system rollback compare 0 N`).
    /// The sample only has the 2 → 0 capture; #1 → #0 was a confirm without config change.
    private var diffText: String? {
        if isSample {
            if index == 1 { return "" }
            return index == 2 ? Self.flipped(DemoData.sampleDiff) : nil
        }
        return fetched
    }

    private var items: [DiffSummaryItem] {
        guard let diffText else { return [] }
        return DiffSummary.items(ConfigCompare.setDiff(fromCompare: diffText), current: session.snapshot?.config)
    }

    private var foreignState: ReviewSheet.CheckState {
        if session.foreignCandidateDiff != nil { return .failed }
        if isSample || session.isOffline { return .skipped }
        return .later
    }

    private var canApply: Bool {
        !isSample && !session.isOffline && session.pending == nil && !going && !session.isBusy
            && session.foreignCandidateDiff == nil && diffText != nil && commit != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ReviewSheetHeader(icon: "arrow.uturn.backward", title: t("Go back to #%@", String(index)),
                              subtitle: diffText != nil && items.count == 1
                                  ? t("%@ · %@ change · compared with the current switch config (%@)", session.profile.name, "1",
                                      session.snapshot.map { Format.time($0.takenAt) } ?? "—")
                                  : t("%@ · %@ changes · compared with the current switch config (%@)", session.profile.name,
                                      diffText == nil ? "—" : String(items.count), session.snapshot.map { Format.time($0.takenAt) } ?? "—"),
                              isSample: isSample)
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            Rectangle().fill(Theme.border).frame(height: 1)
            NDScroll {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        MicroHeading(text: t("What will change"))
                        whatChanges
                    }
                    HStack(alignment: .top, spacing: 12) {
                        SafetyTimerBox(timer: $timer)
                        checksBox
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    details
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
            // Read-only: asks the switch what going back would change.
            guard !isSample, session.isConnected, !session.isBusy, fetched == nil else { return }
            fetched = await session.compare(rollback: 0, to: index)
        }
    }

    private var whatChanges: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("#\(index)").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.onPrimary)
                    .padding(.horizontal, 9).frame(height: 24).background(Capsule().fill(Theme.primary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit?.comment ?? t("No note")).font(Typo.bodyStrong)
                        .foregroundStyle(commit?.comment == nil ? Theme.text3 : Theme.text1).lineLimit(1)
                    if let c = commit {
                        Text("\(Format.commitDate(c)) · \(c.user) · \(c.client)").font(Typo.caption).foregroundStyle(Theme.text3).monospacedDigit()
                    }
                }
                Spacer()
                Pill(text: t("Back to this version"), kind: .outline, icon: "arrow.uturn.backward")
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            if diffText == nil {
                HStack(spacing: 8) {
                    if !isSample && session.isConnected { ProgressView().controlSize(.small) }
                    Text(isSample ? t("The sample switch only includes the comparison of #2 and #1.")
                                  : (session.isConnected ? t("Asking the switch…") : t("Connect to the switch to compare its versions.")))
                        .font(Typo.callout).foregroundStyle(Theme.text3)
                }
            } else {
                DiffSummaryList(items: items, snapshot: session.snapshot, colors: model.colors(for: session.profile.id))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var checksBox: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) { Image(systemName: "checkmark.shield"); Text(t("Before applying")) }.font(Typo.bodyStrong).foregroundStyle(Theme.text1)
            ReviewCheck(state: .ok, text: t("The current config will be backed up"))
            ReviewCheck(state: foreignState,
                        text: foreignState == .failed ? t("Someone else has uncommitted changes on the switch") : t("No one else has uncommitted changes on the switch"),
                        note: foreignState == .later ? t("Checked right before sending") : nil)
            ReviewCheck(state: commit == nil ? .failed : .ok,
                        text: commit == nil ? t("The switch no longer has version #%@", String(index)) : t("The switch still keeps version #%@", String(index)))
            if isSample {
                Text(t("This is a sample switch. Nothing is sent; Apply is turned off.")).font(Typo.caption).foregroundStyle(Theme.accentInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
    }

    private var commands: String {
        let comment = SetConfigParser.quote("Netdeck: rollback to \(index)")
        return "configure\nrollback \(index)\ncommit confirmed \(timer) comment \(comment)\nexit configuration-mode"
    }

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
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Segmented(options: [(0, t("Junos commands") + " 4", nil), (1, t("Switch diff"), nil)], selection: $detailsTab, compact: true)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(detailsTab == 0 ? commands : (diffText ?? ""), forType: .string)
                        } label: { Label(t("Copy"), systemImage: "doc.on.doc") }
                            .buttonStyle(PlainLinkStyle())
                    }
                    if detailsTab == 0 {
                        Text(commands)   // device text, never translated
                            .font(Typo.mono).foregroundStyle(Theme.text1).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface2))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                    } else {
                        DiffCodeView(lines: DiffLine.parse(compare: diffText ?? ""))
                            .frame(height: min(CGFloat(DiffLine.parse(compare: diffText ?? "").count) * 20 + 22, 320))
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(t("Esc to close · nothing changes until you confirm")).font(Typo.caption).foregroundStyle(Theme.text3)
            Spacer()
            Button(t("Cancel")) { dismiss() }.buttonStyle(SecondaryButtonStyle(large: true)).keyboardShortcut(.cancelAction)
            Button {
                going = true
                Task {
                    await session.rollback(to: index, confirmMinutes: timer)
                    going = false
                    if session.pending != nil { dismiss() }
                }
            } label: {
                HStack(spacing: 7) {
                    if going { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.uturn.backward") }
                    Text(t("Go back · %@ min trial", String(timer)))
                }
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
            .disabled(!canApply)
        }
    }

    /// The sample's 2 → 0 diff seen from the other side (0 → 2): additions become removals.
    static func flipped(_ diff: String) -> String {
        diff.components(separatedBy: "\n").map { line in
            if line.hasPrefix("+") { return "-" + line.dropFirst() }
            if line.hasPrefix("-") { return "+" + line.dropFirst() }
            return line
        }.joined(separator: "\n")
    }
}

// MARK: - Discard someone else's uncommitted changes

struct DiscardForeignReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var session: DeviceSession
    var isSample: Bool
    @State private var discarding = false

    private var diff: String { session.foreignCandidateDiff ?? "" }
    private var items: [DiffSummaryItem] { DiffSummary.items(ConfigCompare.setDiff(fromCompare: diff), current: session.snapshot?.config) }
    private var canDiscard: Bool { !isSample && !session.isOffline && !discarding && !session.isBusy && session.foreignCandidateDiff != nil }

    var body: some View {
        VStack(spacing: 0) {
            ReviewSheetHeader(icon: "trash", title: t("Discard uncommitted changes"),
                              subtitle: t("%@ · changes someone else left on the switch, never committed", session.profile.name), isSample: isSample)
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            Rectangle().fill(Theme.border).frame(height: 1)
            NDScroll {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Theme.warn)
                        Text(t("Another session made these changes and never committed them. Discarding clears that draft on the switch; the running configuration stays as it is. This can't be undone."))
                            .font(Typo.callout).foregroundStyle(Theme.text1).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warnSoft))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warnLine, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 8) {
                        MicroHeading(text: t("What will be discarded"))
                        DiffSummaryList(items: items, snapshot: session.snapshot, colors: model.colors(for: session.profile.id), limit: 6)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        MicroHeading(text: t("Switch diff"))
                        let lines = DiffLine.parse(compare: diff)
                        DiffCodeView(lines: lines).frame(height: min(CGFloat(lines.count) * 20 + 22, 300))
                    }
                    if isSample {
                        Text(t("This is a sample switch. Nothing is sent; Apply is turned off.")).font(Typo.caption).foregroundStyle(Theme.accentInk)
                    }
                }
                .padding(24)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 10) {
                Text(t("Esc to close · nothing changes until you confirm")).font(Typo.caption).foregroundStyle(Theme.text3)
                Spacer()
                Button(t("Cancel")) { dismiss() }.buttonStyle(SecondaryButtonStyle(large: true)).keyboardShortcut(.cancelAction)
                Button {
                    discarding = true
                    Task {
                        await session.discardForeignCandidate()
                        discarding = false
                        if session.foreignCandidateDiff == nil { dismiss() }
                    }
                } label: {
                    HStack(spacing: 7) {
                        if discarding { ProgressView().controlSize(.small) } else { Image(systemName: "trash") }
                        Text(t("Discard changes"))
                    }
                }
                .buttonStyle(DangerFilledButtonStyle())
                .disabled(!canDiscard)
            }
            .padding(.horizontal, 24).frame(height: 64)
        }
        .frame(width: 800)
        .frame(maxHeight: 862)
        .background(Theme.surface)
    }
}

/// Filled red button for the last step of a destructive review.
struct DangerFilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.danger))
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.35)
            .contentShape(Rectangle())
    }
}
