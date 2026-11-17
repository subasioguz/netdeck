import Foundation

/// Ubiquiti EdgeOS (EdgeRouter) over a serial console or SSH.
///
/// Safety net: `commit-confirm N`. When its timer runs out EdgeOS does not roll the commit back the way
/// Junos does: it reboots and loads the saved configuration (/config/config.boot). So nothing is ever
/// saved before `confirm`, and reverting early loads the saved configuration instead of rebooting.
/// `rollback N` also reboots, so going back to an older version isn't offered.
public actor EdgeOSDriver: DeviceDriver {
    let cli: CLISession
    private var inConfigMode = false

    public init(transport: Transport) {
        cli = CLISession(transport: transport, dialect: EdgeOSDialect())
    }

    public func connect(username: String, password: String?) async throws {
        try await cli.login(username: username, password: password)
        let version = try await cli.run("show version")
        guard EdgeOSParsers.isEdgeOS(version) else { throw DriverError.notSupported }
    }

    public func disconnect() async {
        if inConfigMode { try? await exitConfig() }
        await cli.logout()
    }

    // MARK: Read

    public func read(progress: @Sendable (LoadStep) -> Void) async throws -> DeviceReading {
        let steps = [
            t("Reading device info"),
            t("Reading configuration"),
            t("Reading port status"),
            t("Reading MAC table"),
            t("Reading LLDP neighbors"),
            t("Reading commit history"),
        ]
        func step(_ i: Int) { progress(LoadStep(index: i, total: steps.count, title: steps[i])) }

        step(0); let version = try await cli.run("show version")
        step(1); let config = try await cli.run("show configuration commands", idle: .seconds(30))
        step(2); let interfaces = try await cli.run("show interfaces")
        step(3); let arp = try await cli.run("show arp")
        // LLDP may be off and the commit archive may be missing; neither should stop the reading.
        step(4); let lldp = (try? await cli.run("show lldp neighbors")) ?? ""
        step(5); let commits = (try? await cli.run("show system commit")) ?? ""

        return .network(EdgeOSSnapshot.build(version: version, config: config, interfaces: interfaces,
                                              arp: arp, lldp: lldp, commits: commits))
    }

    /// Diff between two commit revisions (0 = active configuration). EdgeOS `compare A B` shows the
    /// change from revision B to revision A, so the newer one goes first.
    public func compare(rollback older: Int, to newer: Int) async throws -> String {
        try await enterConfig()
        do {
            let out = try await cli.run("compare \(newer) \(older)", idle: .seconds(60))
            try await exitConfig()
            return out
        } catch {
            try? await exitConfig()
            throw error
        }
    }

    // MARK: Change

    /// Loads the commands into this session's working configuration, shows the router's own diff, then
    /// discards everything. The running configuration is never touched.
    public func preview(_ plan: ChangePlan) async throws -> PreviewResult {
        try await enterCleanConfig()
        do {
            // Unsaved changes are lost too if the timer runs out, since the router reboots into the saved file.
            let saved = EdgeOSParsers.savedState(try await cli.run("compare saved", idle: .seconds(60)))
            let rejected = try await loadCommands(plan.commands)
            let diff = try await cli.run("compare", idle: .seconds(60))
            try await discardAndExit()

            var notes: [String] = []
            if !rejected.isEmpty { notes.append(t("The router rejected some commands:") + "\n" + rejected.joined(separator: "\n")) }
            switch saved {
            case .same: break
            case .differs:
                notes.append(t("The running configuration has changes that were never saved. If you don't confirm in time, the router restarts with its saved configuration and those changes are lost as well."))
            case .unknown:
                notes.append(t("Netdeck could not check whether the running configuration is saved. Changes that were never saved are lost if the router restarts with its saved configuration."))
            }
            notes.append(t("If you don't confirm, the router restarts with its saved configuration. It is offline for a few minutes."))
            return PreviewResult(diff: diff, checkPassed: rejected.isEmpty, checkOutput: notes.joined(separator: "\n\n"))
        } catch {
            try? await discardAndExit()
            throw error
        }
    }

    /// Commits with `commit-confirm`: the router reboots into its saved configuration unless `confirm()`
    /// is called in time. Nothing is saved here.
    public func apply(_ plan: ChangePlan, confirmMinutes: Int, comment: String) async throws -> ApplyResult {
        let minutes = max(1, confirmMinutes)
        try await enterCleanConfig()
        do {
            let rejected = try await loadCommands(plan.commands)
            guard rejected.isEmpty else { throw DriverError.rejected(rejected) }

            // The timer starts before the commit runs, so the deadline counts from here.
            var startedAt = Date.now
            var output = try await cli.run("commit-confirm \(minutes)", idle: .seconds(180))
            var answered = false
            if await cli.currentPrompt == .question {
                startedAt = .now
                let answer = try await cli.run("y", idle: .seconds(180))
                output += "\n" + answer
                answered = true
                await settle()
            }

            switch EdgeOSParsers.commitConfirmResult(output, answered: answered) {
            case .armed:
                // The timer runs: report it even if leaving configuration mode fails.
                try? await exitConfig()
                return ApplyResult(output: output, confirmMinutes: minutes, appliedAt: startedAt)
            case let .notArmed(reason):
                if let reason { throw DriverError.safetyNetUnavailable(reason) }
                throw DriverError.commitFailed(output)
            case .commitFailed:
                let undone = await undoFailedCommit()
                let note = undone
                    ? t("Netdeck stopped the confirm timer and loaded the saved configuration again.")
                    : t("The confirm timer is still running: the router restarts with its saved configuration when it runs out.")
                throw DriverError.commitFailed(output + "\n\n" + note)
            }
        } catch {
            try? await exitConfig()
            throw error
        }
    }

    /// Stops the reboot timer and saves, which makes the change permanent.
    public func confirm(comment: String) async throws {
        try await enterConfig()
        do {
            let confirmed = try await cli.run("confirm", idle: .seconds(60))
            if EdgeOSParsers.nothingPending(confirmed) { throw DriverError.nothingPending }
            let errors = EdgeOSParsers.errors(in: confirmed)
            guard errors.isEmpty else { throw DriverError.commitFailed(confirmed) }
            let saved = try await cli.run("save", idle: .seconds(120))
            guard EdgeOSParsers.saveSucceeded(saved) else { throw DriverError.commitFailed(saved) }
            try? await exitConfig()
        } catch {
            try? await exitConfig()
            throw error
        }
    }

    /// Puts the saved configuration back now instead of waiting for the reboot. The timer is stopped
    /// last, so a revert that fails still leaves the reboot as the safety net.
    public func revertPending(expectedComment: String) async throws {
        try await enterCleanConfig()
        do {
            let loaded = try await cli.run("load", idle: .seconds(120))
            guard EdgeOSParsers.errors(in: loaded).isEmpty else { throw DriverError.commitFailed(loaded) }
            let committed = try await cli.run("commit", idle: .seconds(180))
            guard EdgeOSParsers.commitSucceeded(committed) else { throw DriverError.commitFailed(committed) }
            let confirmed = try await cli.run("confirm", idle: .seconds(60))
            try? await exitConfig()
            if EdgeOSParsers.nothingPending(confirmed) { throw DriverError.nothingPending }
            // The saved configuration is back, but the timer would still restart the router.
            guard EdgeOSParsers.errors(in: confirmed).isEmpty else { throw DriverError.commitFailed(confirmed) }
        } catch {
            try? await discardAndExit()
            throw error
        }
    }

    /// Throws away this session's uncommitted changes. EdgeOS keeps one working configuration per
    /// session, so another session's edits can't be reached from here.
    public func discardCandidate() async throws {
        try await enterConfig()
        do {
            try await discardAndExit()
        } catch {
            try? await exitConfig()
            throw error
        }
    }

    // MARK: Internals

    private func enterConfig() async throws {
        guard !inConfigMode else { return }
        let out = try await cli.run("configure")
        // An operator-level user stays in operational mode.
        guard await cli.currentPrompt == .configuration else { throw DriverError.rejected(["configure\n  → \(out)"]) }
        inConfigMode = true
    }

    /// Enters configuration mode and stops when the working configuration already differs from the active one.
    private func enterCleanConfig() async throws {
        try await enterConfig()
        let diff = try await cli.run("compare", idle: .seconds(60))
        if EdgeOSParsers.compareShowsChanges(diff) {
            try await exitConfig()
            throw DriverError.candidateDirty(diff: diff)
        }
    }

    /// `exit discard` leaves configuration mode whatever is uncommitted.
    private func exitConfig() async throws {
        guard inConfigMode else { return }
        // Cleared first: a second `exit discard` at the operational prompt would end the shell.
        inConfigMode = false
        _ = try await cli.run("exit discard")
        try await answerIfAsked()
    }

    private func discardAndExit() async throws {
        guard inConfigMode else { return }
        _ = try await cli.run("discard")
        try await answerIfAsked()
        try await exitConfig()
    }

    private func answerIfAsked() async throws {
        guard await cli.currentPrompt == .question else { return }
        _ = try await cli.run("y")
        await settle()
    }

    /// Questions such as `Proceed?` read a single key; the line ending sent after it reaches the shell
    /// as an empty command and prints one more prompt. Waiting a moment lets that prompt arrive before
    /// the next command clears the buffer, so it can't be taken for that command's end.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(800))
    }

    /// Sends each command and collects the ones the router rejected.
    private func loadCommands(_ commands: [String]) async throws -> [String] {
        var rejected: [String] = []
        for c in commands {
            let out = try await cli.run(c)
            let errs = EdgeOSParsers.errors(in: out)
            if !errs.isEmpty { rejected.append("\(c)\n  → \(errs.joined(separator: " "))") }
        }
        return rejected
    }

    /// After a commit that failed with the reboot timer already running (part of the change may be
    /// active): loads and commits the saved configuration, then stops the timer, so the router doesn't
    /// restart. Returns false when the timer is still running.
    private func undoFailedCommit() async -> Bool {
        do {
            _ = try await cli.run("discard")
            try await answerIfAsked()
            let loaded = try await cli.run("load", idle: .seconds(120))
            guard EdgeOSParsers.errors(in: loaded).isEmpty else { return false }
            let committed = try await cli.run("commit", idle: .seconds(180))
            guard EdgeOSParsers.commitSucceeded(committed) else { return false }
            let confirmed = try await cli.run("confirm", idle: .seconds(60))
            return EdgeOSParsers.errors(in: confirmed).isEmpty
        } catch {
            return false
        }
    }
}
