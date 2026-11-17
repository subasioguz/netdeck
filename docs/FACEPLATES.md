# Faceplate catalog

Netdeck draws the front panel of known models the way the hardware looks: port groups from left to right,
how the numbers alternate between rows, blocks, uplink module slots, and the console, management, USB,
reset and DC input ports. Models it doesn't know get the generic layout (copper in blocks of 12 on two
rows, then the cages). The EX4300-24T/48T keep the reference drawing of `DESIGN.md` §5.

## Files

- `docs/faceplates-research.json`: the research notes, one entry per front panel, with sources and what
  could not be verified. Edit this file when a model is wrong or missing.
- `scripts/faceplates-import.py`: turns the notes into the catalog the app reads.
- `Sources/NetdeckCore/Resources/Faceplates/faceplates.json`: the generated catalog (`FaceplateCatalog`).

```sh
python3 scripts/faceplates-import.py docs/faceplates-research.json
```

Models are matched by prefix on the model name the device reports (Junos `show chassis hardware`, IOS
model number, RouterOS `board-name`, EdgeOS `HW model`); the longest prefix wins. Ports are matched by
name, then (Junos) by FPC/PIC/port under any media prefix, then (IOS) by slot path when the kind matches.
Ports the spec doesn't name go into the model's module slot (uplink modules), else after everything.

## Field order

`top-even` (Juniper: 0 on top), `top-odd` (Cisco: 1 on top), `bottom-first` (MikroTik CRS/CCR: 1 at the
bottom), `single-row`, `top-first-half`.

## Not verified against a drawing

74 panels were researched from vendor hardware guides, datasheets and product images (2026-11-17).
These notes list what could not be confirmed; check them against real hardware when you can:

- **EX2300-24T**: width_mm nominal (17.4 in class). non-PoE 24T drawing not viewed; the guide says the layout matches the PoE model.
- **EX2300-48T**: width_mm nominal.
- **EX2300-C-12P**: width_mm (compact, rack-mountable with a kit). me0 as the management interface name.
- **EX3400-24T**: width_mm nominal.
- **EX3400-48T**: width_mm nominal.
- **EX4100-24T**: PIC numbering et-0/1/x for the VC ports and xe-0/2/x for the uplinks (not stated on the pages read).
- **EX4100-48T**: PIC numbering of the VC ports and uplinks.
- **EX4100-F-12T**: Junos names of the VC ports (xe-0/1/0..3 vs xe-0/0/12..15). rear multigig uplink names (likely mge-0/2/0..1). width_mm.
- **EX4100-F-24T**: PIC numbering of the VC ports and uplinks.
- **EX4100-F-48T**: PIC numbering of the VC ports and uplinks.
- **EX4300-24T**: width_mm nominal (17.5 in). drawing is low-resolution; top-even order follows the 0/1 labels under the first column.
- **EX4300-48T**: width_mm nominal.
- **EX4300-32F**: width_mm nominal.
- **EX4300-48MP**: row order (no port labels on the drawing). which half is ge vs mge follows the callouts (left = 1G, right = multigig). width_mm nominal.
- **EX4400-24T**: extension-module interface names (PIC 2) not read from the guide. width_mm nominal.
- **EX4400-48T**: extension-module interface names. width_mm nominal.
- **EX4650-48Y**: default 25G vs 10G naming depends on optic/config. width_mm nominal. QFX5120-48YM is a different panel (not covered).
- **QFX5100-48S-6Q**: width_mm nominal. QFX5100 guide is no longer on networkingdocs.hpe.com; read from a 2023 archive copy.
- **QFX5100-48T-6Q**: copper row order (low-resolution drawing; Juniper convention assumed). width_mm nominal.
- **QFX5110-48S-4C**: width_mm nominal.
- **QFX5120-32C**: em0 name for MGMT. width_mm nominal.
- **SRX300**: width_mm.
- **SRX320**: mPIM interface naming. width_mm.
- **SRX340**: SRX345 drawing not viewed (same callout list as SRX340). SRX345 dual-AC variant has an extra FIPS blank on the front. width_mm nominal.
- **SRX380**: width_mm nominal.
- **SRX1500**: PIM interface naming. width_mm nominal.
- **SRX1600**: width_mm nominal.
- **MX204**: width_mm nominal.
- **MX10003**: whole entry: the MX10003 guide pages redirect to a product landing page now; layout and PIC numbering are from memory/third-party search results. front vs rear placement of RCBs. form '3U-19in' is outside the requested enum.
- **C9200L-24T-4G**: 24-port faceplate not shown in the guide; extrapolated from the 48-port drawing (position of the blank area between the copper blocks and the uplinks unknown).
- **C9200-24T**: 24-port faceplate extrapolated from the 48-port drawing.
- **C9300-24T**: 24-port faceplate not shown; extrapolated from the 48-port drawing. NM-2Y interface prefix.
- **C9300L-24T-4G**: 24-port faceplate extrapolated from the C9300L-48P-4X drawing.
- **WS-C2960X-24TS-L**: SFP row order (2x2) and label numbers. the guide's generic figure is a 24-port PoE unit; TS layout assumed identical.
- **WS-C2960X-48TS-L**: 48-port drawing not available; block size and SFP arrangement extrapolated from the 24-port figure. 48TD uplink naming.
- **WS-C2960L-8TS-LL**: 2960-L interface prefix (Gi0/x assumed, not stackable). row order of the 2x4 block. 16-port layout. width_mm.
- **WS-C2960L-24TS-LL**: interface prefix Gi0/x. SFP 2x2 numbering.
- **WS-C2960L-48TS-LL**: 48-port drawing exists in the guide (354751.jpg) but was not viewed; layout extrapolated from the 24-port drawing. interface prefix.
- **WS-C3850-24T**: 24-port faceplate extrapolated from the 48-port drawing.
- **C1000-8T-2G-L**: drawing not viewed: row count (1 or 2) of the 8 copper ports, order of items, uplink interface numbering. width_mm.
- **C1000-24T-4G-L**: uplink interface numbering (Gi1/0/25..28 vs Gi1/1/1..4).
- **C1000-48T-4G-L**: 48-port drawing not viewed: block size and the console/USB stacking. uplink interface numbering.
- **CBS350-24T-4G**: whole layout: no CBS350 drawing was viewed (the admin guide only has a generic representation). CLI interface naming. order of console/reset/USB and copper/SFP groups. row order.
- **CBS350-48T-4G**: whole layout (no drawing viewed).
- **CRS326-24G-2S+**: RM version: 1U-19in (~443 mm) with the same port layout but no front console (console location on RM not confirmed).
- **CRS328-24P-4S+**: bottom-first order inferred from the CRS326/CSS610/CRS310/CCR2004 panels (same label scheme), not directly confirmed on this model.
- **CRS317-1G-16S+**: which of ether1/console is on top. reset/mode location.
- **CRS309-1G-8S+**: kind 'console-db9' is outside the requested enum.
- **CRS305-1G-4S+**: side-panel item positions.
- **CRS310-8G+2S+**: no serial console listed in the specs.
- **CRS112-8G-4S**: SFP interface names sfp9..sfp12 (RouterOS) not confirmed. SFP row order.
- **CCR2004-16G-2S+**: '15/BOOT' reading (small text). PC (passive) variant layout.
- **CCR1009-7G-1C-1S+**: which physical RJ-45 maps to ether1 vs the combo copper (labels read 'ETH' for the combo and ETH1..ETH7). PC (passive, 272 mm desktop) variant layout and LCD presence.
- **RB5009UG+S+**: RB5009UPr+S+ (PoE-out variant) assumed same layout.
- **RB4011iGS+**: console on the rear (spec lists an RJ-45 console; it is not on the front render).
- **hEX S**: reset button, mode button and USB-A location (not on the front render).
- **hEX**: USB-A location (spec lists one USB-A; not seen on the front render).
- **hAP ax^2**: exact RouterOS board-name string. mode button position.
- **hAP ax^3**: exact RouterOS board-name string. which port has PoE-out (spec page says Ether 1).
- **L009UiGS**: console location. width_mm (rack kit K-79 for 1U). L009UiGS-2HaxD (wireless) assumed same layout.
- **EdgeRouter X SFP 6-Port**: EdgeOS HW model string. width_mm.
- **EdgeRouter X 5-Port**: width_mm. EdgeOS HW model string.
- **EdgeRouter 4**: width_mm.
- **EdgeRouter 6P**: width_mm.
- **EdgeRouter 12**: width_mm.
- **EdgeRouter Lite 3-Port**: width_mm. EdgeOS HW model string.
- **EdgeRouter Infinity**: SFP+ pair numbering (top = odd assumed; drawing too small to read). width_mm nominal.
