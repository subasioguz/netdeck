import Foundation

/// What a driver read from a device: a network device (ports, VLANs, MAC table...) or an appliance
/// reached over an HTTPS API (server BMC, NAS), which Netdeck shows as an information screen.
public enum DeviceReading: Sendable {
    case network(SwitchSnapshot)
    case appliance(ApplianceSnapshot)
}

/// One platform's connection to a device: login, read, and for network devices the safe change flow.
///
/// Every change goes out with a device-side safety net that undoes it unless `confirm` is called in
/// time (Junos `commit confirmed`, IOS `revert timer`, EdgeOS `commit-confirm`, a RouterOS scheduler).
/// Operations a platform can't do throw `DriverError.notSupported`.
public protocol DeviceDriver: Actor {
    /// Logs in (CLI) or opens an API session.
    func connect(username: String, password: String?) async throws
    /// Logs out and closes the transport. Never throws; safe to call more than once.
    func disconnect() async
    func read(progress: @Sendable (LoadStep) -> Void) async throws -> DeviceReading

    /// Asks the device what the plan would change, without changing anything.
    func preview(_ plan: ChangePlan) async throws -> PreviewResult
    /// Applies the plan's timed part (`ChangePlan.commands`). Nothing is final until `confirm`.
    func apply(_ plan: ChangePlan, confirmMinutes: Int, comment: String) async throws -> ApplyResult
    /// Runs the plan's commands that no timer covers (`ChangePlan.operationalCommands`), such as a
    /// Virtual Chassis port role change. Only called after the user acknowledged that.
    func runOperational(_ plan: ChangePlan) async throws
    /// Makes the change waiting for confirmation permanent.
    func confirm(comment: String) async throws
    /// Undoes the change waiting for confirmation right away.
    func revertPending(expectedComment: String) async throws
    /// Returns to an older version from the device's history, again with a timer.
    func rollback(to index: Int, confirmMinutes: Int, comment: String) async throws -> ApplyResult
    /// Throws away uncommitted changes someone else left on the device.
    func discardCandidate() async throws
    /// Diff between two versions from the device's history (0 = the active configuration).
    func compare(rollback older: Int, to newer: Int) async throws -> String
    /// Server power command (Redfish `ComputerSystem.Reset`). Only called after the user confirmed it.
    func power(_ action: ApplianceSnapshot.PowerAction) async throws
}

extension DeviceDriver {
    public func preview(_ plan: ChangePlan) async throws -> PreviewResult { throw DriverError.notSupported }
    public func apply(_ plan: ChangePlan, confirmMinutes: Int, comment: String) async throws -> ApplyResult { throw DriverError.notSupported }
    public func runOperational(_ plan: ChangePlan) async throws { throw DriverError.notSupported }
    public func confirm(comment: String) async throws { throw DriverError.notSupported }
    public func revertPending(expectedComment: String) async throws { throw DriverError.notSupported }
    public func rollback(to index: Int, confirmMinutes: Int, comment: String) async throws -> ApplyResult { throw DriverError.notSupported }
    public func discardCandidate() async throws { throw DriverError.notSupported }
    public func compare(rollback older: Int, to newer: Int) async throws -> String { throw DriverError.notSupported }
    public func power(_ action: ApplianceSnapshot.PowerAction) async throws { throw DriverError.notSupported }
}

/// How a platform handles changes, for the review sheet, the countdown banner and History & backups.
public struct ChangeTraits: Sendable, Equatable {
    public enum History: Sendable, Equatable {
        /// Numbered versions kept on the device (Junos `show system commit`, EdgeOS commit archive).
        case commits
        /// Only Netdeck's own backups.
        case localOnly
    }

    /// Netdeck can stage and apply changes on this platform.
    public var canChange: Bool
    /// Title of the command list in the review sheet ("Junos commands").
    public var commandsTitle: String
    /// The device itself shows the diff and checks the change before it is applied (a candidate configuration).
    public var devicePreview: Bool
    /// One sentence: what the device does when the timer runs out.
    public var timeoutNote: String
    public var history: History
    /// "Go back to this version" is possible.
    public var canRollback: Bool
    /// Timer lengths offered in the review sheet, in minutes.
    public var timerChoices: [Int]

    public init(canChange: Bool, commandsTitle: String, devicePreview: Bool, timeoutNote: String, history: History,
                canRollback: Bool, timerChoices: [Int] = [3, 5, 10]) {
        self.canChange = canChange
        self.commandsTitle = commandsTitle
        self.devicePreview = devicePreview
        self.timeoutNote = timeoutNote
        self.history = history
        self.canRollback = canRollback
        self.timerChoices = timerChoices
    }

    public static let readOnly = ChangeTraits(canChange: false, commandsTitle: t("Commands"), devicePreview: false,
                                              timeoutNote: "", history: .localOnly, canRollback: false)
}

extension Platform {
    public var changeTraits: ChangeTraits {
        switch self {
        case .juniperJunos:
            return ChangeTraits(canChange: true, commandsTitle: t("Junos commands"), devicePreview: true,
                                timeoutNote: "", history: .commits, canRollback: true)
        case .ciscoIOS:
            return ChangeTraits(canChange: true, commandsTitle: t("IOS commands"), devicePreview: false,
                                timeoutNote: t("If you don't confirm, the switch replaces its configuration with the archived copy taken before the change."),
                                history: .localOnly, canRollback: false)
        case .ubiquitiEdgeOS:
            return ChangeTraits(canChange: true, commandsTitle: t("EdgeOS commands"), devicePreview: true,
                                timeoutNote: t("If you don't confirm, the router restarts with its saved configuration. It is offline for a few minutes."),
                                history: .commits, canRollback: false)
        case .arubaAOSCX:
            return ChangeTraits(canChange: true, commandsTitle: t("AOS-CX commands"), devicePreview: false,
                                timeoutNote: t("If you don't confirm, the switch restores the configuration it had before the change."),
                                history: .localOnly, canRollback: false)
        case .arubaAOSS:
            return ChangeTraits(canChange: true, commandsTitle: t("AOS-S commands"), devicePreview: false,
                                timeoutNote: t("If you don't confirm, the switch restores the configuration it had before the change."),
                                history: .localOnly, canRollback: false)
        case .tplinkOmada:
            return ChangeTraits(canChange: true, commandsTitle: t("TP-Link commands"), devicePreview: false,
                                timeoutNote: t("If you don't confirm, the switch restarts with its saved configuration. It is offline for a few minutes."),
                                history: .localOnly, canRollback: false)
        case .mikrotikRouterOS:
            return ChangeTraits(canChange: true, commandsTitle: t("RouterOS commands"), devicePreview: false,
                                timeoutNote: t("If you don't confirm, a scheduled script on the router puts the previous settings back."),
                                history: .localOnly, canRollback: false)
        // Firewalls: read only (see `FortiOSDriver`, `PFDriver`).
        case .fortinetFortiOS, .pfsense, .opnsense, .dellIDRAC, .redfish, .synologyDSM, .truenas, .qnap, .unknown:
            return .readOnly
        }
    }
}
