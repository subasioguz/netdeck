import Foundation

/// MikroTik RouterOS 7 over the text console (serial or SSH).
///
/// RouterOS has no candidate configuration and no `commit confirmed`; every command takes effect at
/// once. Safe mode is no substitute (`/quit` keeps its changes, a dropped serial line isn't covered), so
/// the safety net lives on the router itself, independent of Netdeck and of the connection: before the
/// first change Netdeck stores the plan's undo commands as a script (`netdeck-undo`) and a one-shot
/// scheduler (`netdeck-revert`) that runs it at the deadline. Confirming removes both; the script
/// removes both itself when it runs.
public actor MikroTikDriver: DeviceDriver {
    public let session: CLISession
    /// The end marker printed after each command arrives (checked at login), so a command that ended
    /// without it was cut short or rejected.
    private var markerWorks = false

    public init(transport: Transport) {
        self.session = CLISession(transport: transport, dialect: MikroTikDialect())
    }

    // MARK: Connection

    public func connect(username: String, password: String?) async throws {
        do {
            try await session.login(username: username, password: password)
        } catch let CLIError.unrecognizedPrompt(text) where MikroTikDialect.asksForNewPassword(text) {
            throw MikroTikError.newPasswordRequired
        }
        await synchronize()
        let resource = MikroTikParsers.keyValues(try await read("/system resource print"))
        let isRouterOS = resource["version"] != nil
            && (resource["platform"]?.contains("MikroTik") == true || resource["board-name"] != nil)
        guard isRouterOS else { throw DriverError.notSupported }
    }

    public func disconnect() async {
        await session.logout()
    }

    // MARK: Read

    public func read(progress: @Sendable (LoadStep) -> Void) async throws -> DeviceReading {
        let steps = [
            t("Reading device info"),
            t("Reading configuration"),
            t("Reading port status"),
            t("Reading MAC table"),
            t("Reading LLDP neighbors"),
        ]
        func step(_ i: Int) { progress(LoadStep(index: i, total: steps.count, title: steps[i])) }

        var o = MikroTikOutputs()
        step(0)
        o.identity = try await read("/system identity print")
        o.resource = try await read("/system resource print")
        o.routerboard = (try? await read("/system routerboard print")) ?? ""
        step(1)
        o.export = try await read("/export terse", idle: .seconds(90))
        o.bridges = try await read("/interface bridge print terse without-paging")
        o.bridgeVLANs = try await read("/interface bridge vlan print terse without-paging")
        o.vlanInterfaces = try await read("/interface vlan print terse without-paging")
        step(2)
        o.ethernet = try await read("/interface ethernet print terse without-paging")
        o.interfaces = try await read("/interface print terse without-paging")
        o.bridgePorts = try await read("/interface bridge port print terse without-paging")
        o.addresses = try await read("/ip address print terse without-paging")
        step(3)
        o.hosts = try await read("/interface bridge host print terse without-paging", idle: .seconds(60))
        step(4)
        o.neighbors = try await read("/ip neighbor print terse without-paging")
        return .network(MikroTikSnapshotBuilder.build(o))
    }

    // MARK: Change

    /// RouterOS has no candidate configuration to diff or check, so the diff is the command list. The
    /// router parses every command and undo command (`:parse`, which never runs anything) to catch
    /// syntax errors early.
    public func preview(_ plan: ChangePlan) async throws -> PreviewResult {
        try await ensureNoPendingTrial()
        var problems: [String] = []
        for c in plan.commands + plan.undoCommands {
            let check = ":put [:typeof [:parse \(MikroTikQuote.quoted(c))]]"
            guard check.count <= MikroTikSafetyNet.maxCommandLength else { continue }
            let errs = MikroTikDialect.errorLines(try await exec(check).output)
            if !errs.isEmpty { problems.append("\(c)\n  → \(errs.joined(separator: " "))") }
        }
        var note = t("RouterOS has no candidate configuration to check in advance. Netdeck sends the commands one by one and undoes all of them if the router rejects one.")
        if !problems.isEmpty { note += "\n\n" + problems.joined(separator: "\n") }
        return PreviewResult(diff: plan.commands.map { "+ " + $0 }.joined(separator: "\n"), checkPassed: problems.isEmpty, checkOutput: note)
    }

    public func apply(_ plan: ChangePlan, confirmMinutes: Int, comment: String) async throws -> ApplyResult {
        let commands = plan.commands
        guard !commands.isEmpty else { return ApplyResult(output: "", confirmMinutes: confirmMinutes, appliedAt: .now) }
        try await ensureNoPendingTrial()
        let armedAt = try await arm(undo: plan.undoCommands, minutes: confirmMinutes, comment: comment)

        var transcript: [String] = []
        for c in commands {
            let result: (output: String, confirmed: Bool)
            do {
                result = try await exec(c)
            } catch {
                // The session broke mid-change: undo now if the router still listens; otherwise the
                // scheduler undoes it at the deadline.
                try? await undoNow()
                throw error
            }
            let errs = MikroTikDialect.errorLines(result.output)
            if !errs.isEmpty || (markerWorks && !result.confirmed) {
                let why = errs.isEmpty ? [t("The router did not confirm the command.")] : errs
                try? await undoNow()
                throw DriverError.rejected(["\(c)\n  → \(why.joined(separator: " "))"])
            }
            transcript.append(result.output.isEmpty ? c : c + "\n" + result.output)
        }
        return ApplyResult(output: transcript.joined(separator: "\n"), confirmMinutes: confirmMinutes, appliedAt: armedAt)
    }

    /// Makes the change permanent: RouterOS keeps every change at once, so only the timer goes.
    public func confirm(comment: String) async throws {
        guard let pending = try await pendingTrial(), !MikroTikSafetyNet.hasRun(pending) else { throw DriverError.nothingPending }
        try await change(MikroTikSafetyNet.removeScheduler)
        // The undo script removes itself last: when it is gone, the timer fired just before.
        let scripts = MikroTikParsers.number(in: try await read(MikroTikSafetyNet.scriptCount))
        if scripts == 0 { throw DriverError.nothingPending }
        try await change(MikroTikSafetyNet.removeScript)
        if try await pendingTrial() != nil {
            throw DriverError.commitFailed(t("The undo timer is still on the router. Confirm again."))
        }
        _ = try? await exec(":log info \(MikroTikQuote.quoted(L10n.asciiComment(comment)))")
    }

    /// Runs the undo script now, if the pending change is ours.
    public func revertPending(expectedComment: String) async throws {
        guard let pending = try await pendingTrial(),
              (pending["comment"] ?? "") == MikroTikSafetyNet.comment(expectedComment) else {
            throw DriverError.nothingPending
        }
        try await runUndoScript()
    }

    /// Someone else's pending change: undo it now (its own timer would do the same at its deadline).
    public func discardCandidate() async throws {
        guard try await pendingTrial() != nil else {
            _ = try? await exec(MikroTikSafetyNet.removeScript)
            return
        }
        try await runUndoScript()
    }

    // MARK: Safety net

    /// Arms the timer on the router: the undo script, checked to be complete and valid, then the
    /// scheduler at router time + `minutes`. Returns when it was armed (the start of the countdown).
    /// Removes what it created and throws `safetyNetUnavailable` when anything fails; nothing is
    /// changed then.
    private func arm(undo: [String], minutes: Int, comment: String) async throws -> Date {
        let source = MikroTikSafetyNet.undoSource(undo)
        guard source.utf8.count <= MikroTikSafetyNet.maxSourceBytes else {
            throw DriverError.safetyNetUnavailable(t("This change is too large for the router's undo script. Apply it in smaller parts."))
        }
        // A script left without its scheduler does nothing; remove it so the name is free.
        _ = try? await exec(MikroTikSafetyNet.removeScript)

        let clockText = try await read("/system clock print")
        let armedAt = Date()
        guard let now = MikroTikParsers.clock(clockText), let deadline = now.adding(minutes: minutes) else {
            throw DriverError.safetyNetUnavailable(t("Netdeck could not read the router's clock, so it can't set the undo timer. Nothing was changed."))
        }

        // What was sent, so a failure removes only that (a name that already existed is someone else's).
        var scriptSent = false, schedulerSent = false
        do {
            for c in MikroTikSafetyNet.scriptCommands(source: source) {
                scriptSent = true
                try await change(c)
            }
            let length = MikroTikParsers.number(in: try await read(MikroTikSafetyNet.lengthCheck))
            guard length == source.utf8.count else {
                throw MikroTikSafetyNet.Failure(detail: t("The undo script on the router is incomplete."))
            }
            try await change(MikroTikSafetyNet.parseCheck)
            schedulerSent = true
            try await change(MikroTikSafetyNet.schedulerAdd(deadline: deadline, comment: comment))
            let entries = MikroTikParsers.terse(try await read(MikroTikSafetyNet.schedulerPrint))
            guard entries.count == 1, let entry = entries.first, MikroTikSafetyNet.isArmed(entry, now: now, deadline: deadline) else {
                throw MikroTikSafetyNet.Failure(detail: t("The undo timer did not start on the router."))
            }
            return armedAt
        } catch {
            if schedulerSent { _ = try? await exec(MikroTikSafetyNet.removeScheduler) }
            if scriptSent { _ = try? await exec(MikroTikSafetyNet.removeScript) }
            let detail = (error as? MikroTikSafetyNet.Failure)?.detail ?? (error as? LocalizedError)?.errorDescription ?? "\(error)"
            throw DriverError.safetyNetUnavailable(t("Netdeck could not set the undo timer on the router, so nothing was changed.") + "\n" + detail)
        }
    }

    /// The `netdeck-revert` scheduler, when a change waits for confirmation.
    private func pendingTrial() async throws -> MikroTikRecord? {
        MikroTikParsers.terse(try await read(MikroTikSafetyNet.schedulerPrint)).first { $0["name"] == MikroTikSafetyNet.schedulerName }
    }

    /// Another session's change still waits for confirmation: show it instead of stacking a second one.
    private func ensureNoPendingTrial() async throws {
        guard let pending = try await pendingTrial() else { return }
        let source = (try? await read(MikroTikSafetyNet.sourcePrint)) ?? ""
        throw DriverError.candidateDirty(diff: MikroTikSafetyNet.describe(pending, source: source))
    }

    /// Runs the undo script and checks that it finished (it removes the scheduler and itself).
    private func runUndoScript() async throws {
        let out = try await exec(MikroTikSafetyNet.runScript, idle: .seconds(90)).output
        if try await pendingTrial() != nil {
            throw DriverError.commitFailed(t("The undo script did not finish on the router.") + (out.isEmpty ? "" : "\n" + out))
        }
    }

    /// Best effort after a failed or broken apply.
    private func undoNow() async throws {
        _ = try await exec(MikroTikSafetyNet.runScript, idle: .seconds(90))
        _ = try? await exec(MikroTikSafetyNet.removeScheduler)
        _ = try? await exec(MikroTikSafetyNet.removeScript)
    }

    // MARK: Commands

    /// Logs in leave a redrawn prompt behind now and then; a marker round trip makes sure the next
    /// command's output is its own, and tells whether the end marker works on this router.
    private func synchronize() async {
        for _ in 0..<3 {
            guard let raw = try? await session.run(MikroTikSafetyNet.syncCommand, idle: .seconds(10)) else { continue }
            let out = MikroTikDialect.output(raw, sent: MikroTikSafetyNet.syncCommand, marker: false).output
            if out.components(separatedBy: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == MikroTikSafetyNet.syncMarker }) {
                markerWorks = true
                return
            }
        }
    }

    /// Runs one command, with the end marker when it works.
    private func exec(_ command: String, idle: Duration = .seconds(30)) async throws -> (output: String, confirmed: Bool) {
        let sent = markerWorks ? command + MikroTikDialect.markerSuffix : command
        let raw = try await session.run(sent, idle: idle)
        return MikroTikDialect.output(raw, sent: sent, marker: markerWorks)
    }

    /// A read command's output. Asked once more when the end marker didn't arrive (cut short).
    private func read(_ command: String, idle: Duration = .seconds(30)) async throws -> String {
        let first = try await exec(command, idle: idle)
        guard markerWorks, !first.confirmed, MikroTikDialect.errorLines(first.output).isEmpty else { return first.output }
        return try await exec(command, idle: idle).output
    }

    /// A command that must succeed.
    private func change(_ command: String) async throws {
        let r = try await exec(command)
        let errs = MikroTikDialect.errorLines(r.output)
        if !errs.isEmpty || (markerWorks && !r.confirmed) {
            let why = errs.isEmpty ? t("The router did not confirm the command.") : errs.joined(separator: " ")
            throw MikroTikSafetyNet.Failure(detail: "\(command)\n  → \(why)")
        }
    }
}

/// The router-side safety net: undo script, scheduler and the checks around them (pure, for tests).
public enum MikroTikSafetyNet {
    public static let scriptName = "netdeck-undo"
    public static let schedulerName = "netdeck-revert"

    /// RouterOS runs scripts up to 64 kB; stay well below, every byte is typed on the console.
    static let maxSourceBytes = 30_000
    /// Keeps each typed line inside the 511-column terminal (prompt included).
    static let maxCommandLength = 440
    public static let chunkLength = 280

    static let removeScheduler = "/system scheduler remove [find name=\(schedulerName)]"
    static let removeScript = "/system script remove [find name=\(scriptName)]"
    static let runScript = "/system script run \(scriptName)"
    static let schedulerPrint = "/system scheduler print terse without-paging where name=\(schedulerName)"
    static let scriptCount = ":put [:len [/system script find name=\(scriptName)]]"
    static let sourcePrint = ":put [/system script get [find name=\(scriptName)] source]"
    static let lengthCheck = ":put [:len [/system script get [find name=\(scriptName)] source]]"
    /// `:parse` compiles the stored script without running it: a syntax error shows up as an error line.
    static let parseCheck = ":put [:typeof [:parse [/system script get [find name=\(scriptName)] source]]]"
    static let syncCommand = ":put (\"netdeck-\" . \"sync\")"
    static let syncMarker = "netdeck-sync"
    /// The scheduler runs the script only if the script's policy is within its own: give both the same,
    /// just what the undo commands need.
    static let policy = "read,write"

    struct Failure: Error, LocalizedError {
        var detail: String
        var errorDescription: String? { detail }
    }

    /// The undo script: every undo command on its own (one failing doesn't stop the rest), a log line,
    /// then the scheduler and the script remove themselves.
    public static func undoSource(_ undo: [String]) -> String {
        var parts = undo.map { ":do {\($0)} on-error={}" }
        parts.append(":log warning \"Netdeck: previous settings restored\"")
        parts.append(removeScheduler)
        parts.append(removeScript)
        return parts.joined(separator: "; ")
    }

    /// Commands that store `source` as the undo script. The source is escaped and sent in pieces, each
    /// appended to the script, so no typed line gets longer than the terminal.
    public static func scriptCommands(source: String, chunk: Int = chunkLength) -> [String] {
        let pieces = escapedChunks(source, limit: chunk)
        var cmds = ["/system script add name=\(scriptName) policy=\(policy) source=\"\(pieces.first ?? "")\""]
        for p in pieces.dropFirst() {
            cmds.append("/system script set [find name=\(scriptName)] source=([/system script get [find name=\(scriptName)] source] . \"\(p)\")")
        }
        return cmds
    }

    /// `s` escaped for a quoted string, cut between escape sequences into pieces of at most `limit`.
    static func escapedChunks(_ s: String, limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for u in s.unicodeScalars {
            let e = MikroTikQuote.escape(String(u))
            if !current.isEmpty, current.count + e.count > limit {
                out.append(current)
                current = ""
            }
            current += e
        }
        if !current.isEmpty || out.isEmpty { out.append(current) }
        return out
    }

    /// The scheduler already ran (the undo script failed to remove it).
    public static func hasRun(_ entry: MikroTikRecord) -> Bool { (entry["run-count"].flatMap { Int($0) } ?? 0) > 0 }

    /// The scheduler comment: the change comment in ASCII (it's typed on the console and shown in WinBox).
    public static func comment(_ s: String) -> String { L10n.asciiComment(s) }

    public static func schedulerAdd(deadline: MikroTikClock, comment: String) -> String {
        "/system scheduler add name=\(schedulerName) start-date=\(deadline.dateString) start-time=\(deadline.timeString)"
            + " interval=0s policy=\(policy) on-event=\"\(runScript)\" comment=\(MikroTikQuote.quoted(Self.comment(comment)))"
    }

    /// The scheduler is enabled and will run: `next-run` (else its start) is in the future. A bare time
    /// is today's; past midnight it must be the deadline's time.
    public static func isArmed(_ entry: MikroTikRecord, now: MikroTikClock, deadline: MikroTikClock) -> Bool {
        guard entry["name"] == schedulerName, !entry.isDisabled else { return false }
        let text = entry["next-run"].flatMap { $0.isEmpty ? nil : $0 }
            ?? [entry["start-date"], entry["start-time"]].compactMap { $0 }.joined(separator: " ")
        guard let moment = MikroTikClock.parseMoment(text, today: now) else { return false }
        return moment.isAfter(now) || (!text.contains(" ") && moment.timeString == deadline.timeString)
    }

    /// Someone else's pending change, for the "uncommitted changes" card.
    public static func describe(_ entry: MikroTikRecord, source: String) -> String {
        var lines: [String] = []
        if let c = entry["comment"], !c.isEmpty { lines.append("# " + c) }
        let when = [entry["start-date"], entry["start-time"]].compactMap { $0 }.joined(separator: " ")
        if !when.isEmpty { lines.append("# " + t("Undo runs at %@ (router time)", when)) }
        let body = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { lines += body.components(separatedBy: "; ") }
        return lines.joined(separator: "\n")
    }
}
