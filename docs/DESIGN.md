# Netdeck design spec (v1)

Native macOS app (SwiftUI, macOS 26+) for managing network devices: switches first, then routers,
firewalls, storage, server BMCs and access points. The UI is English-first and localized to Turkish
(§8). All values are in points (1 CSS px in the mockups = 1 pt).

Design working files (mockups, references, Turkish string table) are kept outside this repository.
This document is self-contained: every value needed to build the UI is written here.

**Mockup language.** Mockups made after the English-first decision are in English: `00-overview`,
`01-ports-rooms`, `07-add-device`, `07b-add-device-manual`, `07c-add-device-basic`, `11-settings`.
The earlier ones (`direction-*`, `01-ports*`, `02`–`06`, `08`–`10`) show Turkish UI text. Their layout,
states and values are current; take the wording from §9.

**Sample data.** Serial numbers, MAC addresses and the USB adapter name in the English mockups and in
this document are anonymized the same way as the test fixtures (`PE0000000001`, `b0:7b:25:00:00:0b`,
`cu.usbserial-1410`). Friendly names such as "Server 1 iDRAC" are user-given names.

---

## 0. Direction

Three directions were shown for the main Ports screen (`mockups/direction-a/b/c.png`):

| Direction | One line |
|---|---|
| **A · Studio** (chosen) | Light theme; white rounded cards inside a neutral grey window frame; the switch sits on a light "studio stage" like a product shot, connected devices are callout cards wired to their ports, and the inspector sits right under the panel with a notch pointing at the selected port. |
| B · Night showroom | Dark theme; the switch under a spotlight, VLAN colors glow under the ports; port cards below and a glass detail panel on the right. |
| C · Rooms map | Light theme; VLAN-colored cables drop from the switch into "rooms" (VLANs) that hold device cards; the screen itself explains what a VLAN is. |

**The user chose A, with C as a second view.** The Ports screen has a **Ports | Rooms** segmented
control: *Ports* is A's bottom inspector (default); *Rooms* is C's cables-into-rooms view under the
same faceplate, and clicking a device card there opens the same edit form as a popover
(`01-ports-rooms.png`). B shaped the dark mode.

### Principles
1. **The device is the hero.** Front and rear panels are drawn like the real hardware: brushed dark
   metal, rack ears and screws, real RJ-45 mouths (latch slot, contact pins), LED windows, SFP+ cages,
   a plugged DAC cable.
2. **State is always visible.** Up / no link / disabled / warning / change staged can be read off the
   panel; the legend says what each means.
3. **Nothing is applied by itself.** Every edit becomes a staged change; a black bar shows the count;
   applying only happens from the review sheet, with a safety timer (`commit confirmed`).
4. **Plain words first, jargon in brackets.** "One network (access)", "Several networks (trunk)",
   "A VLAN is a room inside the switch".
5. **A calm UI.** No continuous animation (the user cares about CPU). Only the connecting spinner and
   the countdown update, once per second.

---

## 1. Tokens

### 1.1 Colors (light / dark)

| Token | Light | Dark | Use |
|---|---|---|---|
| `frame` | `#EBEBEE` | `#0E0F11` | Window background; the sidebar sits on it without a card |
| `surface` | `#FFFFFF` | `#17181B` | Cards, sheets, inspector |
| `surface2` | `#F7F7F8` | `#1D1E22` | Inset areas inside cards (code, info boxes, table group rows) |
| `surface3` | `#F0F0F2` | `#25262B` | Segmented track, active nav row, neutral pill |
| `border` | `#E4E4E8` | `#2A2B31` | Hairlines, inner card borders |
| `borderStrong` | `#D5D5DB` | `#3A3B42` | Input borders, secondary button border |
| `text1` | `#111114` | `#F3F3F5` | Primary text |
| `text2` | `#55555F` | `#A6A6B0` | Secondary text |
| `text3` | `#8C8C96` | `#74747E` | Labels, captions, timestamps |
| `text4` | `#B9B9C1` | `#4E4E57` | Placeholder, disabled |
| `accent` | `#2F6BFF` | `#5B8CFF` | Selection ring, focus, "change staged" marker, links |
| `accentSoft` | `#EAF0FF` | accent 14% | Changed-field fill, accent pill fill |
| `accentInk` | `#1F4FD1` | `#9DB8FF` | Text on accent fills |
| `primary` | `#111114` | `#F3F3F5` | **Primary button (black)**; inverted in dark mode |
| `onPrimary` | `#FFFFFF` | `#111114` | Primary button label |
| `good` / `goodSoft` / `goodLine` / `goodInk` | `#16A34A` / `#E7F7EC` / `#BDE7CA` / `#157A3B` | `#3DD68C` / 12% / 28% / `#6EE3A6` | Connected, success |
| `warn` / `warnSoft` / `warnLine` / `warnInk` | `#F59E0B` / `#FFF5E1` / `#F8DBA6` / `#A2560A` | `#FFB224` / 12% / 30% / `#FFC95C` | Warnings, countdown, "on trial" |
| `danger` / `dangerSoft` / `dangerLine` / `dangerInk` | `#E5484D` / `#FDECEC` / `#F6C7C8` / `#C02F35` | `#FF6369` / 12% / 30% / `#FF8F93` | Errors, delete |

A percentage in the dark column means the base color of that row at that opacity (`Color(hex).opacity(0.12)`).

**Hardware colors (same in both modes, the device is physical):**

| Token | Hex | Use |
|---|---|---|
| `ledGreen` | `#3BE37A` | Link LED (glow: same color, shadow radius 1.6 panel units) |
| `ledAmber` | `#FFB020` | Warning LED, SFP warning |
| `ledAmberDim` | `#C98A1A` | Standby (backup line), no glow |
| `ledOff` | `#1A1E22` | Unlit LED |
| `plateLabel` | `#A3ACB5` | Silkscreen (port numbers) |
| `plateLabelDim` | `#5C656D` | Disabled port number |
| `plateLabelSel` | `#FFFFFF` | Selected port number |
| `metalAccent` | `#3B76FF` | Selection glow and "change staged" badge on the panel |

### 1.2 VLAN palette

Ten colors, spaced around the hue wheel so they read both as thin bars on the dark faceplate and as
chips on white cards. Green, red and amber are deliberately missing: they carry LED and status meaning.
A new VLAN gets the next unused color. **Slate is only for VLAN 1 (default).**

| # | Name | `base` (bar, dot) | `soft` light | `ink` light | `soft` dark | `ink` dark |
|---|---|---|---|---|---|---|
| 1 | Violet | `#8E62F8` | `#F0EAFE` | `#5F35C9` | base 18% | `#BBA0FF` |
| 2 | Orange | `#F7893B` | `#FEEEE2` | `#B2541A` | base 16% | `#FFB283` |
| 3 | Sky | `#2AA9E0` | `#E2F4FC` | `#12729C` | base 16% | `#7CCDF0` |
| 4 | Teal | `#22B39B` | `#E0F6F2` | `#137767` | base 16% | `#6FD8C6` |
| 5 | Mustard | `#E0AE2A` | `#FBF3DA` | `#8A6611` | base 16% | `#F0CB68` |
| 6 | Orchid | `#D45BC9` | `#FAE8F8` | `#9C3092` | base 16% | `#EC97E3` |
| 7 | Cobalt | `#4F6EF7` | `#E9EDFE` | `#2E46C2` | base 18% | `#A3B4FF` |
| 8 | Pink | `#F06292` | `#FDE8EF` | `#B7335F` | base 16% | `#F89DBC` |
| 9 | Lime | `#8CC63F` | `#EEF7E1` | `#557A1E` | base 16% | `#B7E07D` |
| – | Slate (default) | `#8A94A6` | `#EEF0F4` | `#4E5868` | base 16% | `#B7C0CF` |

Current mapping for sw-01 (stored by Netdeck, never written to the switch): `default 1 → Slate`,
`mgmt 10 → Sky`, `infra 20 → Teal`, `storage 30 → Mustard`, `firstboot 40 → Orchid`,
`cust-01 100 → Violet`, `cust-01-oob 150 → Orange`.

### 1.3 Pastel avatars (connected devices) and type tiles

| Name | Fill light | Icon light | Fill dark | Icon dark |
|---|---|---|---|---|
| lavender | `#EEE9FE` | `#6A48DB` | `#8E62F8` 20% | `#C3AEFF` |
| mint | `#E2F5EA` | `#1F8650` | `#3DD68C` 16% | `#7FE3B0` |
| sky | `#E1F0FC` | `#1E6CB3` | `#2AA9E0` 18% | `#8AD3F3` |
| peach | `#FDEADB` | `#BC5E1C` | `#F7893B` 18% | `#FFB98A` |
| rose | `#FCE6EE` | `#BF386A` | `#F06292` 18% | `#F89DBC` |
| butter | `#FAF1D2` | `#93700F` | `#E0AE2A` 18% | `#F0CB68` |
| slate | `#ECEEF2` | `#5A6372` | `#8A94A6` 18% | `#C1C8D4` |

Defaults: modem → peach, server 1 → sky, server 2 → mint, this Mac → lavender, unknown / DAC → slate.
**Device type tiles** (sidebar, overview, add-device) are neutral: 32 pt (40 pt large), radius 9 (11),
`surface3` fill with a `text1` icon; the selected type and device cards on the overview use the dark
variant (`#1F2328` fill, white icon; inverted in dark mode).

### 1.4 Typography (SF Pro / SF Mono only, system fonts)

| Role | Size / line | Weight | Note |
|---|---|---|---|
| `title1` (screen title, "sw-01") | 22 / 28 | semibold | tracking −0.4 |
| `portTitle` (inspector "ge-0/0/2") | 20 / 26 | semibold | tracking −0.3 |
| `sheetTitle` | 18 / 24 | semibold | |
| `banner` (countdown title) | 16 / 21 | semibold | digits `.monospacedDigit()` |
| `cardTitle` | 15 / 20 | semibold | |
| `body` | 13 / 18 | regular | default |
| `bodyStrong` | 13 / 18 | semibold | row titles |
| `callout` | 12.5 / 17 | regular | descriptions |
| `caption` | 12 / 16 | regular; semibold for field labels | |
| `chip` | 11.5 / 14 | medium | pills |
| `micro` | 11 / 14 | regular | table helpers; location headings 11 semibold, tracking +0.6, uppercase |
| `mono` | SF Mono 12 / 20 | regular | Junos commands, diffs, MAC addresses |
| `countdownRing` | 19 | bold, monospacedDigit | "4:32" inside the ring |
| `percent` | 26 | bold, monospacedDigit | "42%" while connecting |
| Faceplate silkscreen | 7.2 panel units | semibold | scales with the panel (§5) |

Weight 650 in the mockups = `.semibold`, 550 = `.medium`. Every numeric field (port numbers, times,
counters) uses `.monospacedDigit()`.

### 1.5 Spacing, radii, shadows

- **Spacing scale:** 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 32. Gap between cards 12; card padding 16–20; form fields 12–16 apart.
- **Corner radius:** card 16 · stage (faceplate background) 14 · inner box / card in card 12 · sheet 18 · button / input 8 (large button 10) · segmented track 9, segment 7 · pill 999 (capsule) · port chip 6 · avatar circle. All `.continuous`.
- **Shadows (SwiftUI `shadow(color:radius:x:y:)`; CSS blur ≈ 2 × SwiftUI radius):**

| Name | Light | Dark |
|---|---|---|
| `card` | 1 pt border black 3.5% (overlay stroke) + black 4%, r 1, y 1 | 1 pt border white 5%, no shadow |
| `raised` (callout, selected card) | black 8%, r 12, y 8 + black 5%, r 1, y 1 | black 45%, r 15, y 10 + border white 6% |
| `sheet` | black 22%, r 32, y 24 + black 8%, r 3, y 2 | black 60%, r 40, y 30 + border white 8% |
| `stagedBar` | black 18%, r 15, y 10 | same |
| Faceplate floor shadow | ellipse, black 22%, blur 14, starts 14 pt above the chassis bottom edge | black 70% |

---

## 2. Window and layout

- **Window:** default 1440 × 900, minimum **1280 × 800**. Hidden title bar (`.windowStyle(.hiddenTitleBar)`), traffic lights inside the sidebar (x 18, y 18).
- **Regions (at 1440 wide):**

```
┌ sidebar 248 ───────┬ main column (4 left, 14 right inset) ───────────────────────┐
│ traffic lights     │ Header row 52                                               │
│ brand              │ [global confirmation banner 56, only when a device waits]   │
│ All devices        │ [device countdown banner 96, on that device's own screens]  │
│ HOME               │ Board card (flexible):                                      │
│  └ device card     │   card header 54 · stage 330 · inspector (rest)             │
│     + section nav  │                                                             │
│ DATA CENTER        │ Staged-changes bar 56 (only with ≥1 staged change)          │
│ + Add location     │                                                             │
│ connection box     │                                                             │
│ Settings ⌘,        │                                                             │
└────────────────────┴─────────────────────────────────────────────────────────────┘
vertical gaps 12 · outer top/bottom inset 14
```

- **Sidebar (248):** on `frame`, no card. Top to bottom: traffic lights → brand (28 pt black square logo, radius 8, + "Netdeck" 15 semibold) → **All devices** row (34 high, radius 10; white with `card` shadow when active; count on the right) → **location groups** → "+ Add location" → connection box (connection type, adapter or host, Last read, Last backup of the selected device) → "Settings ⌘," at the very bottom.
  - **Location group:** heading in `micro` uppercase (`HOME`, `DATA CENTER`; user-named), disclosure chevron, device count on the right; context menu: Rename location, Delete location (only when empty). Devices can be dragged between groups. An empty group shows a dashed "+ Add a device here" row.
  - **Device row:** type tile (§1.3), name 13 semibold, model 11 `text3`, then badges: staged count (18 pt `accent` capsule, white number) **or** countdown (18 pt `warn` capsule, dark text, e.g. "4:32"), then the status dot. The selected device expands into a white card (radius 12) with the section nav: Ports 48 + 4, VLANs 7, Connected devices 12, History & backups. Nav rows 30 high; active row `surface3` + semibold.
  - **Grouping is optional:** Settings → General → "Group devices by location". Off = one plain "Devices" heading with a flat list (the mockups' earlier flat sidebar). Keep grouping isolated in the sidebar model so it can be removed without touching anything else.
- **Header row (52):** `title1` + status pill; a secondary line under it (model · OS version · serial). Right: "Last read 14:32" + **Read again** (secondary) + "…" menu.
- **Board card:** white, radius 16. Header: card title + summary pills + on the right `Front | Rear`, `Ports | Rooms` and a list icon button.
- **Stage:** inside the card with 12 pt side insets, radius 14, radial gradient (light: center `#FFFFFF` → `#F6F6F8` at 62% → `#EFEFF2`; dark: `#24262B` → `#1A1B1F` → `#141518`), 1 pt `border` inside. The faceplate is centered with 20 pt on each side; 74 pt callout space above; legend in the bottom 44 pt.
- **Inspector:** the lower part of the board card under the stage; three columns `290 | flexible | 318`, 1 pt dividers, padding 18/20. A rotated 18 pt square **notch** on its top edge lines up with the selected port's x and pokes into the stage. It slides 0.2 s ease-out when the selection changes.
- **Staged-changes bar:** under the board card, full width, 56 high, radius 14, `#121215` (dark mode `#F3F3F5`). Takes no space when there are no staged changes.
- **At 1280 wide:** the main column is ~1010 → faceplate scale k ≈ 0.91 (ports ~22 × 18 pt). Inspector columns `270 | flexible | 290`. Callouts follow the overlap rule in §4.6.
- **Text room for two languages:** layouts must take ±35% text length (§8). Buttons and pills hug their content; fixed-width containers (segments, callouts, inspector column 1, overview metric tiles) truncate with a tooltip rather than wrap; no fixed-width text container narrower than 120 pt.

---

## 3. Screens

### 3.1 All devices (overview) · `00-overview.png`
- Header: "All devices" + "2 locations · 1 device"; subtitle "Each device has its own connection, staged changes and confirmation timer."; right: **Read all again** (secondary), **Add device** (black).
- **Global confirmation banner** (§3.8) when any device waits.
- One section per location (heading in `micro` uppercase + count + "…" menu). Grid: device cards (flexible).
- **Device card:** radius 16; header with dark type tile (40), name 16 semibold, model · OS version, and pills on the right (countdown pill "Awaiting confirmation · 4:32" in `warn`, status pill). Body: a small realistic faceplate on a mini stage (radius 12, same gradient). Five metric tiles (`surface2`, radius 10): enabled ports (8 / 52), up, warnings (`warnInk` number), devices seen, staged changes. Footer: "Last read · Last backup" + **Open**. A card waiting for confirmation gets a 1.5 pt `warnLine` outline.
- **No promises in the UI:** Netdeck never shows "Coming soon" items. Something it can't do is shown disabled, or not at all (§10.6).
- **Empty location:** a dashed row "No devices in this location yet" + hint + **Add a device here**.
- **Serial cables card:** each detected USB serial adapter: name, "USB serial adapter · 9600 baud", owner pill "In use by sw-01" + "This serial cable is currently used by sw-01." + **End session** (disabled while that device waits for confirmation: "sw-01 is waiting for confirmation. Finish that first.").

### 3.2 Ports · front · `01-ports.png`, dark `01-ports-dark.png`
- Summary pills: `● 3 up` (good), `4 no link` (outline), `40 disabled` (outline), `⚠ 2 warnings` (warn).
- Stage: the faceplate plus **callouts**: the device on a top-row port above the panel, on a bottom-row port below it. Here: Home modem (ge-0/0/0), Server 2 iDRAC (ge-0/0/2), Server 1 iDRAC (ge-0/0/1). The DAC cables hang below the panel and end in one callout "2× MikroTik 25G DAC · Warning".
- Legend (bottom strip of the stage): "VLAN" + the VLAN chips in use · divider · Up / No link / Disabled / Warning / Change staged · right-aligned "Top row even, bottom row odd numbers".
- Inspector (ge-0/0/2 selected): column 1 identity (port name + status pill, "Port 2 · block 1, top row · copper", **Port enabled** switch, Speed, Speed setting, Name on the switch); column 2 settings (Description, "How many networks on this port?" with two option cards, VLAN picker); column 3 connected device (avatar, name + pencil, vendor/model, MAC, IP, LLDP, "Open in Connected devices →").
- Nothing selected: "Click a port" + a summary (warnings list, connected devices list) instead of the inspector.
- List icon: a table of all ports (Port, Description, Status, VLAN, Speed, Connected device); selection and inspector behave the same.

### 3.3 Ports · Rooms view · `01-ports-rooms.png`
- Same header and faceplate; `Ports | Rooms` shows **Rooms**. No callouts and no legend: the stage grows to the bottom of the board card and the inspector area is not shown.
- Faceplate 22 pt from the stage top. 78 pt below it, one **room** per VLAN in use, roughly under its ports: rounded rect (radius 16) in the VLAN `soft` color with a 1 pt `base` 22% border; heading = color square + name + ID + "3 ports" / "4 slots". Inside, **device cards** (radius 12, white): avatar, name, sub line, LED dot + port name, blue dot if a change is staged. Ports without a cable are outlined cards ("No cable" + port description). DAC slots show "25G DAC · Seen as 1G" with a `warnLine` outline.
- **Wires:** cubic curves from each port (chassis bottom edge; SFP from the cage bottom) to the top of its card, in the VLAN `base` color: 3 pt solid when there is a link or a module, 1.6 pt dashed (4/4) at 75% when the port is configured but has no cable. A dot of the same color where the wire leaves the panel.
- VLANs without ports: "Rooms with no ports yet" + chips, bottom right.
- **Clicking a device card** opens the **same edit form** as the Ports inspector, as a popover (540 wide, notch on the card): port name + status + staged pill + Port enabled switch + close; Description (with "Was … · Undo") and VLAN (room) side by side; "How many networks on this port?" segmented; footer row with the connected device + "All details →" (switches to the Ports view with that port selected).

### 3.4 Ports · rear · `01-ports-rear.png`
- Pills: `4 QSFP+ · no module`, `Console connected` (accent), `● Power and fans OK`.
- Rear panel left to right: **PSU 0** (JPSU-350-AC-AFO-A, AC inlet, handle, green "AC OK" LED), **PSU 1 blank**, **Fan 0, Fan 1** (grille, green LED, "AFO →"), port block: **4 × QSFP+ 1/0–1/3** (dashed bar = Virtual Chassis role), **MGMT** (me0), **CON** (a light-blue console plug while Netdeck is connected), **USB**.
- Callouts: Power supply 1 (slot empty), 4× QSFP+ · Virtual Chassis, Console · "Netdeck is connected through this port" + `Active`; below: Power supply 0, Fans 0 and 1, Management port · me0 · 192.168.1.228/24 · no cable.
- Inspector (QSFP+ 1/0): role, status, "Name as a network port: et-0/1/0", speed; "What should this port be used for?" → Virtual Chassis (stacking) / Network port; **amber box**: the role is changed by an operational command (`request virtual-chassis vc-port`), not by a commit, so the safety timer does not cover it; right column "This slot is empty".
- MGMT selected: IP, no link, hint to use SSH once a cable is in. CON: "Netdeck is connected through this port · 9600 baud". PSU / fans: info only.

### 3.5 VLANs · `02-vlans.png`
- Header "VLANs" + "7 VLANs · sw-01"; right: Read again + **New VLAN** (black).
- Explanation card: small "rooms" drawing + **"A VLAN is a room inside the switch."** + "Devices in the same room see each other… The internet is only in the room where the modem is connected: cust-01 today."
- Three-column room cards (158 high): 4 pt VLAN color on the left edge, color square, name, description, ID badge, port chips with LED dots, bottom line (avatars / "Internet" pill / "Empty room · no ports in this VLAN"). Order: VLANs in use first, then empty rooms, then a dashed "+ New VLAN" card.
- Right panel (396): edit the selected VLAN: Name, Number (locked), Description, Color (10 squares; "Colors are only shown in Netdeck…"), **mini port map** (§4.14), port list, "Delete VLAN" (disabled with the reason while it has ports).
- Adding, renaming and deleting are staged changes too.

### 3.6 Connected devices · `03-connected.png`
- Header + "12 devices · on 3 ports"; search (⌘F) + Read again.
- Table card: filter segments (All 12 / ge-0/0/0 10 / ge-0/0/1 1 / ge-0/0/2 1), `LLDP: no neighbors` pill, "Hide unnamed".
- Grouped by port: group row (LED, port, switch description, VLAN chip, what is behind it, MAC count). Rows: avatar + name (or faded "✎ Give it a name"), MAC (mono), Vendor ("Unknown" when the OUI is not known), IP, Port, action. More than 5 MACs → "Show N more MACs".
- "This Mac" row: when a MAC matches one of this Mac's interfaces, show `Netdeck runs here`. (The user's MAC is a USB LAN adapter on a dock; its vendor is not confirmed → "Unknown".)
- Right panel (372): name field, icon picker (6 icons), MAC / vendor / IP / port / LLDP; **suggestion box** when the port description doesn't match the device name: "Change the switch description to … too?" → **Add to changes** (still staged, never applied directly). Note: names and icons stay on this Mac.

### 3.7 History & backups · `04-history.png`
- Left card (452): segments (All / Switch history / Local backups); **clock warning** ("The switch clock is about 18 days behind and NTP is off…"); timeline: local backup row (disk icon, `Local`), commit rows (#, note or faded "No note", date, who · how, pills `Safe commit · 5 min`, `Confirmed the previous one · no config change`), collapsed "7 more versions (#4–#10)".
- Right card: selected version title; "Compare #2 → #1" pickers + change count; **plain-language summary** (~ / + / − badges); `Switch diff | Full configuration` tabs + the real diff (red/green rows, line numbers); footer note "Going back also goes through Review changes first…" + Export + **Go back to this version…** (black).
- The diff in the mockup is the real output from `Tests/NetdeckCoreTests/Fixtures/rollback-compare-2-0.txt`.

### 3.8 Review changes · `05-review-sheet.png`
- Sheet 800 wide, 20 pt from the window top, max 862 high, scrim black 32%.
- Title: 40 pt black square icon + "Review changes" + "sw-01 · 3 changes · compared with the current switch config (14:33)".
- **What will change:** one row card per change: dark port pill (blue dot), plain title, before → after (struck-through old value, bold new value, VLANs as chips), grey note, amber risk note when needed; `✕ Remove` on the right.
- Two boxes: **Safety timer** (3 / 5 / 10 min segments, default 5) and **Before applying** checks (backup will be taken · no one else has uncommitted changes · commit check passed). While a check runs it shows a spinner; a failed check shows a red ✕ and **Apply is disabled**.
- **Technical details** (collapsible; collapsed by default, open in the mockup): `Junos commands N | Switch diff` + Copy; mono code block. **Device output is never translated.**
- Note field ("written to the switch history") → commit comment.
- Footer: "Esc to close · your changes are kept" · Cancel · **Apply · 5 min trial** (black, paperplane icon).
- VC port role changes get their own row with an amber warning and a checkbox "I understand the safety timer can't undo this"; Apply stays disabled until it is ticked.

### 3.9 Waiting for confirmation · `06-countdown.png` and the global banner
- **Device countdown banner** (on that device's own screens, below the header, cannot be dismissed): `warnSoft` fill, `warnLine` border, 72 pt ring (track warn 18%, arc warn, proportional to the time left), "4:32" in the ring; title "Confirm within **4:32** or the switch rolls back"; description; pills (Switch responds · ge-0/0/0, 1, 2 still up · Backup taken); right: **Roll back now** (secondary), **Confirm** (black, large).
- Changed ports get an amber clock badge; legend "On trial". Header pill `Awaiting confirmation · 4:32`. The staged-changes bar is hidden meanwhile.
- The inspector area shows three columns: changes on trial · "Check before confirming" (Is the internet working? [Test], Does Server 2 iDRAC open? [Open], Netdeck is still connected) · "What happens next?" timeline (14:34 Applied → Now → 14:39 Automatic rollback).
- **Global banner** (`00-overview.png`, on every other screen while any device waits): 56 high, radius 14, warn colors, 32 pt ring, "sw-01 is waiting for your confirmation · 4:32" + "If you don't confirm, the switch rolls back at 14:39. Other devices are not affected." + **Open sw-01 →**, **Roll back now**, **Confirm**. With several devices: "2 devices are waiting for your confirmation", the soonest timer, and a menu per device.
- Last 60 s: ring and number turn `danger`; system notification if Netdeck is in the background. Confirmed: the banner turns green for 3 s ("Changes are permanent…") and disappears. Timed out: grey banner "The switch rolled back (14:39). Your changes are staged again." Lost connection: "Connection lost. The switch rolls itself back at 14:39." + Reconnect.

### 3.10 Add device · `07-add-device.png`, `07b-add-device-manual.png`, `07c-add-device-basic.png`
Sheet 860 wide; the body scrolls, the header and footer stay pinned.
1. **What are you adding?** Seven type tiles in one row (icon, name, one-line hint): Switch · Router · Firewall · Storage (NAS) · Server (iDRAC / IPMI) · Wireless (access point) · Other. The selected tile has a dark icon tile and a 1.5 pt `text1` border. The same icons are used in the sidebar and the overview.
2. **Connection** (option cards with a radio): Serial console · SSH · API (HTTPS). Methods a type doesn't support are disabled with the pill "Not available for this type":

| Type | Serial console | SSH | API (HTTPS) |
|---|---|---|---|
| Switch | yes | yes | – |
| Router | yes | yes | – |
| Firewall | yes | yes | – |
| Storage (NAS) | – | yes | yes |
| Server (iDRAC / IPMI) | – | – | **only** (Redfish) |
| Wireless (AP) | – | yes | yes |
| Other | yes | yes | – |

3. **Brand and model:** "Detect automatically (recommended)" is the default: after connecting, Netdeck reads vendor, model and OS (`DeviceDetector`). "Let me pick the brand and model" opens a two-level picker (`07b`): brand tiles in a 4-column grid (Juniper · MikroTik RouterOS · Cisco IOS / IOS-XE · Ubiquiti · Dell iDRAC · Synology DSM · TrueNAS · Other) with a status pill (Supported / Basic), then the family row for the chosen brand (Juniper: EX, SRX, MX, QFX). Every listed brand is Supported; "Other" is Basic. Support flags come from the device catalog, not from the UI.
4. **Connection details** in an inset box: serial → Port (detected adapters with a "Plugged in" or "In use by sw-01" pill) + Speed (9600 / 19200 / 115200); SSH → Address + Port (22); API → URL. Then Username + Password (Keychain note).
   **Serial cable in use** (`07b`): "This serial cable is currently used by sw-01. Testing will end that session first. sw-01 keeps its staged changes." Blocked while sw-01 waits for confirmation.
5. **Test result card** after "Test connection":
   - Recognized and fully supported (`07`): green card, check tile, "Juniper EX4300-48T · Junos 21.2R3.8 · recognized as a switch", details (hostname, serial, what full support means), `Full support` pill. Primary button **Add and read**.
   - Recognized, no driver (`07c`, example values): accent card, type tile, "HPE 2530 recognized", "… · Netdeck shows basic information for this device", four mini tiles (Model, OS version, Uptime, Shown as: Info card, no panel), `Basic support` pill. Primary button **Add with basic info**.
   - Already in the list: "This is sw-01, which is already in your list." and the primary button becomes **Open**.
   - Failure: the error cards of §3.13 in compact form inside the sheet.
- Footer: **Test connection** + result line (e.g. "● Login OK · EX4300-48T") · Cancel · primary.
- First run (`07`): the sidebar shows only All devices (0) and "Add device"; the main area shows a skeleton faceplate and "Add your first device".

### 3.11 Basic-support device screen (no mockup)
A device with basic support has no faceplate, Ports, VLANs or Connected devices. Its nav shows only **Overview** (and History & backups when the platform allows config export). The Overview card shows a type tile, name, Model, OS version, Uptime, Serial, Last read, and the note "Netdeck shows basic information for <brand>. It only reads this device; it never changes it." The features it lacks are listed under "Not available for this device", without any promise. No staged changes are possible.

### 3.11b Appliance screen (servers and NAS over HTTPS, no mockup)
Devices added with **API (HTTPS)** (Dell iDRAC over Redfish, Synology DSM, TrueNAS) have only **Overview**. Same card as §3.11: header with a health pill (Healthy / Warning / Critical) and a power pill; a stage with the type tile, vendor + model and software version; below it alerts (warn box), Summary tiles (model, serial, software, uptime and the facts the device gives), storage pools with a usage bar, disks, sensors (temperatures, fans), power supplies, network interfaces and firmware versions; on the right a green "Netdeck only reads this device over its API" box and the connection facts. Self-signed certificates are trusted on first use and pinned, like SSH host keys.

### 3.12 Connecting · `08-connecting.png`
- Header pill `Connecting · serial console` (accent), Read again disabled, blue sidebar dot.
- **Skeleton faceplate** on the stage (port outlines only, unlit LEDs, a faint sheen moving left to right; no sheen with Reduce Motion).
- Lower area: big percentage + "Reading sw-01 · Serial console · 9600 baud · about 12 s left" + Cancel; overall progress bar; steps: Connected to the serial port → Logged in → Reading the configuration (sub-progress) → Ports → MAC table → Closing the session (logout). Finished steps show their time ("0.4 s"). Right: "Why does this take a while?" and a green "Read only" box.
- If the last read is younger than 24 h, the last known panel is shown at 50% with a "Last known state · yesterday 22:10" label instead of the skeleton.

### 3.13 Connection errors · `09-connection-errors.png`
The app shows **one** error card at a time in the inspector area (the mockup shows four side by side). Header pill `Couldn't connect` (danger), black **Try again** top right.
1. **Wrong password** (red key tile): raw output `Login incorrect`, new password field, Change user · **Save and connect**. No automatic retries.
2. **Serial cable not found** (amber plug tile): 3-step checklist + mini rear panel (CON selected, no plug), port picker + Rescan. The list refreshes on its own when an adapter appears.
3. **The switch has uncommitted changes** (amber triangle): raw line, Show diff · Discard these changes… (danger, still through review) · **Continue read-only**. Apply is disabled everywhere while this holds.
4. **The switch isn't responding** (grey timer tile): 2-step checklist, Change speed · **Try again**.
Same card layout for: port open in another app (screen, minicom), SSH address unreachable, SSH host key changed, connection dropped while reading.

### 3.14 Settings · `11-settings.png`
A standard Settings window (⌘,), 700 wide, toolbar tabs **General · Devices · Safety · Backups**; label column right-aligned (170), controls left.
- **General:** Language `System | English | Türkçe` (System is the default) + help text; Appearance `System | Light | Dark`; Device list: "Group devices by location" switch + locations list (drag to reorder, rename, "+ Add location"); Notifications: "Notify me 1 minute before a confirmation timer runs out".
- **Safety:** Default safety timer (3 / 5 / 10 min), "Always back up before applying" (on and locked).
- **Backups:** Backup folder (`~/Library/Application Support/Netdeck/backups`) + Show in Finder.

### 3.15 Component sheet · `10-components.png`
Ten port-cell states, four SFP states, the VLAN palette (on white and on the faceplate), buttons, pills, progress-step and device-row states. Worth rebuilding as SwiftUI `#Preview`s.

---

## 4. Components and states

### 4.1 Port cell (RJ-45)
Geometry in §5.3. States combine (e.g. Up + Selected + Change staged).

| State | Mouth | LEDs (latch-side corners) | VLAN bar | Number | Extra |
|---|---|---|---|---|---|
| **Up** | Plug inserted: clear grey boot + cable cross-section circle | left `ledGreen` + glow | yes | `plateLabel` | |
| **No link** | Black mouth, 8 contact pins visible | both `ledOff` | yes | `plateLabel` | |
| **Disabled** | 45° hatch (`#1E2226` / `#2B3036`, 3-unit pitch) | not drawn | no | `plateLabelDim` | |
| **Selected** | unchanged | | | white, heavier | 1.5-unit white ring (2.8 units out, r 4) + 3.2-unit `metalAccent` 55% outside it |
| **Warning** | unchanged | right `ledAmber` + glow | | | amber triangle badge (10.8 units) on the outer corner |
| **Standby** (RTG backup) | plug inserted | left `ledAmberDim`, no glow | | | |
| **Change staged** | unchanged | | bar shows the new value | | r 5 `metalAccent` circle + white pencil on the latch-side outer corner, 1.5-unit chassis-colored edge |
| **On trial** (awaiting confirmation) | | | | | same spot, r 5 `ledAmber` circle + clock |
| **Several networks (trunk)** | | | bar split into one segment per VLAN (1-unit gaps) | | |
| **Hover** | | | | | 1-unit white 40% ring; tooltip after 0.4 s (port, description, VLAN, state) |

- **Top row** (even numbers): latch slot up, LEDs in the top corners, number and VLAN bar above. **Bottom row** (odd): everything mirrored.
- The hit area is larger than the port: 27 × 25 units (the port pitch).

### 4.2 SFP+ / QSFP+ cage
- Cage: metal gradient (`#B9C1C8 → #8D969F → #6B747D`), black mouth 2.2 units inside; 8 × 1.6 spring tab at the bottom center.
- **Empty:** black mouth. **DAC plugged:** metal plug in the mouth (`#D3D8DD → #8C959E`, two ridges) + dark cable cross-section (r 5.6) + an 8.5-unit dark cable (`#121417`, 1.4-unit white 13% highlight) hanging below the panel. **Module + link:** plug + green LED. **Warning:** `ledAmber` LED + triangle. LED above the cage (5 × 2.6); VLAN bar below; number at the bottom, drawn over the cable with a 2.2-unit chassis-colored outline.
- QSFP+ cage 46 × 26; in the Virtual Chassis role the VLAN bar becomes a dashed empty bar (`#8B959E`, 2 / 1.6).

### 4.3 VLAN chip
Height 24 (small 20, large 28), capsule; fill `soft`, text `ink` 12 medium, inner border `base` 22%. A 10 × 10 (small: 8) radius-3 `base` square on the left; the ID after the name at 70% opacity: `■ cust-01 100`.

### 4.4 Status pill
22 high, 11.5 medium, capsule; kinds: good / warn / danger / accent (fill `soft`, text `ink`, 1 pt `line` border), outline (clear + `borderStrong`), neutral (`surface3`), dark (`primary`). Leading 6 pt dot or 12 pt icon.

### 4.5 Legend
Bottom strip of the stage, 11.5 text. "VLAN" + small VLAN chips · 16 pt vertical divider · glyph + label pairs (16 × 12 mini port: with LED / empty / hatched / amber LED; 12 pt accent dot). Right-aligned hint.

### 4.6 Callout (connected-device bubble)
40 high, radius 12, white, `raised` shadow; 24 pt pastel avatar + two lines (name 12 semibold; sub 11 `text3`: "ge-0/0/2 · Dell R640 · 192.168.1.118"). The selected port's callout has a 1.5 pt `accent` ring; a warning callout has a `warnLine` border and a `Warning` pill.
**Leader line:** 1.2 pt `borderStrong` (`accent` when selected, `#F0B24A` for warnings); starts at an r 3 ring on the chassis edge, goes straight out, turns horizontal halfway between panel and card (corner r 6), ends at the card center.
**Placement:** top-row port → 64 pt above the panel; bottom-row → 12–22 pt below. Cards stay 14 pt inside the stage; a card that overlaps another moves to whichever side of it is closer, 12 pt apart. **More than 6** known devices: show only the selected and hovered port's callout; the others become 8 pt pastel dots above the port number.

### 4.7 Inspector form
- Field label 12 semibold `text2`; input 32 high, radius 8, 1 pt `borderStrong` inside; focus: 1 pt `accent` + 3 pt `accent` 22% halo.
- **Changed field:** fill `accentSoft` 55%, border `accent` 55%; below it: blue dot + "Was ~~R640-PVE-01~~" + "↶ Undo" on the right (`accentInk`).
- **Option card** (one / several networks, port role, connection type, brand mode): radius 10, 1 pt `borderStrong`; selected: 1.5 pt `text1` border and a filled radio (5 pt inner ring).
- **Switch row** (Port enabled): `surface2` box + 34 × 20 switch (`good` when on).
- **Value list:** 32-high rows, `text3` label on the left, medium value on the right, 1 pt `border` between.

### 4.8 Table
Header 11.5 semibold `text3`, 30 high; rows 46; group rows 40, `surface2`; selected row `accentSoft` 60%; first column 20 pt left inset. MACs in mono.

### 4.9 Staged-changes bar
56 high, radius 14, `#121215`. Left: 28 pt accent square with the count (13 bold, white) · two lines ("3 changes staged, not sent to the switch yet" 13 semibold white / "Nothing changes on the switch until you review and confirm." 12 white 60%) · change pills (24 high, white 8%) · right: **Discard all** (white 8%) and **Review changes →** (white fill, black text, 36 high). Colors invert in dark mode.
"Discard all" asks in a popover: "Discard 3 staged changes? Nothing was sent to the switch." [Cancel] [Discard all].

### 4.10 History row
Padding 10/10, radius 12; a 28 pt avatar node (person initial; disk icon for local backups) with a 2 pt `border` line under it; title 13 semibold (`text3` "No note" when empty), `#n` on the right; sub line 11.5 `text3` + pills. Selected row `surface2` + 1.5 pt `text1` border. Collapsed range row with a 10 pt dot.

### 4.11 Device row (sidebar)
Status dot 8 pt + 3 pt halo: Connected `good`, Connecting `accent`, Awaiting confirmation `warn`, Couldn't connect `danger`, Not connected `text4` (no halo). Badges as in §2.

### 4.12 Progress step
24 pt circle: done = filled `good` + white tick; running = `accentSoft` ring + a rotating 90° `accent` arc (one turn per 0.9 s; static with Reduce Motion); queued = 2 pt `borderStrong` ring, `text3` text; failed = filled `danger` + ✕. 2 pt line between circles (`good` 50% under finished steps). Time on the right (12, monospacedDigit).

### 4.13 Global confirmation banner, device countdown banner
§3.9.

### 4.14 Mini port map
48 copper (4 blocks × 6 × 2, top row even) + 4 SFP; squares 9 × 9 (SFP 12 × 10), gap 2, 7 between blocks, radius 2.5. Filled `base` = member; `soft` fill + 1.5 pt `base` border = joins with a staged change; others `surface3` + 1 pt `border`.

### 4.15 Room and room device card (Rooms view)
§3.3. Room radius 16, padding 10, gap 8; device card radius 12, padding 9; popover radius 16, `sheet` shadow, notch 16 pt.

### 4.16 Type tile and type picker tile
Type tile §1.3. Picker tile: radius 12, padding 9/8, 1 pt `borderStrong`; selected: `surface2` fill, 1.5 pt `text1` border, dark type tile.

---

## 5. Front and rear panel drawing (SwiftUI `Canvas` recommended)

### 5.1 Units and scale
Everything is in **panel units (u)**. Chassis 1000 × 118 u. Front drawing area x −31…1031, y −2…118 + 44 (44 u for hanging DAC cables; 4 without cables). Scale `k = width_pt / 1062`. In a 1440 window k ≈ 1.05 (port ≈ 25 × 21 pt). Rear drawing area x −2…1002, y −2…120 (no rack ears at the back).
Hit testing: compute each port's `CGRect` from the formulas below; put transparent buttons over the `Canvas` or use one `onTapGesture(coordinateSpace:)` with a hit test.

### 5.2 Chassis
- Chassis `0,0,1000,118`, r 2; vertical gradient `#3B4148` (0) → `#30363C` (0.07) → `#252A2F` (0.6) → `#1B1F23` (1).
- Brushed metal: 0.45 u horizontal lines every 1.3 u, white 2.8%. In SwiftUI a small tiled image (`ImagePaint`) or a loop in the `Canvas`.
- Top edge 1.1 u white 16%, bottom edge 1.2 u black 55%, side edges 1 u black 50%. In dark mode add a 1 pt white 6% outline around the chassis so it separates from the dark stage.
- **Rack ears:** x −30…1 and 999…1030, gradient `#363C42 → #202428`, r 2.5; each with two 20 × 10 r 5 slots (`#0E1012`, y 17 and 91) holding r 5.6 screws (radial `#E9ECEF → #9BA4AC → #626B73`, `#4B535B` cross).
- **Left section:** "EX4300-48T" at (16, 21), 8.4 u bold `#D2D8DE`, tracking 0.4 · "JUNIPER" at (16, 31), 5.6 u semibold `#7F8A94`, tracking 1.1 (plain text, never the logo) · LEDs 5 × 3 u at (16, 45/55/65): SYS green, ALM off, MST green; labels at x 25, 5.6 u · **hostname label** at (15, 82), 54 × 15, r 1.6, `#F4F2EA`, shadow y 1.2 blur 1.2 45%, with "sw-01" in 8.2 u bold `#16181B`. The label text is the device name.
- The model text, LED set and port layout come from a per-model panel description; other models get their own description (§10).

### 5.3 Copper ports
- Block starts `GX = [100, 272, 444, 616]`, pitch 27 u, port 24 × 20 u.
- Port n (0…47): `g = n/12`, `k = n%12`, `col = k/2`, `row = k%2` → `x = GX[g] + col*27`, `y = row == 0 ? 35 : 60`.
- Block shield: `(GX − 4.5, 31.5, 168, 52)`, r 2.4, gradient `#5D666F → #4A525A → #3D444B`, 0.5 u `#69727B` border, 0.6 u white 22% highlight on top.
- **Mouth shape:** 24 × 20 rectangle (corner r 1.2) with an 11 × 4 u notch in the middle of the latch side. Top row: notch up; bottom row: notch down. Fill gradient `#020304 → #101317` (lighter away from the notch), 0.6 u black 70% border.
- Contact pins (empty mouth only): on the side opposite the notch, 8 lines of 3 u starting at x + 5.2, 1.95 apart, 0.65 u `#B08E52` 55%.
- Plug inserted: body 1.6 u inside the mouth (`#E6EAEE → #AEB7C0`, r 1.6, 0.5 u `#7F8993` border) + 9 × 4 latch in the notch (`#C3CAD1`) + an r 4.4 cable cross-section (radial `#F6F7F8 → #B4BCC4`) in the middle of the body.
- LEDs 4.4 × 2.6 u, r 0.7: top row (x + 1, y + 0.6) and (x + 18.6, y + 0.6); bottom row y + 16.8. Left = link, right = status / warning.
- VLAN bar 23 × 2.6 u, r 1.3: top row y 27.6, bottom row y 85.
- Number 7.2 u semibold, centered, baseline y 24.4 (top) / 95.6 (bottom).

### 5.4 Uplink module (PIC 2) and SFP+
- Module plate `(789, 21, 202, 76)` r 3, gradient `#2C3137 → #1F2327`, 1 u `#0F1113` border, two r 3.6 screws at (797.5, 59) and (982.5, 59); "4× SFP+ 10G" at (807, 33.5), 5.8 u, and "PIC 2" right-aligned.
- Cage i (0…3): `x = 807.5 + i*43`, `y = 47`, 36 × 22. LED (x + 15.5, 41.4, 5 × 2.6). VLAN bar y 72.2. Number baseline y 84.
- DAC cable: cubic curve down from the plug center (cx, cy + 1.5) to x = cx − 14 (cage 0) / cx + 10 (cage 1), y = 118 + 44.

### 5.5 Rear panel
- PSU bays (14, 12, 150, 94) and (170, …). Filled PSU: grille (62 × 74, hex holes 5 × 4.4 u), C14 AC inlet, U handle (3.2 u `#7E8892`), green "AC OK" LED, "PSU 0 · 350W". Empty: blank plate, two screws, "PSU 1 · EMPTY".
- Fans: (336, 12, 104, 94) and (448, …); r 34 round hex grille, r 7 hub, green LED top left, "FAN n" and "AFO →" at the bottom.
- Port block plate (574, 21, 410, 76): "4× QSFP+ 40G · PIC 1"; QSFP+ i at (588 + i*54, 44, 46 × 26), LED y 38.6, role bar y 74, number "1/i" y 86 · MGMT mouth (820, 47) · CON mouth (868, 47; `#7FB8E6` console plug while Netdeck is connected) · USB (912, 52, 20 × 9) · ground screw (962, 40).

### 5.6 SwiftUI notes
- Replace the SVG blur glow by drawing the LED twice (the lower copy `.blur(radius: 1.6·k)`) or with `GraphicsContext.addFilter(.shadow(color:radius:))`.
- Draw the panel in one `Canvas`; no `drawingGroup()` needed; redraw only when state changes, no animation. Callouts, wires and leader lines go in a separate layer (`ZStack` + `Path`).
- Port numbers and labels with `context.draw(Text(...))`, font size `7.2·k`.
- The stage needs about 74 pt above and 100 pt below the panel for callouts and DAC cables (§2).

---

## 6. Interaction rules

1. **Staging:** every edit (description, enable/disable, mode, VLAN, VLAN add / delete / rename, VC role) becomes a local staged change: a blue pencil badge on the panel, a "Was …" line under the field, the count in the bar. Staged changes are stored per device on disk and survive a restart.
2. **Applying only from the review sheet:** Apply stays disabled until the checks pass (backup, no foreign candidate changes, commit check). Every apply is `commit confirmed N` (default 5).
3. **Countdown:** while a device waits, its banner shows on its screens and the global banner on all others. New edits can be staged, but no new Apply until it is confirmed or rolled back.
4. **VC port role** is an operational command outside the commit: it gets its own row in the review sheet with an amber warning and an acknowledgment checkbox.
5. **Foreign candidate changes (switch busy):** read-only mode. Fields still work (staging is allowed) but Apply is disabled, with the reason next to it.
6. **Many devices:** each device has its **own session, staged changes and timer**. Reading, staging and confirming on one device never touch another. The sidebar and overview show each device's badges independently; the global banner aggregates them.
7. **Serial exclusivity:** one USB serial adapter serves one device session at a time. Pickers show "In use by sw-01"; connecting another device through it first ends that session (sw-01 keeps its staged changes); ending is blocked while that device waits for confirmation. Serial sessions are logged out when a read finishes.
8. **Locations:** user-named groups, stored on this Mac only; drag devices between them; an empty location can be deleted; grouping can be switched off.
9. **Keyboard:** ←/→ move along a row, ↑/↓ switch between rows, ⌘R read again, ⌘↩ open review, ⌘F search, Esc closes sheets, ⌘, settings. ⌘-click selects several ports (bulk edit: enable/disable, VLAN).
10. **Animation:** selection ring and notch 0.2 s ease-out; system sheet animation; nothing else moves continuously. Reduce Motion stops the skeleton sheen and the spinner.
11. **Accessibility:** every port has an `accessibilityLabel` ("Port 2, up, 1 gigabit, VLAN cust-01, Server 2 iDRAC"); state is never color-only (legend, pills, text). Body text contrast ≥ 4.5:1 in light mode (`text3` only for secondary info).

---

## 7. SF Symbols

The mockups use stroke icons that stand in for SF Symbols (weight `.medium`, size equal to the text or 1 pt smaller). Check the names in the SF Symbols app and pick the closest one if a name differs.

| Mockup icon | SF Symbol |
|---|---|
| plus / x / check | `plus` / `xmark` / `checkmark` |
| chevron down / up-down / arrow right | `chevron.down` / `chevron.up.chevron.down` / `arrow.right` |
| alert (badge) | `exclamationmark.triangle.fill` |
| info | `info.circle` |
| refresh (Read again) | `arrow.clockwise` |
| history | `clock.arrow.circlepath` |
| undo | `arrow.uturn.backward` |
| layers (VLAN, Rooms) | `square.3.layers.3d` |
| **type: Switch** (ports glyph) | `rectangle.connected.to.line.below` |
| **type: Router** | `wifi.router` |
| **type: Firewall** | `shield.lefthalf.filled` (no brick-wall symbol exists) |
| **type: Storage (NAS)** | `externaldrive.connected.to.line.below` |
| **type: Server** | `server.rack` |
| **type: Wireless** | `wifi` |
| **type: Other** | `shippingbox` |
| All devices | `square.stack.3d.up` |
| laptop / devices | `laptopcomputer` / `laptopcomputer.and.iphone` |
| ethernet | `cable.connector` |
| terminal (console, test) | `terminal` |
| pencil | `pencil` |
| search | `magnifyingglass` |
| lock / key | `lock` / `key` |
| plug (serial) / USB adapter | `powerplug` / `cable.connector.horizontal` |
| unplug (DAC, no cable) | `cable.connector.slash` if present, else `bolt.horizontal.circle` |
| timer | `timer` |
| shield | `checkmark.shield` |
| compare | `arrow.left.arrow.right` |
| more | `ellipsis` |
| bolt (PSU) / fan | `bolt` / `fan` |
| drive (backup) | `externaldrive` |
| download (export) | `square.and.arrow.down` |
| list | `list.bullet` |
| tag / trash / copy | `tag` / `trash` / `doc.on.doc` |
| circle check | `checkmark.circle` |
| send (Apply) | `paperplane` |
| sliders (Settings) | `slider.horizontal.3` |
| globe (language) | `globe` |
| folder (empty location) | `folder` |
| eye / cpu | `eye` / `cpu` |

---

## 8. Localization

- **Development language: English.** Every user-facing string goes through `t("English text")`; translations live in `<lang>.lproj/Localizable.strings` (Turkish today). The Turkish values are in `strings-tr.md`.
- **Language setting:** Settings → General → Language: **System** (default) / **English** / **Türkçe** (each language is listed by its own name). System follows the macOS preferred languages; if none is available, English is used. The menu bar picks the new language up on the next launch.
- **Never translated:** device output (commands, diffs, logs, raw error lines such as `Login incorrect`), interface names (`ge-0/0/2`), VLAN names, user-given names and descriptions, model names, units like "Gbps" and "baud".
- **Placeholders:** all `%@`; numbers are passed as `String`. Plural forms ("1 device" / "2 devices") are separate strings.
- **Room for text:** design every label for ±35% length. Examples from the mockups: "Port enabled" is longer than its Turkish counterpart and needed `white-space: nowrap` and a wider popover; "Review changes" is much shorter than its Turkish version. Test both languages at 1280 × 800.
- **Dates and times:** formatted with the user's locale (`Date.FormatStyle`); 24-hour clock follows the system setting.

---

## 9. UI strings (English)

English text is the key (§8). Turkish translations of the same rows: `strings-tr.md`.
`%@` marks a placeholder. Device output is never part of this list.

### General and window chrome

| English |
|---|
| Netdeck |
| All devices |
| Devices |
| Add device |
| Add a device here |
| Add location |
| Rename location |
| Delete location |
| Settings |
| Ports |
| VLANs |
| Connected devices |
| History & backups |
| Overview |
| Serial console |
| SSH |
| API (HTTPS) |
| %@ baud |
| Last read |
| Last read %@ |
| Last backup |
| Read again |
| Connected |
| Connected · %@ |
| Connecting · %@ |
| Awaiting confirmation · %@ |
| Couldn't connect |
| Not connected |
| serial console |
| Serial %@ |
| Cancel |
| Close |
| Undo |
| Copy |
| Save |
| Open |
| Unknown |
| Today %@ |
| Yesterday %@ |
| %@ s |

### Global confirmation banner

| English |
|---|
| %@ is waiting for your confirmation |
| %@ devices are waiting for your confirmation |
| If you don't confirm, the switch rolls back at %@. Other devices are not affected. |
| Open %@ |
| Roll back now |
| Confirm |

### All devices (overview)

| English |
|---|
| %@ locations · %@ devices |
| Each device has its own connection, staged changes and confirmation timer. |
| Read all again |
| %@ device |
| %@ devices |
| enabled ports |
| up |
| warnings |
| devices seen |
| staged changes |
| Last read %@ · Last backup %@ |
| Router |
| Watch and manage your gateway and internet connection from here too. |
| Add router |
| Storage (NAS) |
| Disk health, shares and backups at a glance. |
| Add storage |
| No devices in this location yet |
| When the servers move to the data center, drag %@ here or add a new device. |
| Serial cables |
| A serial cable can serve only one device at a time. |
| USB serial adapter · %@ baud |
| In use by %@ |
| This serial cable is currently used by %@. |
| End session |
| %@ is waiting for confirmation. Finish that first. |

### Ports screen

| English |
|---|
| Front panel |
| Rear panel |
| Front |
| Rear |
| Rooms |
| List |
| 48 copper ports (1G) · 4 SFP+ slots (10G) |
| 4 QSFP+ (40G) · management · console · power · fans |
| %@ up |
| %@ no link |
| %@ disabled |
| %@ warnings |
| VLAN |
| Up |
| No link |
| Disabled |
| Warning |
| Change staged |
| On trial |
| Top row even, bottom row odd numbers |
| Working |
| No cable or module |
| Virtual Chassis role |
| Seen from the back: power, fans, ports from left to right |
| %@ QSFP+ · no module |
| Console connected |
| Power and fans OK |
| 2× MikroTik 25G DAC |
| %@ and %@ · switch reads them as 1G |
| Power supply %@ |
| %@ · working |
| Slot empty · optional spare |
| Fans 0 and 1 |
| Normal · airflow out (AFO) |
| 4× QSFP+ · Virtual Chassis |
| 1/0–1/3 · no module |
| Console |
| Netdeck is connected through this port |
| Active |
| Management port · me0 |
| %@ · no cable |
| Selected port |
| %@ change staged |
| %@ changes staged |
| Port %@ · block %@, top row · copper |
| Port %@ · block %@, bottom row · copper |
| Port enabled |
| Turning it off disconnects the device on it. |
| Speed |
| %@ · full duplex |
| Speed setting |
| Automatic |
| Name on the switch |
| Description |
| Was |
| How many networks on this port? |
| One network |
| One VLAN room. For servers, modems, iDRAC. (access) |
| Several networks |
| Several VLANs share one cable. For another switch or a hypervisor. (trunk) |
| One network (access) |
| Several networks (trunk) |
| Devices in the same VLAN see each other; devices in other VLANs don’t. |
| VLAN (room) |
| Connected device |
| MAC |
| IP |
| LLDP |
| The device doesn't announce itself |
| Open in Connected devices |
| All details |
| Click a port |
| Click a port on the panel to see and edit it. |
| MikroTik XS+DA0001 25G DAC plugged in. The switch reads it as 1G (%@). A 10G SFP+ DAC may be needed. |
| Home modem |
| Server %@ iDRAC |
| No cable |
| Seen as 1G |
| %@ slots |
| %@ ports |
| Rooms with no ports yet |
| QSFP+ %@ |
| Rear panel · 40G · PIC 1, port %@ |
| Current role |
| Virtual Chassis port |
| Status |
| No module or cable |
| Name as a network port |
| What should this port be used for? |
| Virtual Chassis (stacking) |
| To run as one device with another EX switch. There is no second switch today. |
| Network port |
| Becomes a normal 40G port (%@). Connect a server or an uplink and pick a VLAN. |
| The safety timer can't undo this change |
| The role is changed by a separate command, not by a commit (request virtual-chassis vc-port). Review asks you to confirm it separately. |
| Each of the four ports can have its own role. If you don't plan a second switch, "Network port" makes sense. |
| This slot is empty |
| When a QSFP+ module or DAC is plugged in, its model, speed and far end show here. |

### Staged changes bar

| English |
|---|
| %@ changes staged, not sent to the switch yet |
| Nothing changes on the switch until you review and confirm. |
| Discard all |
| Discard %@ staged changes? Nothing was sent to the switch. |
| Review changes |
| %@ description |
| Redundant internet |

### VLANs

| English |
|---|
| %@ VLANs · %@ |
| Rooms inside the switch. Every port belongs to one room, or to several. |
| New VLAN |
| A VLAN is a room inside the switch. |
| Devices in the same room see each other; devices in other rooms don't. The internet is only in the room where the modem is connected: %@ today. |
| Learn more |
| Internet |
| %@ ports · %@ up |
| no devices connected |
| Empty room · no ports in this VLAN |
| Name |
| Number |
| Color |
| Colors are only shown in Netdeck. They are not written to the switch. |
| Ports in this room |
| Filled: in this room · outlined: joins with a staged change |
| Joins this room |
| Staged change |
| Delete VLAN |
| Move the %@ ports in this room to another VLAN before deleting it. |
| Default · no internet |

### Connected devices

| English |
|---|
| %@ devices · on %@ ports |
| The switch's MAC table and LLDP neighbors. Names you give are stored only on this Mac. |
| Search MAC, name or vendor |
| All |
| LLDP: no neighbors |
| Hide unnamed |
| Device |
| MAC address |
| Vendor |
| Port |
| Give it a name |
| This Mac |
| Netdeck runs here |
| Show %@ more MACs |
| %@ MACs |
| Home modem %@ (%@) and the devices behind it |
| Icon |
| Port description differs: %@ |
| Change the switch description to "%@" too? It is added to staged changes and only applied after you confirm. |
| Add to changes |
| Name and icon are stored only on this Mac, never on the switch. |

### History & backups

| English |
|---|
| %@ versions · %@ local backups |
| The switch's own commit history and the backups Netdeck took. Compare any version and go back to it if you want. |
| Back up now |
| Switch history |
| Local backups |
| The switch clock is about %@ days behind and NTP is off. Commit dates follow the switch clock. |
| Netdeck backup |
| Local |
| Taken automatically on first read |
| Taken automatically before applying |
| %@ (Mac time) |
| No note |
| Safe commit · %@ min |
| Confirmed the previous one |
| no config change |
| %@ more versions (#%@–#%@) |
| Compare |
| %@ changes |
| Switch diff |
| Full configuration |
| Going back also goes through "Review changes" first. Nothing is sent to the switch without your confirmation. |
| Export |
| Go back to this version… |
| %@ removed from the disabled ports group (UNUSED), so it was enabled |
| %@ description: %@ |
| %@ put on VLAN %@ as one network |
| %@ became an edge port: if another switch is plugged in, the port shuts itself down |

### Review changes

| English |
|---|
| %@ · %@ changes · compared with the current switch config (%@) |
| What will change |
| Remove |
| Description changes |
| Prepared as a 10G uplink |
| The slot is empty now. It starts working when a 10G module or DAC is plugged in. |
| Redundant internet uplink (RTG) |
| %@ becomes the primary line and %@ the backup. If one fails, the other takes over within seconds. |
| %@ is where the internet comes in today. The internet may drop for a few seconds while applying. |
| empty |
| Safety timer |
| The changes run as a %@-minute trial. If you don't confirm, the switch rolls back on its own, even if you lose the connection. |
| %@ min |
| Before applying |
| The current config will be backed up |
| No one else has uncommitted changes on the switch |
| Syntax check passed (commit check) |
| Someone else has uncommitted changes on the switch |
| The switch didn't accept the commands |
| Technical details |
| Junos commands |
| Note |
| written to the switch history |
| Esc to close · your changes are kept |
| Apply · %@ min trial |
| I understand the safety timer can't undo this |

### Confirmation countdown

| English |
|---|
| Confirm within %@ or the switch rolls back |
| %@ changes were applied as a %@-minute trial. If everything looks fine, confirm. If you lost the connection, do nothing; the switch rolls back on its own. |
| Switch responds |
| %@ still up |
| Backup taken · %@ |
| Changes on trial |
| Check before confirming |
| Is the internet working? |
| Test |
| Does %@ open? |
| Netdeck is still connected to the switch |
| If something went wrong, choose "Roll back now" or wait: at %@ the switch goes back on its own. |
| What happens next? |
| %@ · Applied |
| commit confirmed %@ · backup taken |
| Now · Waiting for you |
| If you confirm, it becomes permanent and goes into the history |
| %@ · Automatic rollback |
| Without confirmation the switch returns to #%@ |
| Changes are permanent · saved as #0 in the history |
| The switch rolled back (%@). Your changes are staged again. |
| Connection lost. The switch rolls itself back at %@. |
| Reconnect |
| If you don't confirm within 1 minute, the switch rolls back. |

### Add device

| English |
|---|
| Add your first device |
| Netdeck connects over a serial cable, SSH or an API, reads the device and draws it. Nothing changes until you review and confirm. |
| Netdeck only reads while adding. Nothing on the device is changed. |
| What are you adding? |
| Switch |
| Ports and VLANs |
| Gateway |
| Firewall |
| Security gateway |
| Storage |
| NAS |
| Server |
| iDRAC / IPMI |
| Wireless |
| Access point |
| Other |
| Anything else |
| Connection |
| USB serial cable to the console port. No network needed. |
| Over the network, through the management port. |
| Redfish or REST · iDRAC, IPMI, NAS |
| Not available for this type |
| Brand and model |
| Detect automatically (recommended) |
| After connecting, Netdeck reads the vendor, model and OS. |
| Let me pick the brand and model |
| Choose from a list. Useful if detection fails. |
| Brand |
| %@ family |
| the exact model and OS version are still read after connecting |
| Supported |
| Basic |
| Basic info only |
| Data center switch |
| Plugged in |
| Speed (baud) |
| Address |
| Username |
| Password |
| Stored in the macOS Keychain. It never leaves this Mac. 9600 is the Junos console default. |
| Testing will end that session first. %@ keeps its staged changes. |
| %@ · %@ · recognized as a %@ |
| Hostname %@ · serial %@ · full support: front panel, ports, VLANs, history |
| Full support |
| %@ recognized |
| %@ · Netdeck shows basic information for this device |
| Basic support |
| Model |
| OS version |
| Uptime |
| Shown as |
| Info card, no panel |
| Test connection |
| Testing… |
| Not tested yet |
| Login OK · %@ |
| Add and read |
| Add with basic info |
| This is %@, which is already in your list. |

### Basic-support device screen

| English |
|---|
| Basic information |
| Netdeck shows basic information for %@. It only reads this device; it never changes it. |

### Connecting and errors

| English |
|---|
| Reading %@ |
| %@ · %@ baud · about %@ s left |
| Connected to the serial port |
| Connected to the device |
| Logged in |
| Reading the configuration |
| Link state and speeds |
| MAC table |
| Who is on which port |
| Closing the session |
| The console is released (logout) |
| Why does this take a while? |
| A serial console carries about 1 KB per second, so a full read takes around 20 seconds. With a cable on the management port (MGMT) and SSH it drops to a few seconds. |
| Read only |
| Nothing on the switch changes while connecting. Changes are only sent after you review and confirm them. |
| Reading ports… |
| The panel fills in when reading finishes. The last known state is hidden because it is older than a day. |
| Last known state · %@ |
| Last successful read %@ |
| Try again |
| The switch didn't accept the password |
| The saved password for "%@" was rejected. It may have changed on the switch. Netdeck doesn't retry on its own, to avoid a lockout. |
| New password |
| Saved to the Keychain |
| Change user |
| Save and connect |
| Serial cable not found |
| %@ isn't visible right now. The USB serial adapter may be unplugged or on another port. |
| Make sure the adapter is plugged into the Mac. |
| The other end goes into the CON port on the back of the switch. |
| The port list refreshes on its own once it is plugged in. |
| Rear panel · the cable goes into the CON port |
| Choose port |
| Rescan |
| The switch has uncommitted changes |
| Another session is editing the configuration and hasn't committed. Netdeck won't write over someone else's work. Until you decide, it only reads and applying stays off. |
| Show diff |
| Discard these changes… |
| Continue read-only |
| The switch isn't responding |
| The port opened but no prompt came for %@ seconds. The switch may be booting (an EX4300 takes a few minutes) or the speed (baud) is wrong. |
| Is the SYS light on the front of the switch green? |
| The speed should be 9600 (the Junos default). |
| Change speed |
| The port is open in another app (screen, minicom) |
| SSH: the address can't be reached |
| SSH: the host key changed |
| The connection dropped while reading |

### Settings

| English |
|---|
| General |
| Safety |
| Backups |
| Language |
| System |
| English |
| Türkçe |
| System follows your macOS language, currently %@. If that language isn't available, Netdeck uses English. Switch output (commands, diffs, logs) is never translated. |
| The menu bar updates the next time Netdeck opens. |
| Appearance |
| Light |
| Dark |
| Device list |
| Group devices by location |
| Turn this off to show one plain Devices list in the sidebar. Locations are only stored on this Mac. |
| Notifications |
| Notify me 1 minute before a confirmation timer runs out |
| The switch rolls back on its own if you don't confirm in time. The notification is only a reminder. |
| Default safety timer |
| Always back up before applying |
| Backup folder |
| Show in Finder |

---

## 10. Things to watch in SwiftUI

1. **Don't use the system `.inspector()`.** The design's inspector is the lower part of the board card, tied to the selected port by the notch. Build it as `VStack { stage; inspector }`; the notch x is `cx · k + stage offset`.
2. **Shadow radius:** use half of the CSS blur as the SwiftUI `radius` (the table in §1.5 is already converted).
3. **Weights:** SF has no 650/550; use `.semibold` and `.medium`.
4. **Dark mode:** define tokens as Any/Dark pairs in the asset catalog. The primary button and the staged-changes bar invert. Hardware colors stay the same; add the 1 pt white 6% chassis outline in dark mode.
5. **One `Canvas` per panel:** about 600 shapes; redrawn only when state changes. LED glow through a `GraphicsContext` shadow filter. A small tiled image is enough for brushed metal.
6. **No "Coming soon" anywhere.** Unsupported options are disabled without a promise. App Review rejects promises of unreleased features (guidelines 2.1 and 2.3).
7. **Trademarks:** the panel shows "JUNIPER" and the model as plain text, never a logo. Keep vendor brands out of the app icon, screenshots and store text.
8. **Uplink slot names:** a cage shows up as `ge-0/2/N` or `xe-0/2/N` depending on the optic; the two DAC slots read as `ge-0/2/0` and `ge-0/2/1` (1G) today. The mockups use the brief's `xe-0/2/0`. Keep the physical label ("SFP+ 0") fixed, show the Junos name the switch currently uses, and explain the mismatch in the warning text.
9. **VC ports** are missing from `show interfaces terse`; the rear QSFP+ state comes from `show virtual-chassis vc-port` ("Configured / Absent"). Role changes are operational commands outside `commit confirmed` (§6.4).
10. **Switch clock ~18 days behind:** history dates follow the switch clock; Netdeck's own backups are labeled "Mac time" (§3.7).
11. **Command and diff text:** the commands in the review sheet are illustrative; the real text comes from `ChangePlanner` and the `show | compare` of the preview. The history diff is the real fixture output.
12. **Recognizing "This Mac":** compare with this Mac's own interface MACs. The OUI database must be local (no network lookups).
13. **Callout density:** apply the "more than 6" rule of §4.6 or the stage gets busy once the data center fills up.
14. **Nothing writes directly to a device:** "Add to changes", "Go back to this version", "Discard these changes…", "Roll back now" and "Confirm" either go through the review sheet or act on the pending `commit confirmed` from the countdown banner.
15. **Support levels are data:** Full / Basic come from the device catalog (`Model/DeviceCatalog`), so the add-device sheet and overview update without UI changes. How a platform applies changes (timer kind, history, device-side preview) is `ChangeTraits` in `Drivers/DeviceDriver.swift`.
16. **Faceplates of other models** are laid out from the port list (`PanelBuilder.arrange`): copper in blocks of 12 on two rows (first port on top; eight or fewer in one row), then each group of cages; the chassis widens when the ports don't fit. The EX4300-48T comes out exactly as §5 describes. The rear face is drawn only for the EX4300.
