# API fixtures (synthetic)

These JSON files are **synthetic**. No iDRAC, iLO, Supermicro, Synology or TrueNAS hardware was available when the API
module was written. They were built from vendor documentation and public captures (Dell iDRAC9 Redfish
API guide, dell/iDRAC-Redfish-Scripting, bmclib fixtures, Synology DSM Login Web API guide,
py-synologydsm-api, truenas/middleware) and should be replaced by real, anonymized captures when
hardware is at hand.

All identifiers are documentation values: IPs from 192.0.2.0/24 and 198.51.100.0/24, MAC addresses
with zeros after the vendor OUI, serials and service tags like `TEST0000001`. No tokens, passwords or
real serials.

Each file is one HTTP response body, exactly as the driver receives it, except the `*-members.json`
files: those are JSON arrays of the collection members the driver fetches one by one
(`EthernetInterfaces/<id>`, `Storage/<id>`, `Drives/<id>`, `Volumes/<id>`).

| File | Request |
| --- | --- |
| `redfish-root-dell.json` | `GET /redfish/v1/` on iDRAC9 (no login) |
| `redfish-root-hpe.json` | `GET /redfish/v1/` on an HPE iLO 5 (read as a generic Redfish BMC) |
| `redfish-hpe-system.json` | `GET /redfish/v1/Systems/1/` on iLO 5 (`Links.ManagedBy`/`Chassis`, reset types listed) |
| `redfish-hpe-manager.json` | `GET /redfish/v1/Managers/1/` (`Model` "iLO 5", firmware "iLO 5 v2.72") |
| `redfish-hpe-manager-nic.json` | `GET /redfish/v1/Managers/1/EthernetInterfaces/1/` (iLO dedicated port) |
| `redfish-hpe-ethernet-members.json` | members of `Systems/1/EthernetInterfaces` (one port down) |
| `redfish-hpe-thermal.json` | `GET /redfish/v1/Chassis/1/Thermal/` (fans in percent, absent DIMM sensor and fan) |
| `redfish-hpe-power.json` | `GET /redfish/v1/Chassis/1/Power/` |
| `redfish-hpe-iml.json` | `GET /redfish/v1/Systems/1/LogServices/IML/Entries/` (old critical, recent warning, OK) |
| `redfish-supermicro-system.json` | `GET /redfish/v1/Systems/1` on a Supermicro BMC (blank `SerialNumber`, reset types only via `ActionInfo`, powered off) |
| `redfish-root-legacy.json` | `GET /redfish/v1/` on old iDRAC 8 firmware (no vendor, `/redfish/v1/Sessions`) |
| `redfish-system.json` | `GET /redfish/v1/Systems/System.Embedded.1` (iDRAC9, `Oem.Dell.DellSystem`, PSU rollup warning, reset types) |
| `redfish-system-idrac8.json` | same on iDRAC 8: no Oem block, Service Tag only in `SKU`, powered off, memory in Dell's "GiB" |
| `redfish-manager.json` | `GET /redfish/v1/Managers/iDRAC.Embedded.1` |
| `redfish-manager-nic.json` | `GET /redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces/NIC.1` |
| `redfish-thermal.json` | `GET /redfish/v1/Chassis/System.Embedded.1/Thermal` (one absent fan) |
| `redfish-thermal-idrac8.json` | same on iDRAC 8: fans named only by `FanName`, one fan critical |
| `redfish-power.json` | `GET /redfish/v1/Chassis/System.Embedded.1/Power` (PSU 2 lost its input) |
| `redfish-ethernet-members.json` | members of `Systems/System.Embedded.1/EthernetInterfaces` |
| `redfish-storage-members.json` | members of `Systems/System.Embedded.1/Storage` (PERC, NVMe direct, empty SATA) |
| `redfish-drive-members.json` | the drives those controllers link |
| `redfish-volume-members.json` | members of the PERC's `Volumes` (one RAID 1 virtual disk) |
| `redfish-sel.json` | `GET .../LogServices/Sel/Entries` (one entry older than 30 days) |
| `synology-query.json` | `GET /webapi/query.cgi?api=SYNO.API.Info&...` |
| `synology-login-2fa.json` | `SYNO.API.Auth login` answer for an account with 2-step verification |
| `synology-dsm-info.json` | `SYNO.DSM.Info getinfo` |
| `synology-core-system.json` | `SYNO.Core.System info` |
| `synology-storage.json` | `SYNO.Storage.CGI.Storage load_info` (SHR pool, degraded RAID 1 pool, crashed drive, M.2 drive) |
| `synology-storage-denied.json` | `load_info` with a non-administrator account (error 105) |
| `synology-network.json` | `SYNO.DSM.Network list` |
| `truenas-system-info-scale.json` | `GET /api/v2.0/system/info` (`system.info`) on SCALE 24.10 |
| `truenas-system-info-core.json` | same on CORE 13 (filler serial) |
| `truenas-pool-scale.json` | `GET /api/v2.0/pool` on SCALE: RAIDZ1 with sizes, degraded mirror |
| `truenas-pool-core.json` | same on CORE 13: no size fields, two mirrors |
| `truenas-disk.json` | `GET /api/v2.0/disk` |
| `truenas-interface.json` | `GET /api/v2.0/interface` (DHCP port, unplugged port, bridge, VLAN) |
| `truenas-alert-list.json` | `GET /api/v2.0/alert/list` (critical, warning with HTML, dismissed, info) |

Unverified fields (not in public documentation): Synology `SYNO.Core.System.up_time` format, disk
`serial`, the `SYNO.DSM.Network` layout; TrueNAS `state.active_media_subtype` wording on SCALE.
