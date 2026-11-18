import Foundation

/// Platform data a change planner needs beyond the neutral `JunosConfig` model. Junos needs none.
public enum VendorState: Equatable, Sendable {
    case none
    case mikrotik(MikroTikState)
    case cisco(CiscoState)
    case edgeos(EdgeOSState)
    case aoscx(AOSCXState)
    case aoss(AOSSState)
    case tplink(TPLinkState)
}

/// Change planners of the platforms other than Junos.
enum VendorPlanners {
    static func plan(snapshot: SwitchSnapshot, ports: [PortEdit], vlans: [VLANEdit]) -> ChangePlan {
        switch snapshot.platform {
        case .mikrotikRouterOS: return MikroTikPlanner.plan(snapshot: snapshot, ports: ports, vlans: vlans)
        case .ciscoIOS: return CiscoPlanner.plan(snapshot: snapshot, ports: ports, vlans: vlans)
        case .ubiquitiEdgeOS: return EdgeOSPlanner.plan(snapshot: snapshot, ports: ports, vlans: vlans)
        case .arubaAOSCX: return AOSCXPlanner.plan(snapshot: snapshot, ports: ports, vlans: vlans)
        case .arubaAOSS: return AOSSPlanner.plan(snapshot: snapshot, ports: ports, vlans: vlans)
        case .tplinkOmada: return TPLinkPlanner.plan(snapshot: snapshot, ports: ports, vlans: vlans)
        default: return ChangePlan(changes: [])
        }
    }
}
