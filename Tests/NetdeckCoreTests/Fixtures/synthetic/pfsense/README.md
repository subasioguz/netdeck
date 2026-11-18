# pfSense / OPNsense fixtures (synthetic)

These files are **synthetic**. No pfSense or OPNsense unit was available when the module was written. They follow
the FreeBSD `ifconfig(8)` and `arp(8)` output formats, the `/conf/config.xml` layout of both systems (`<interfaces>`
with `<wan>`, `<lan>`, `<optN>`, `<vlans>`, `<laggs>`, `<ppps>`; pfSense writes `<enable></enable>` and CDATA
descriptions, OPNsense `<enable>1</enable>`) and the console menus both show after an SSH login as an administrator.
Replace them with real, anonymized captures once a unit is available.

Unlike the other synthetic folders, each file is the command output alone, without the echoed command or prompt
(`PFFake` in `PFTests` adds those, plus the menu and shell states).

| File | What | Notes |
| --- | --- | --- |
| `pfsense-login-menu.txt` / `opnsense-login-menu.txt` | the screen after logging in | banner with the version, interface list, the two-column menu, "Enter an option:" |
| `*-identity.txt` | `PFParsers.identityCommand` | `key=value` lines; pfSense has `/etc/platform` and `/etc/version`, OPNsense `opnsense-version`; SMBIOS placeholders on the pfSense box |
| `pfsense-ifconfig.txt` | `ifconfig -a` | WAN on DHCP, LAN with a VLAN (`igb1.20`), a port that is down, an unassigned one, two 10G Twinax ports in `lagg0`, and enc0, lo0, pflog0, pfsync0 and an OpenVPN server that are not ports |
| `opnsense-ifconfig.txt` | `ifconfig -a` | a PPPoE WAN (`pppoe0` dialling out on `igb0`, point-to-point address), a 2.5G LAN with a VLAN named `vlan01` |
| `*-arp.txt` | `arp -an` | entries on ports, VLANs and the LAGG, the unit's own (`permanent`) and an incomplete one; one MAC with unpadded octets |
| `pfsense-config.xml` / `opnsense-config.xml` | `cat /conf/config.xml` | the sections above, a disabled interface (no `<enable>`), and a rule description quoting `</pfsense>` and the prompt text inside CDATA |

Assumptions a real unit should confirm: both menus put "Shell" at 8 and "Logout" at 0 (Netdeck still reads the number
for Shell from the screen and refuses without it); option 8 starts a shell for the logged-in administrator and `exit`
returns to the menu; `env -i ... /bin/sh` gives a plain shell with Netdeck's prompt; the administrator can read
`/conf/config.xml` (without it the ports come from ifconfig alone).

Only documentation values are used: addresses from 192.0.2.0/24, 198.51.100.0/24 and 203.0.113.0/24, MAC addresses from
00:00:5e:00:53:xx (RFC 7042), serial `TEST0001`, no passwords, hashes or keys.
