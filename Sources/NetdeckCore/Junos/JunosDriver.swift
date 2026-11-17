import Foundation

public enum DriverError: Error, LocalizedError, Equatable {
    case candidateDirty(diff: String)
    case rejected([String])
    case commitFailed(String)
    case nothingPending

    public var errorDescription: String? {
        switch self {
        case .candidateDirty:
            return t("The switch has uncommitted changes made by someone else. Review or discard them first.")
        case .rejected(let lines): return t("The switch rejected some commands:") + "\n" + lines.joined(separator: "\n")
        case .commitFailed(let out): return t("The switch could not commit the change:") + "\n" + out
        case .nothingPending: return t("There is no change waiting for confirmation.")
        }
    }
}

public struct LoadStep: Sendable, Equatable {
    public var index: Int
    public var total: Int
    public var title: String
}

public struct PreviewResult: Sendable, Equatable {
    public var diff: String
    public var checkPassed: Bool
    public var checkOutput: String
}

public struct ApplyResult: Sendable, Equatable {
    public var output: String
    public var confirmMinutes: Int
    public var appliedAt: Date
    public var deadline: Date { appliedAt.addingTimeInterval(TimeInterval(confirmMinutes * 60)) }
}

/// High-level operations for Juniper EX (ELS) switches over a `JunosCLI` session.
public actor JunosDriver {
    public let cli: JunosCLI
    private var inConfigMode = false

    public init(transport: Transport) {
        self.cli = JunosCLI(transport: transport)
    }

    public func connect(username: String, password: String?) async throws {
        try await cli.login(username: username, password: password)
    }

    public func disconnect() async {
        if inConfigMode { _ = try? await cli.run("rollback 0"); _ = try? await exitConfig() }
        await cli.logout()
    }

    // MARK: Read

    public func loadSnapshot(progress: @Sendable (LoadStep) -> Void = { _ in }) async throws -> SwitchSnapshot {
        let steps = [
            t("Reading device info"),
            t("Reading configuration"),
            t("Reading port status"),
            t("Reading MAC table"),
            t("Reading LLDP neighbors"),
            t("Reading hardware and modules"),
            t("Reading commit history"),
            t("Reading rear-panel ports"),
        ]
        func step(_ i: Int) { progress(LoadStep(index: i, total: steps.count, title: steps[i])) }

        step(0); let version = OutputParsers.version(try await cli.run("show version"))
        step(1); let configText = try await cli.run("show configuration | display set")
        step(2); let terse = try await cli.run(#"show interfaces terse | except "\.""#)
        step(3); let macs = try await cli.run("show ethernet-switching table")
        step(4); let lldp = try await cli.run("show lldp neighbors")
        step(5); let hw = try await cli.run("show chassis hardware")
        step(6); let commits = try await cli.run("show system commit")
        step(7); let vc = try? await cli.run("show virtual-chassis vc-port")

        return SwitchSnapshot(
            version: version,
            hardware: OutputParsers.chassisHardware(hw),
            config: SetConfigParser.parse(configText),
            configText: configText,
            statuses: OutputParsers.interfacesTerse(terse),
            macTable: OutputParsers.macTable(macs),
            lldp: OutputParsers.lldpNeighbors(lldp),
            commits: OutputParsers.commitHistory(commits),
            vcPorts: vc.map(OutputParsers.vcPorts) ?? []
        )
    }

    /// Diff between two rollback slots (0 = active config).
    public func compare(rollback older: Int, to newer: Int = 0) async throws -> String {
        try await cli.run("show system rollback compare \(older) \(newer)")
    }

    // MARK: Change

    /// Loads the commands into the candidate config, shows the switch's own diff and runs
    /// `commit check`, then throws everything away. The running config is never touched.
    public func preview(_ commands: [String]) async throws -> PreviewResult {
        try await enterCleanConfig()
        do {
            try await load(commands)
            let diff = try await cli.run("show | compare")
            let check = try await cli.run("commit check", idle: .seconds(120))
            _ = try await cli.run("rollback 0")
            try await exitConfig()
            return PreviewResult(diff: diff, checkPassed: check.contains("configuration check succeeds"), checkOutput: check)
        } catch {
            _ = try? await cli.run("rollback 0")
            try? await exitConfig()
            throw error
        }
    }

    /// Applies with `commit confirmed`: the switch reverts by itself unless `confirm()` is called in time.
    public func apply(_ commands: [String], confirmMinutes: Int = 5, comment: String) async throws -> ApplyResult {
        try await enterCleanConfig()
        do {
            try await load(commands)
            let check = try await cli.run("commit check", idle: .seconds(120))
            guard check.contains("configuration check succeeds") else { throw DriverError.commitFailed(check) }
            let out = try await cli.run(
                "commit confirmed \(confirmMinutes) comment \(SetConfigParser.quote(L10n.asciiComment(comment)))", idle: .seconds(180)
            )
            guard out.contains("commit complete") else { throw DriverError.commitFailed(out) }
            try await exitConfig()
            return ApplyResult(output: out, confirmMinutes: confirmMinutes, appliedAt: .now)
        } catch {
            _ = try? await cli.run("rollback 0")
            try? await exitConfig()
            throw error
        }
    }

    /// Makes a pending `commit confirmed` permanent.
    public func confirm(comment: String) async throws {
        try await enterConfig()
        let out = try await cli.run("commit comment \(SetConfigParser.quote(L10n.asciiComment(comment)))", idle: .seconds(180))
        try await exitConfig()
        guard out.contains("commit complete") else { throw DriverError.commitFailed(out) }
    }

    /// Reverts a pending `commit confirmed` right away (instead of waiting for the timer).
    /// Only acts if the newest commit is still the unconfirmed one we made.
    public func revertPending(expectedComment: String) async throws {
        let history = OutputParsers.commitHistory(try await cli.run("show system commit"))
        guard let top = history.first, top.confirmed, top.comment == L10n.asciiComment(expectedComment) else {
            throw DriverError.nothingPending
        }
        try await enterConfig()
        _ = try await cli.run("rollback 1")
        let out = try await cli.run("commit comment \(SetConfigParser.quote("Netdeck: reverted"))", idle: .seconds(180))
        try await exitConfig()
        guard out.contains("commit complete") else { throw DriverError.commitFailed(out) }
    }

    /// Returns to an older version, again with a confirm timer.
    public func rollback(to index: Int, confirmMinutes: Int = 5, comment: String) async throws -> ApplyResult {
        try await enterCleanConfig()
        do {
            let r = try await cli.run("rollback \(index)")
            let errs = OutputParsers.errors(in: r)
            guard errs.isEmpty else { throw DriverError.rejected(errs) }
            let out = try await cli.run(
                "commit confirmed \(confirmMinutes) comment \(SetConfigParser.quote(comment))", idle: .seconds(180)
            )
            guard out.contains("commit complete") else { throw DriverError.commitFailed(out) }
            try await exitConfig()
            return ApplyResult(output: out, confirmMinutes: confirmMinutes, appliedAt: .now)
        } catch {
            _ = try? await cli.run("rollback 0")
            try? await exitConfig()
            throw error
        }
    }

    /// Discards candidate changes someone else left behind.
    public func discardCandidate() async throws {
        try await enterConfig()
        _ = try await cli.run("rollback 0")
        try await exitConfig()
    }

    // MARK: Internals

    private func enterConfig() async throws {
        guard !inConfigMode else { return }
        _ = try await cli.run("configure")
        inConfigMode = true
    }

    private func enterCleanConfig() async throws {
        try await enterConfig()
        let count = OutputParsers.count(try await cli.run("show | compare | count")) ?? 0
        if count > 0 {
            let diff = try await cli.run("show | compare")
            try await exitConfig()
            throw DriverError.candidateDirty(diff: diff)
        }
    }

    private func exitConfig() async throws {
        guard inConfigMode else { return }
        _ = try await cli.run("exit configuration-mode")
        if await cli.currentPrompt == .question { _ = try await cli.run("yes") }
        inConfigMode = false
    }

    private func load(_ commands: [String]) async throws {
        var rejected: [String] = []
        for c in commands {
            let out = try await cli.run(c)
            let errs = OutputParsers.errors(in: out)
            if !errs.isEmpty { rejected.append("\(c)\n  → \(errs.joined(separator: " "))") }
        }
        if !rejected.isEmpty { throw DriverError.rejected(rejected) }
    }
}
