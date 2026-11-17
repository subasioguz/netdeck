import AppKit
import NetdeckCore
import SwiftUI
import UniformTypeIdentifiers

// History & backups (§3.7): the switch's commit history next to Netdeck's local backups,
// a plain-language summary of any comparison, the switch's own diff, and the way back
// (always through the review sheet, never directly).

// MARK: - Data

/// Commits and local backups of one device, as History & backups shows them.
@MainActor
struct HistoryData {
    struct Backup: Identifiable {
        var id: String
        var date: Date
        var reason: String
        var source: BackupStore.Backup?
    }

    let session: DeviceSession
    let isSample: Bool
    let commits: [CommitEntry]
    let backups: [Backup]

    init(session: DeviceSession, isSample: Bool) {
        self.session = session
        self.isSample = isSample
        commits = (session.snapshot?.commits ?? []).filter { !$0.isRescue && $0.index != nil }
        if isSample, let snap = session.snapshot {
            // The sample switch was "read" when it opened; Netdeck backs up on every read.
            backups = [Backup(id: "sample", date: snap.takenAt, reason: "on connect", source: nil)]
        } else {
            backups = session.backups.map { Backup(id: $0.url.lastPathComponent, date: $0.date, reason: $0.reason, source: $0) }
        }
    }

    func commit(_ i: Int) -> CommitEntry? { commits.first { $0.index == i } }
    func backup(_ id: String) -> Backup? { backups.first { $0.id == id } }

    func exists(_ v: HistoryVersion) -> Bool {
        switch v {
        case let .commit(i): return commit(i) != nil
        case let .backup(id): return backup(id) != nil
        }
    }

    /// Full text of a version when Netdeck has it: the current config and its own backups.
    func text(_ v: HistoryVersion) -> String? {
        switch v {
        case .commit(0): return session.snapshot?.configText
        case .commit: return nil
        case let .backup(id):
            guard let b = backup(id) else { return nil }
            if let src = b.source { return session.backupText(src) }
            return session.snapshot?.configText
        }
    }

    /// The newest version that changed something: a plain "confirm" commit points to the one it confirmed.
    var defaultSelection: HistoryVersion? {
        if let first = commits.first, let i = first.index {
            return Self.confirmsPrevious(first, in: commits) ? .commit(i + 1) : .commit(i)
        }
        return backups.first.map { .backup($0.id) }
    }

    /// The compared pair for a selection: a commit against the one before it, a backup against now.
    func pair(for selected: HistoryVersion, state: HistoryViewState) -> (HistoryVersion?, HistoryVersion) {
        switch selected {
        case let .commit(i):
            return (state.base ?? (commit(i + 1) != nil ? .commit(i + 1) : nil), state.target ?? selected)
        case .backup:
            return (state.base ?? selected, state.target ?? (session.snapshot != nil ? .commit(0) : selected))
        }
    }

    /// A plain commit right after a `commit confirmed`: it made the previous one permanent.
    static func confirmsPrevious(_ c: CommitEntry, in commits: [CommitEntry]) -> Bool {
        guard !c.confirmed, let i = c.index, let prev = commits.first(where: { $0.index == i + 1 }), prev.confirmed else { return false }
        guard let a = c.date, let b = prev.date else { return true }
        let gap = a.timeIntervalSince(b)
        return gap >= 0 && gap <= Double((prev.confirmMinutes ?? 10) * 60 + 60)
    }

    /// "The switch clock is about N days behind" (§3.7, §10.10). Only said when it can be shown:
    /// NTP is not configured, and the newest commit is one Netdeck made, so its Mac time is known
    /// (the pending timer, or the backup Netdeck took right after it). The sample switch carries the
    /// offset of the switch it was captured from.
    var clockBehindDays: Int? {
        guard let snap = session.snapshot, !snap.configText.contains("set system ntp ") else { return nil }
        if isSample { return DemoData.sampleClockBehindDays }
        guard let newest = commits.first, newest.index == 0, let switchTime = newest.date,
              newest.comment?.hasPrefix("Netdeck") == true else { return nil }
        let after = ["applied, awaiting confirmation", "rolled back, awaiting confirmation", "confirmed", "reverted"]
        guard let macTime = session.pending?.appliedAt ?? session.backups.first(where: { after.contains($0.reason) })?.date else { return nil }
        let days = Int((macTime.timeIntervalSince(switchTime) / 86_400).rounded())
        return days >= 2 ? days : nil
    }

    // MARK: Labels

    func title(_ v: HistoryVersion) -> String {
        switch v {
        case let .commit(i): return commit(i)?.comment ?? t("No note")
        case .backup: return t("Netdeck backup")
        }
    }

    /// Short label for the compare pickers: "#2 · 2 Sep 2026" / "Netdeck backup · 17 Nov".
    func shortLabel(_ v: HistoryVersion) -> String {
        switch v {
        case let .commit(i):
            guard let c = commit(i) else { return "#\(i)" }
            return "#\(i) · " + (c.date.map { Format.day($0, zone: c.timeZone) } ?? c.timestamp)
        case let .backup(id):
            guard let b = backup(id) else { return t("Netdeck backup") }
            return t("Netdeck backup") + " · " + Format.day(b.date)
        }
    }

    static func backupReason(_ reason: String) -> String {
        switch reason {
        case "on connect": return t("Taken automatically on first read")
        case "before change", "before rollback": return t("Taken automatically before applying")
        case "applied, awaiting confirmation", "rolled back, awaiting confirmation": return t("Taken right after applying")
        case "confirmed": return t("Taken after confirming")
        case "reverted": return t("Taken after rolling back")
        case "refresh": return t("Taken on a read")
        default: return reason
        }
    }
}

// MARK: - Comparison

/// One line of a diff as shown in the code view.
struct DiffLine: Identifiable, Equatable {
    enum Kind { case header, context, added, removed }
    var id: Int
    var kind: Kind
    var sign: String
    var text: String

    /// The switch's own diff output (`[edit …]` headers, `+`/`-` rows).
    static func parse(compare text: String) -> [DiffLine] {
        var out: [DiffLine] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if line.hasPrefix("[edit") {
                out.append(DiffLine(id: out.count, kind: .header, sign: " ", text: line))
            } else if line.hasPrefix("+") {
                out.append(DiffLine(id: out.count, kind: .added, sign: "+", text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                out.append(DiffLine(id: out.count, kind: .removed, sign: "\u{2212}", text: String(line.dropFirst())))
            } else {
                out.append(DiffLine(id: out.count, kind: .context, sign: " ", text: String(line.dropFirst())))
            }
        }
        return out
    }

    /// A local `set` diff, grouped by statement so related lines sit together.
    static func lines(_ diff: SetDiff.Result) -> [DiffLine] {
        let rows = diff.removed.map { (String($0.dropFirst(4)), Kind.removed) } + diff.added.map { (String($0.dropFirst(4)), Kind.added) }
        return rows.sorted { $0.0 == $1.0 ? $0.1 == .removed : $0.0 < $1.0 }.enumerated().map { i, r in
            DiffLine(id: i, kind: r.1, sign: r.1 == .added ? "+" : "\u{2212}", text: (r.1 == .added ? "set " : "delete ") + r.0)
        }
    }

    static func plain(_ text: String) -> [DiffLine] {
        text.components(separatedBy: "\n").enumerated().compactMap { i, l in
            l.isEmpty && i > 0 ? nil : DiffLine(id: i, kind: .context, sign: " ", text: l)
        }
    }
}

/// What the comparison of two versions shows.
enum Comparison {
    case switchDiff(text: String, command: String)
    case local(SetDiff.Result)
    case loading
    case unavailable(String)

    var setDiff: SetDiff.Result? {
        switch self {
        case let .switchDiff(text, _): return ConfigCompare.setDiff(fromCompare: text)
        case let .local(d): return d
        default: return nil
        }
    }

    var lines: [DiffLine] {
        switch self {
        case let .switchDiff(text, _): return DiffLine.parse(compare: text)
        case let .local(d): return DiffLine.lines(d)
        default: return []
        }
    }

    var exportText: String? {
        switch self {
        case let .switchDiff(text, _): return text
        case let .local(d): return DiffLine.lines(d).map { $0.text }.joined(separator: "\n") + "\n"
        default: return nil
        }
    }

    /// The sample switch carries one real capture: `show system rollback compare 2 0`. #0 only
    /// confirmed #1 without a config change, so 2 → 1 shows the same diff.
    @MainActor
    static func resolve(base: HistoryVersion?, target: HistoryVersion, data: HistoryData, cache: [String: String], deviceID: String) -> Comparison {
        guard let base else { return .unavailable(t("This is the oldest version the switch keeps.")) }
        if case let .commit(a) = base, case let .commit(b) = target {
            if a == b { return .local(SetDiff.Result(removed: [], added: [])) }
            let command = "show system rollback compare \(a) \(b)"
            if data.isSample {
                return a == 2 && (b == 1 || b == 0) ? .switchDiff(text: DemoData.sampleDiff, command: command)
                                                     : .unavailable(t("The sample switch only includes the comparison of #2 and #1."))
            }
            guard data.session.isConnected else { return .unavailable(t("Connect to the switch to compare its versions.")) }
            if let text = cache[cacheKey(deviceID: deviceID, data: data, a, b)] { return .switchDiff(text: text, command: command) }
            return .loading
        }
        guard let old = data.text(base), let new = data.text(target) else {
            return .unavailable(t("Netdeck keeps the full text only of the current version and its own backups. Compare two switch versions, or a backup with the current version."))
        }
        return .local(SetDiff.diff(old: old, new: new))
    }

    @MainActor
    static func cacheKey(deviceID: String, data: HistoryData, _ a: Int, _ b: Int) -> String {
        "\(deviceID)|\(data.session.snapshot?.takenAt.timeIntervalSince1970 ?? 0)|\(a)|\(b)"
    }
}

// MARK: - Header

struct HistoryHeader: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession

    var body: some View {
        let data = HistoryData(session: session, isSample: model.isSample(device.id))
        let versions = String(data.commits.count), backups = String(data.backups.count)
        SectionHeader(title: t("History & backups"),
                      chip: Format.plural(data.commits.count, t("%@ version", "1"), t("%@ versions", versions)) + " · "
                          + Format.plural(data.backups.count, t("%@ local backup", "1"), t("%@ local backups", backups)),
                      subtitle: t("The switch's own commit history and the backups Netdeck took. Compare any version and go back to it if you want.")) {
            // A backup is a fresh read of the configuration; Netdeck keeps it when it changed.
            Button { model.read(device.id) } label: { Label(t("Back up now"), systemImage: "square.and.arrow.down") }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isSample(device.id) || session.isBusy)
                .help(model.isSample(device.id) ? t("This is a sample switch. Nothing is sent; Apply is turned off.") : "")
        }
    }
}

// MARK: - Screen

struct HistoryScreen: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var session: DeviceSession

    private var state: Binding<HistoryViewState> {
        Binding(get: { model.historyState[device.id] ?? HistoryViewState() }, set: { model.historyState[device.id] = $0 })
    }

    var body: some View {
        let data = HistoryData(session: session, isSample: model.isSample(device.id))
        let selected = state.wrappedValue.selected.flatMap { data.exists($0) ? $0 : nil } ?? data.defaultSelection
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 12) {
                HistoryTimeline(data: data, state: state, selected: selected)
                    .frame(width: geo.size.width < 1100 ? 400 : 452)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .card()
                Group {
                    if let selected {
                        VersionDetail(device: device, data: data, selected: selected, state: state)
                    } else {
                        EmptyHistory()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .card()
            }
        }
    }
}

private struct EmptyHistory: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.text4)
            Text(t("No versions yet. The history fills in after the first read.")).font(Typo.callout).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Timeline (left card)

private struct HistoryTimeline: View {
    var data: HistoryData
    @Binding var state: HistoryViewState
    var selected: HistoryVersion?

    enum Item: Identifiable {
        case commit(CommitEntry)
        case backup(HistoryData.Backup)
        case collapsed(first: Int, last: Int, count: Int)

        var id: String {
            switch self {
            case let .commit(c): return "c\(c.index ?? -1)"
            case let .backup(b): return "b\(b.id)"
            case let .collapsed(f, _, _): return "r\(f)"
            }
        }
        var date: Date? {
            switch self {
            case let .commit(c): return c.date
            case let .backup(b): return b.date
            case .collapsed: return nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if data.session.changeTraits.history == .commits {
                Segmented(options: [(HistoryViewState.Filter.all, t("All"), nil), (.commits, t("Switch history"), nil), (.backups, t("Local backups"), nil)],
                          selection: $state.filter)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            } else {
                // The device keeps no numbered versions (IOS, RouterOS): only Netdeck's own backups.
                Text(t("This device keeps no version history. Netdeck backs up its configuration on every read and before every change."))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            }
            if let days = data.clockBehindDays, state.filter != .backups {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.warn)
                    Text(t("The switch clock is about %@ days behind and NTP is off. Commit dates follow the switch clock.", String(days)))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface2))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            let list = items
            if list.isEmpty {
                Text(state.filter == .backups ? t("No local backups yet. Netdeck keeps one on every read that finds a changed configuration.")
                                              : t("No versions yet. The history fills in after the first read."))
                    .font(Typo.callout).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.top, 12)
                Spacer(minLength: 0)
            } else {
                NDScroll {
                    VStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                            row(item, last: i == list.count - 1).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 10)
                }
            }
        }
    }

    private var items: [Item] {
        let commits = collapsedCommits
        switch state.filter {
        case .commits: return commits
        case .backups: return data.backups.map(Item.backup)
        case .all:
            // Newest first; local backups slot in by date (Mac time vs. switch time, see the clock note).
            var out: [Item] = []
            var pending = data.backups
            for item in commits {
                if let d = item.date {
                    while let b = pending.first, b.date >= d { out.append(.backup(b)); pending.removeFirst() }
                }
                out.append(item)
            }
            return out + pending.map(Item.backup)
        }
    }

    /// The first four commits, every commit with a note and the selected one stay visible;
    /// runs of two or more others fold into "N more versions (#a–#b)".
    private var collapsedCommits: [Item] {
        var out: [Item] = []
        var run: [CommitEntry] = []
        func flush() {
            if run.count >= 2, let f = run.first?.index, let l = run.last?.index, !state.expanded.contains(f) {
                out.append(.collapsed(first: f, last: l, count: run.count))
            } else {
                out += run.map(Item.commit)
            }
            run = []
        }
        for (pos, c) in data.commits.enumerated() {
            let visible = pos < 4 || c.comment != nil || selected == .commit(c.index ?? -1)
            if visible { flush(); out.append(.commit(c)) } else { run.append(c) }
        }
        flush()
        return out
    }

    @ViewBuilder
    private func row(_ item: Item, last: Bool) -> some View {
        switch item {
        case let .commit(c): commitRow(c, last: last)
        case let .backup(b): backupRow(b, last: last)
        case let .collapsed(f, l, n): collapsedRow(first: f, last: l, count: n, isLast: last)
        }
    }

    private func rail(last: Bool, @ViewBuilder node: () -> some View) -> some View {
        node().frame(width: 28)
    }

    /// The 2 pt line from a row's node down to the next row's node.
    private func railLine(last: Bool) -> some View {
        Group {
            if !last {
                RoundedRectangle(cornerRadius: 1).fill(Theme.border).frame(width: 2)
                    .padding(.top, 42).padding(.bottom, -10).padding(.leading, 21)
            }
        }
    }

    private func commitRow(_ c: CommitEntry, last: Bool) -> some View {
        let index = c.index ?? 0
        let isSelected = selected == .commit(index)
        return Button {
            state.selected = .commit(index); state.base = nil; state.target = nil
        } label: {
            HStack(alignment: .top, spacing: 12) {
                rail(last: last) { UserNode(user: c.user, size: 28) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let note = c.comment {
                            Text(note).font(Typo.bodyStrong).foregroundStyle(Theme.text1).lineLimit(1)
                        } else {
                            Text(t("No note")).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text("#\(index)").font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text3)
                    }
                    CommitMeta(commit: c, commits: data.commits)
                }
                .padding(.top, 1)
            }
            .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 10)
            .background(alignment: .topLeading) { railLine(last: last) }
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.text1, lineWidth: 1.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func backupRow(_ b: HistoryData.Backup, last: Bool) -> some View {
        let isSelected = selected == .backup(b.id)
        return Button {
            state.selected = .backup(b.id); state.base = nil; state.target = nil
        } label: {
            HStack(alignment: .top, spacing: 12) {
                rail(last: last) {
                    Circle().fill(Theme.surface3).frame(width: 28, height: 28)
                        .overlay(Image(systemName: "externaldrive").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(t("Netdeck backup")).font(Typo.bodyStrong).foregroundStyle(Theme.text1).lineLimit(1)
                        Pill(text: t("Local"), kind: .outline, small: true)
                        Spacer(minLength: 6)
                        Text(Format.shortDay(b.date)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text3)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { macTime(b); Text("·"); Text(HistoryData.backupReason(b.reason)).lineLimit(1) }
                        VStack(alignment: .leading, spacing: 2) { macTime(b); Text(HistoryData.backupReason(b.reason)).lineLimit(1) }
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                }
                .padding(.top, 1)
            }
            .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 10)
            .background(alignment: .topLeading) { railLine(last: last) }
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.text1, lineWidth: 1.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func macTime(_ b: HistoryData.Backup) -> some View {
        Text(t("%@ (Mac time)", Format.day(b.date) + " · " + Format.time(b.date))).lineLimit(1)
    }

    private func collapsedRow(first: Int, last: Int, count: Int, isLast: Bool) -> some View {
        Button { state.expanded.insert(first) } label: {
            HStack(alignment: .center, spacing: 12) {
                Circle().fill(Theme.borderStrong).frame(width: 10, height: 10).frame(width: 28)
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .bold))
                    Text(t("%@ more versions (#%@–#%@)", String(count), String(first), String(last)))
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
                Spacer()
            }
            .padding(.leading, 8).padding(.trailing, 10).frame(height: 30)
            .background(alignment: .topLeading) {
                if !isLast {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.border).frame(width: 2)
                        .padding(.top, 20).padding(.bottom, -10).padding(.leading, 21)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "30 Oct 2026 · 05:35 · root · cli" plus the commit's pills; wraps onto a second line when narrow.
private struct CommitMeta: View {
    var commit: CommitEntry
    var commits: [CommitEntry]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { text; pills }
            VStack(alignment: .leading, spacing: 5) { text; pills }
        }
    }

    private var text: some View {
        HStack(spacing: 6) {
            Text(Format.commitDate(commit)).monospacedDigit()
            Text("·")
            Text("\(commit.user) · \(commit.client)")
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1).fixedSize()
    }

    @ViewBuilder
    private var pills: some View {
        let confirming = HistoryData.confirmsPrevious(commit, in: commits)
        if commit.confirmed || confirming {
            HStack(spacing: 6) {
                if commit.confirmed {
                    Pill(text: t("Safe commit · %@ min", String(commit.confirmMinutes ?? 5)), kind: .accent, icon: "timer", small: true)
                }
                if confirming {
                    let noChange = commit.comment?.hasSuffix("(confirmed)") == true && commit.comment?.hasPrefix("Netdeck") == true
                    Pill(text: noChange ? t("Confirmed the previous one") + " · " + t("no config change") : t("Confirmed the previous one"),
                         kind: .good, icon: "checkmark", small: true)
                }
            }
        }
    }
}

/// Person node: initial on a pastel circle (root is slate, other users get a stable color).
struct UserNode: View {
    var user: String
    var size: CGFloat = 28

    var body: some View {
        let avatar = Self.avatar(for: user)
        Circle().fill(avatar.fill).frame(width: size, height: size)
            .overlay(Text(String(user.prefix(1)).uppercased()).font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(avatar.ink))
    }

    static func avatar(for user: String) -> Avatar {
        if user == "root" { return .slate }
        let options: [Avatar] = [.lavender, .mint, .sky, .peach, .rose, .butter]
        let sum = user.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return options[sum % options.count]
    }
}

// MARK: - Version detail (right card)

private struct VersionDetail: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var data: HistoryData
    var selected: HistoryVersion
    @Binding var state: HistoryViewState

    var body: some View {
        let (base, target) = data.pair(for: selected, state: state)
        let comparison = Comparison.resolve(base: base, target: target, data: data, cache: model.compareCache, deviceID: device.id)
        let items = comparison.setDiff.map { DiffSummary.items($0, current: data.session.snapshot?.config) } ?? []
        VStack(alignment: .leading, spacing: 0) {
            header
            compareBar(base: base, target: target, count: comparison.setDiff == nil ? nil : items.count)
            Rectangle().fill(Theme.border).frame(height: 1)
            if comparison.setDiff != nil && !items.isEmpty {
                DiffSummaryList(items: items, snapshot: data.session.snapshot, colors: model.colors(for: device.id), limit: 5)
                    .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
            }
            code(comparison, base: base, target: target)
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .layoutPriority(-1)
            footer(comparison, target: target)
        }
        .task(id: fetchKey(base: base, target: target)) { await fetch(base: base, target: target) }
    }

    // Header: who, when, how
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            switch selected {
            case let .commit(i):
                UserNode(user: data.commit(i)?.user ?? "?", size: 32)
            case .backup:
                Circle().fill(Theme.surface3).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "externaldrive").font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text2))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(data.title(selected)).font(Typo.cardTitle)
                        .foregroundStyle(isUnnamed ? Theme.text3 : Theme.text1).lineLimit(1)
                    if case .backup = selected { Pill(text: t("Local"), kind: .outline, small: true) }
                }
                subline
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button { copy(currentText) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(GhostButtonStyle()).help(t("Copy")).disabled(currentText == nil)
                NDMenu {
                    Button(t("Copy")) { copy(currentText) }.disabled(currentText == nil)
                    Button(t("Export")) { export() }.disabled(currentText == nil)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    private var isUnnamed: Bool {
        if case let .commit(i) = selected { return data.commit(i)?.comment == nil }
        return false
    }

    @ViewBuilder
    private var subline: some View {
        switch selected {
        case let .commit(i):
            if let c = data.commit(i) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { Text("#\(i) · \(Format.commitDate(c)) · \(c.user) · \(c.client)").lineLimit(1); detailPills(c) }
                    Text("#\(i) · \(Format.commitDate(c)) · \(c.user) · \(c.client)").lineLimit(1)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.text3).monospacedDigit()
            }
        case let .backup(id):
            if let b = data.backup(id) {
                Text(t("%@ (Mac time)", Format.day(b.date) + " · " + Format.time(b.date)) + " · " + HistoryData.backupReason(b.reason))
                    .font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func detailPills(_ c: CommitEntry) -> some View {
        HStack(spacing: 6) {
            if c.confirmed { Pill(text: t("Safe commit · %@ min", String(c.confirmMinutes ?? 5)), kind: .accent, icon: "timer", small: true) }
            if let i = c.index, let next = data.commit(i - 1), HistoryData.confirmsPrevious(next, in: data.commits) {
                Pill(text: t("Confirmed by #%@", String(i - 1)), kind: .good, icon: "checkmark", small: true)
            }
        }
    }

    // Compare bar: "Compare [#2 · 2 Sep 2026] → [#1 · 30 Oct 2026]     4 changes"
    private func compareBar(base: HistoryVersion?, target: HistoryVersion, count: Int?) -> some View {
        HStack(spacing: 8) {
            Text(t("Compare")).font(.system(size: 12)).foregroundStyle(Theme.text3)
            versionPicker(base, placeholder: "—") { state.base = $0 }
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
            versionPicker(target, placeholder: "—") { state.target = $0 }
            Spacer(minLength: 8)
            if let count {
                Pill(text: count == 1 ? t("1 change") : t("%@ changes", String(count)), kind: .outline).monospacedDigit()
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 14)
    }

    private func versionPicker(_ value: HistoryVersion?, placeholder: String, set: @escaping (HistoryVersion) -> Void) -> some View {
        NDMenu {
            Section(t("Switch history")) {
                ForEach(data.commits, id: \.id) { c in
                    if let i = c.index {
                        Button("#\(i) · \(Format.commitDate(c)) · \(c.comment ?? t("No note"))") { set(.commit(i)) }
                    }
                }
            }
            if !data.backups.isEmpty {
                Section(t("Local backups")) {
                    ForEach(data.backups) { b in
                        Button(t("Netdeck backup") + " · " + Format.day(b.date) + " · " + Format.time(b.date)) { set(.backup(b.id)) }
                    }
                }
            }
        } label: {
            PickerField(icon: nil, text: value.map(data.shortLabel) ?? placeholder, placeholder: value == nil)
                .fixedSize()
        }
    }

    // Tabs + code
    @ViewBuilder
    private func code(_ comparison: Comparison, base: HistoryVersion?, target: HistoryVersion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Segmented(options: [(HistoryViewState.Tab.diff, t("Switch diff"), nil), (.full, t("Full configuration"), nil)], selection: $state.tab)
                Spacer(minLength: 8)
                if state.tab == .diff, case let .switchDiff(_, command) = comparison {
                    Text(command).font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
            }
            if state.tab == .diff {
                switch comparison {
                case .loading:
                    CodeMessage { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(t("Asking the switch…")) } }
                case let .unavailable(reason):
                    CodeMessage { Text(reason) }
                default:
                    let lines = comparison.lines
                    if lines.isEmpty {
                        CodeMessage {
                            if case .backup = selected, target == .commit(0) {
                                Text(t("This backup matches the current configuration."))
                            } else {
                                Text(t("No differences between these versions."))
                            }
                        }
                    } else {
                        DiffCodeView(lines: lines)
                    }
                }
            } else if let text = data.text(target) {
                DiffCodeView(lines: DiffLine.plain(text))
            } else {
                CodeMessage { Text(t("The switch keeps the older versions. Netdeck shows the full text of the current version and of its own backups.")) }
            }
        }
    }

    private func footer(_ comparison: Comparison, target: HistoryVersion) -> some View {
        let session = data.session
        let rollbackIndex: Int? = { if case let .commit(i) = selected, i > 0, session.changeTraits.canRollback { return i }; return nil }()
        return HStack(spacing: 10) {
            Text(t("Going back also goes through \"Review changes\" first. Nothing is sent to the switch without your confirmation."))
                .font(.system(size: 12)).foregroundStyle(Theme.text3).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Button { export() } label: { Label(t("Export"), systemImage: "square.and.arrow.down") }
                .buttonStyle(SecondaryButtonStyle()).disabled(currentText == nil)
            if session.changeTraits.canRollback {
                rollbackButton(rollbackIndex, session: session)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Theme.surface2)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func rollbackButton(_ rollbackIndex: Int?, session: DeviceSession) -> some View {
            Button {
                if let i = rollbackIndex { model.sheet = .rollback(deviceID: device.id, index: i) }
            } label: { Label(t("Go back to this version…"), systemImage: "arrow.uturn.backward") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(rollbackIndex == nil || session.pending != nil || session.isBusy)
                .help(rollbackIndex != nil ? "" : (selected == .commit(0) ? t("This is the current version.") : t("Going back works for versions the switch keeps.")))
    }

    // MARK: Text actions

    /// What the visible tab shows: the diff, or the selected version's full text.
    private var currentText: String? {
        let (base, target) = data.pair(for: selected, state: state)
        if state.tab == .full { return data.text(target) }
        return Comparison.resolve(base: base, target: target, data: data, cache: model.compareCache, deviceID: device.id).exportText
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export() {
        guard let text = currentText else { return }
        let (base, target) = data.pair(for: selected, state: state)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(base: base, target: target)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func fileName(base: HistoryVersion?, target: HistoryVersion) -> String {
        func part(_ v: HistoryVersion) -> String {
            switch v {
            case let .commit(i): return "\(i)"
            case let .backup(id):
                return "backup-" + (data.backup(id).map { BackupNames.stamp($0.date) } ?? id)
            }
        }
        if state.tab == .full { return "\(device.name)-\(part(target)).set" }
        return "\(device.name)-compare-\(base.map(part) ?? "")-\(part(target)).txt"
    }

    // MARK: Fetching the switch's diff (connected sessions only; read-only command)

    private func fetchKey(base: HistoryVersion?, target: HistoryVersion) -> String {
        guard case let .commit(a)? = base, case let .commit(b) = target, a != b else { return "" }
        // Busy is part of the key so the fetch runs again once a read or apply has finished.
        return Comparison.cacheKey(deviceID: device.id, data: data, a, b) + (data.session.isBusy ? "|busy" : "")
    }

    private func fetch(base: HistoryVersion?, target: HistoryVersion) async {
        guard !data.isSample, data.session.isConnected, !data.session.isBusy,
              case let .commit(a)? = base, case let .commit(b) = target, a != b else { return }
        let key = Comparison.cacheKey(deviceID: device.id, data: data, a, b)
        guard model.compareCache[key] == nil else { return }
        let text = await data.session.compare(rollback: a, to: b)
        model.compareCache[key] = text
    }
}

private enum BackupNames {
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: d)
    }
}

/// Centered note in the code area (loading, not available, no differences).
private struct CodeMessage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .font(Typo.callout).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Diff code view

/// Line-numbered mono code block with red/green rows (`.code` in the mockups).
struct DiffCodeView: View {
    var lines: [DiffLine]
    var maxHeight: CGFloat = .infinity
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if RenderMode.active {
                VStack(alignment: .leading, spacing: 0) { rows }.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView(.vertical) { LazyVStack(alignment: .leading, spacing: 0) { rows } }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: maxHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var rows: some View {
        ForEach(lines) { line in
            HStack(spacing: 0) {
                Text(String(line.id + 1)).foregroundStyle(Theme.text4).frame(width: 36, alignment: .trailing).padding(.trailing, 12)
                Text(line.sign).foregroundStyle(signColor(line.kind)).frame(width: 14, alignment: .leading)
                Text(line.text).foregroundStyle(textColor(line.kind)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(Typo.mono)
            .frame(height: 20)
            .padding(.trailing, 14)
            .background(background(line.kind))
            .textSelection(.enabled)
        }
    }

    private func background(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: return Color(hex: 0x16A34A, opacity: scheme == .dark ? 0.12 : 0.08)
        case .removed: return Color(hex: 0xE5484D, opacity: scheme == .dark ? 0.12 : 0.08)
        default: return .clear
        }
    }

    private func textColor(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: return scheme == .dark ? Color(hex: 0x6EE3A6) : Color(hex: 0x12733A)
        case .removed: return scheme == .dark ? Color(hex: 0xFF8F93) : Color(hex: 0xB42F34)
        case .header: return Theme.text3
        case .context: return Theme.text1
        }
    }

    private func signColor(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added, .removed: return textColor(k)
        default: return Theme.text3
        }
    }
}

// MARK: - Plain-language summary

/// "~ ge-0/0/2 removed from the disabled ports group (UNUSED), so it was enabled" rows.
struct DiffSummaryList: View {
    var items: [DiffSummaryItem]
    var snapshot: SwitchSnapshot?
    var colors: VLANColorMap
    var limit: Int = .max

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                HStack(spacing: 10) {
                    badge(.changed).opacity(0.4)
                    Text(t("No differences between these versions.")).font(Typo.body).foregroundStyle(Theme.text3)
                }
            }
            ForEach(Array(items.prefix(limit).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 10) {
                    badge(item.sign)
                    SummarySentence(item: item, snapshot: snapshot, colors: colors)
                        .frame(minHeight: 22)
                }
            }
            if items.count > limit {
                Text(Format.plural(items.count - limit, t("%@ more change in the diff below", "1"),
                                   t("%@ more changes in the diff below", String(items.count - limit))))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3).padding(.leading, 32)
            }
        }
    }

    private func badge(_ sign: DiffSummaryItem.Sign) -> some View {
        let (symbol, fill, ink): (String, Color, Color) = {
            switch sign {
            case .changed: return ("~", Theme.accentSoft, Theme.accentInk)
            case .added: return ("+", Theme.goodSoft, Theme.goodInk)
            case .removed: return ("\u{2212}", Theme.dangerSoft, Theme.dangerInk)
            }
        }()
        return Text(symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(ink)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
    }
}

/// One summary sentence. The translated template is split at its `%@` placeholders so ports can be
/// bold and VLANs can be chips, in whatever order the language puts them.
private struct SummarySentence: View {
    var item: DiffSummaryItem
    var snapshot: SwitchSnapshot?
    var colors: VLANColorMap

    enum Part { case text(String), strong(String), mono(String), vlan(String, id: Int? = nil) }

    var body: some View {
        let parts = self.parts
        if parts.contains(where: { if case .vlan = $0 { return true }; return false }) {
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    switch p {
                    case let .vlan(name, id):
                        VLANChip(name: name, vlanID: id ?? snapshot?.config.vlan(named: name)?.vlanID, color: colors.color(name), size: .small)
                            .padding(.horizontal, 3)
                    default: text(p)
                    }
                }
            }
            .lineLimit(1)
        } else {
            parts.reduce(Text("")) { $0 + text($1) }
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func text(_ p: Part) -> Text {
        switch p {
        case let .text(s): return Text(s).font(Typo.body).foregroundColor(Theme.text1)
        case let .strong(s): return Text(s).font(Typo.bodyStrong).foregroundColor(Theme.text1)
        case let .mono(s): return Text(s).font(.system(size: 12.5, design: .monospaced)).foregroundColor(Theme.text2)
        case let .vlan(s, _): return Text(s).font(Typo.bodyStrong).foregroundColor(Theme.text1)
        }
    }

    private var parts: [Part] {
        switch item.kind {
        case let .leftDisabledRange(port, range):
            return range == "UNUSED"
                ? fill("%@ removed from the disabled ports group (UNUSED), so it was enabled", [.strong(port)])
                : fill("%@ removed from the disabled ports group (%@), so it was enabled", [.strong(port), .text(range)])
        case let .joinedDisabledRange(port, range):
            return fill("%@ added to the disabled ports group (%@), so it was disabled", [.strong(port), .text(range)])
        case let .description(port, value): return fill("%@ description: %@", [.strong(port), .text(value)])
        case let .descriptionRemoved(port): return fill("%@ description removed", [.strong(port)])
        case let .accessVLAN(port, vlan): return fill("%@ put on VLAN %@ as one network", [.strong(port), .vlan(vlan)])
        case let .joinedVLAN(port, vlan): return fill("%@ joined VLAN %@", [.strong(port), .vlan(vlan)])
        case let .leftVLAN(port, vlan): return fill("%@ left VLAN %@", [.strong(port), .vlan(vlan)])
        case let .mode(port, trunk):
            return fill(trunk ? "%@ now carries several networks (trunk)" : "%@ now carries one network (access)", [.strong(port)])
        case let .edge(port): return fill("%@ became an edge port: if another switch is plugged in, the port shuts itself down", [.strong(port)])
        case let .notEdge(port): return fill("%@ is no longer an edge port", [.strong(port)])
        case let .disabled(port): return fill("%@ was disabled", [.strong(port)])
        case let .enabled(port): return fill("%@ was enabled", [.strong(port)])
        case let .vlanAdded(name, id): return fill("VLAN %@ was added", [.vlan(name, id: id)])
        case let .vlanRemoved(name): return fill("VLAN %@ was removed", [.vlan(name)])
        case let .other(subject, statement): return [.strong(subject), .text(" "), .mono(statement)]
        }
    }

    private func fill(_ key: String, _ args: [Part]) -> [Part] {
        let pieces = t(key).components(separatedBy: "%@")
        var out: [Part] = []
        for (i, piece) in pieces.enumerated() {
            if !piece.isEmpty { out.append(.text(piece)) }
            if i < args.count && i < pieces.count - 1 { out.append(args[i]) }
        }
        return out
    }
}

// MARK: - Formatting

extension Format {
    /// "30 Oct 2026" in the UI language; `zone` keeps a commit's date as the switch printed it.
    static func day(_ date: Date, zone: TimeZone? = nil) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale)
        if let zone { style.timeZone = zone }
        return date.formatted(style)
    }

    /// "30 Oct 2026 · 05:35" as printed by the switch (its clock and time zone).
    static func commitDate(_ c: CommitEntry) -> String {
        guard let d = c.date else { return c.timestamp }
        var time = Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)
        if let zone = c.timeZone { time.timeZone = zone }
        return day(d, zone: c.timeZone) + " · " + d.formatted(time)
    }

    /// "Today", "Yesterday" or a short date.
    static func shortDay(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return t("Today") }
        if Calendar.current.isDateInYesterday(date) { return t("Yesterday") }
        return date.formatted(Date.FormatStyle().day().month(.abbreviated).locale(L10n.locale))
    }

    /// For the middle of a sentence: "14:32", "yesterday 22:10" or "17 Nov 2026 22:10".
    static func inlineDay(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return time(date) }
        if Calendar.current.isDateInYesterday(date) { return t("yesterday %@", time(date)) }
        return day(date) + " " + time(date)
    }
}
