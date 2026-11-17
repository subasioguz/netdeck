# Netdeck

**See your network gear the way it looks on the rack, and change it without fear.**

Netdeck is a native macOS app for managing switches and other network devices. It connects over a
serial console or SSH, draws the device's real front and rear panels, shows what is plugged into every
port, and turns your edits into a reviewed, time-boxed change that the device rolls back on its own if
you don't confirm it.

> **Status: early development.** The Junos core is tested against real hardware (EX4300-48T). The drivers
> for the other platforms are written from vendor documentation and covered by unit tests on synthetic
> captures; they have not met real hardware yet. Try them with `netdeck-probe` first (it never applies
> anything) and send captures.

---

## Why

Most small teams and homelab owners manage switches by pasting CLI commands from notes. A typo in the
wrong `interface-range`, or one forgotten `commit`, takes a server off the network, and the person who
made the change is often the one locked out of fixing it.

Netdeck keeps the device's own safety net in place and puts a clear picture on top of it:

- **Know what you have.** Every port, its VLAN, link state, the module in each cage, and the MAC
  addresses and LLDP neighbours behind it, drawn on a faithful faceplate.
- **Say what you want, not how.** "Open port 3 for the management cable" becomes the right `set`
  and `delete` statements, including splitting the disabled-ports range it belongs to.
- **Apply without fear.** Changes go out with `commit confirmed`. If something breaks and you can't
  confirm, the device returns to its previous configuration by itself.

## Features

| | Status |
|---|---|
| Serial console (USB), SSH and HTTPS API connections | Done |
| Login handling for console, shell and CLI prompts; automatic hand-over to the right platform | Done |
| Ports, VLANs, MAC table, LLDP, hardware, optics, commit history | Done |
| Plain-language change plan (edit ports and VLANs) | Done |
| Device-side safety timer on every apply, one-click confirm or revert | Done |
| Rear QSFP+ role changes (Virtual Chassis port ↔ network port) on the EX4300 | Done |
| Automatic config backups before every change | Done |
| Device auto-detection (vendor, model, OS) | Done |
| Front panels drawn per model (68 known panels, generic layout for the rest) | Done |
| Health, storage, sensors and interfaces of servers and NAS (read only) | Done |
| Multiple devices grouped by location, global "awaiting confirmation" banner | Done |
| English and Turkish interface | Done |

## Supported devices

| Platform | Devices | Safety net when you apply | Tested on hardware |
|---|---|---|---|
| Juniper Junos | EX, QFX, SRX (ports, VLANs, security zones), MX (ports) | `commit confirmed` | EX4300-48T, Junos 21.2 |
| Cisco IOS / IOS-XE | Catalyst switches | `configure terminal revert timer` (turns the config archive on if needed), `write memory` only after you confirm | Not yet |
| MikroTik RouterOS 7 | CRS switches, CCR / RB / hEX routers (bridge VLAN filtering) | An undo script and a scheduler on the router run unless you confirm | Not yet |
| Ubiquiti EdgeOS | EdgeRouter | `commit-confirm` (the router restarts with its saved configuration if not confirmed), `save` only after you confirm | Not yet |
| Dell iDRAC (Redfish) | PowerEdge servers | Read only | Not yet |
| Synology DSM, TrueNAS | NAS | Read only | Not yet |

Other devices are recognised when possible and shown with basic information. HTTPS devices with a
self-signed certificate are trusted on first use and pinned, like SSH host keys.

## Safety model

Netdeck is built so that a mistake costs you minutes, never a site visit.

1. **Read-only by default.** Connecting, refreshing and previewing never change the device.
2. **Preview on the device itself.** Your edits are loaded into the candidate configuration, the device
   reports its own diff and `commit check` result, and the candidate is discarded again.
3. **Timed apply.** Changes are committed with `commit confirmed 3/5/10`. Until you press *Confirm*, the
   device will undo them on its own when the timer runs out, even if Netdeck or your connection dies.
4. **Backups first.** The current configuration is saved locally before every apply or rollback.
5. **Hands off other people's work.** If the device already holds uncommitted changes from another
   session, Netdeck stops and shows them instead of building on top of them.
6. **Clean exits.** Serial console sessions are logged out when Netdeck disconnects.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6 toolchain) to build from source
- A USB serial console cable, or SSH access to the device's management interface

## Build and run

```sh
git clone <this repository>
cd netdeck
swift test                     # run the test suite
scripts/make-app.sh --open     # build build/Netdeck.app and open it
```

### Field tool

`netdeck-probe` exercises the same core from the terminal. It is useful for checking a new device or
firmware before using the app. It never commits.

```sh
swift build --product netdeck-probe

# Read everything Netdeck shows (the platform is detected; --platform cisco|mikrotik|edgeos|... forces it)
NETDECK_PASSWORD=... .build/debug/netdeck-probe --serial /dev/cu.usbserial-XXXX --user root snapshot
NETDECK_PASSWORD=... .build/debug/netdeck-probe --api https://192.0.2.30 --user root snapshot

# Ask the device what a change would do, then throw it away
NETDECK_PASSWORD=... .build/debug/netdeck-probe --ssh 192.0.2.10 --user admin \
  preview "set interfaces ge-0/0/2 description uplink"
```

## How it works

```
Sources/
  NetdeckCore/            UI-independent core (fully unit-tested)
    Transport/            Serial console (termios) and SSH (system ssh with a forced TTY)
    CLI/                  Text CLI session shared by the non-Junos drivers (prompts come from a dialect)
    Drivers/              DeviceDriver protocol, driver factory, per-platform change traits
    Junos/                CLI session, output parsers, config model, change planner, driver
    Cisco/ MikroTik/ EdgeOS/  Dialect, parsers, change planner and driver per platform
    API/                  HTTPS client with certificate pinning; Redfish, Synology and TrueNAS readers
    Model/                Snapshots, ports, device kinds and platforms, auto-detection, faceplate catalog
    Session/              Observable per-device state for the UI
    Support/              Backups, device list, Keychain, localization
  Netdeck/                SwiftUI app
  netdeck-probe/          Command-line field tool
Tests/
  NetdeckCoreTests/       Parser, planner, session and detection tests
    Fixtures/             Real console captures (anonymized); synthetic/ holds captures written
                          from vendor documentation until real ones replace them
```

Netdeck talks to devices the same way you would: through their CLI. It reads with `show` commands,
parses the text (including fixed-width tables), and writes with plain `set`/`delete` statements, so
every change is visible as the exact commands the device received.

## Privacy

- Device passwords are stored in the macOS Keychain, never on disk.
- Netdeck only connects to the devices you add. There is no telemetry and no account.
- Backups and device settings stay in `~/Library/Application Support/Netdeck`.

## Localization

English is the development language. Every user-facing string is looked up with `t("English text")`,
and translations live in `Sources/NetdeckCore/Resources/<language>.lproj/Localizable.strings`.
Turkish is included. To add a language, copy `tr.lproj`, translate the values, and add the code to
`CFBundleLocalizations` in `Resources/Info.plist`.

## Contributing

Bug reports with console output are very welcome, especially from devices and firmware versions not
listed above. When sharing captures, remove passwords and hashes, and replace serial numbers and MAC
addresses (keep column alignment in fixed-width tables). See `Tests/NetdeckCoreTests/Fixtures` for
examples.

## License

Copyright 2026 Oğuzhan Subaşı.

Licensed under the [Apache License, Version 2.0](LICENSE). You may use, modify and distribute Netdeck,
including commercially, under the terms of that license. The license does not grant rights to the
Netdeck name or logo.
