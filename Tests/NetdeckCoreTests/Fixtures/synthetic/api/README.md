# API fixtures (synthetic)

These JSON (and QNAP XML) files are **synthetic**. No iDRAC, iLO, Supermicro, Synology, QNAP or TrueNAS hardware was available when the API
module was written. They were built from vendor documentation and public captures (Dell iDRAC9 Redfish
API guide, dell/iDRAC-Redfish-Scripting, bmclib fixtures, Synology DSM Login Web API guide,
py-synologydsm-api, truenas/middleware, the QNAP answers in python-qnapstats' tests) and should be replaced by real, anonymized captures when
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
| `qnap-probe.xml` | `GET /cgi-bin/authLogin.cgi` without a login (`authPassed` 0, model and firmware) |
| `qnap-login.xml` | `POST /cgi-bin/authLogin.cgi` (`user`, base64 `pwd`): `authPassed` 1 and `authSid` |
| `qnap-login-failed.xml` / `qnap-login-2sv.xml` | a refused login; one that needs a 2-step verification code (`need_2sv`) |
| `qnap-session-ended.xml` | a data call after the session ended (`authPassed` 0 only) |
| `qnap-sysinfo.xml` | `management/manaRequest.cgi?subfunc=sysinfo&hd=no&multicpu=1` (TS-464 on QTS 5.1.4: CPU, memory, two NICs, uptime, a system temperature over its warning limit, a failed fan) |
| `qnap-health.xml` | `manaRequest.cgi?subfunc=sysinfo&sysHealth=1` ("warning") |
| `qnap-volumes.xml` | `management/chartReq.cgi?chart_func=disk_usage&disk_select=all&include=all` (RAID 5 volume with sizes, a single-disk volume without a label in a non-ready state) |
| `qnap-disks.xml` | `disk/qsmart.cgi?func=all_hd_data` (four bays, one SMART warning, an SSD in an expansion unit) |

Unverified fields (not in public documentation): Synology `SYNO.Core.System.up_time` format, disk
`serial`, the `SYNO.DSM.Network` layout; TrueNAS `state.active_media_subtype` wording on SCALE; QNAP `volumeStatus` codes
other than 0 (Ready), `sysHealth` words other than "good", what `authLogin.cgi` returns without a login on QTS 5, and
`authLogout.cgi`; QuTS hero versions (the `hero_model` flag).
