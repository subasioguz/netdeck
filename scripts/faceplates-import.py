#!/usr/bin/env python3
"""Turns the researched front-panel notes (one JSON array, see docs/FACEPLATES.md) into the catalog
the app reads: Sources/NetdeckCore/Resources/Faceplates/faceplates.json.

Usage: python3 scripts/faceplates-import.py RESEARCH.json

Interface names are normalised ("ether1..ether24" -> "ether1..24", notes in parentheses dropped).
Groups whose "names" aren't interface names (module slots, HA ports, management ports) become
decorations or module slots. EX4300-24T/48T are left out on purpose: they are the reference drawing
of docs/DESIGN.md §5 and use the built-in layout.
"""
import json, re, sys

SKIP_MODELS = {"EX4300-24T", "EX4300-48T", "CSS610-8G-2S+", "MX10003", "CBS350-24T-4G", "CBS350-48T-4G"}
DECORATION_KINDS = {"console-rj45", "console-usb", "console-db9", "mgmt-rj45", "usb", "reset", "power-dc"}

def clean_names(names):
    if not names:
        return None
    n = re.split(r"\s+\(|\s+/\s+|\s+at\s+", names)[0].strip()
    # "ether1..ether24" -> "ether1..24", "sfp9..sfp12" -> "sfp9..12"
    n = re.sub(r"\.\.([A-Za-z+\-]+)(\d+)$", r"..\2", n)
    if not re.fullmatch(r"[A-Za-z][A-Za-z+\-]*[\d/]*\d(\.\.\d+)?", n):
        return None
    return n

def clean_labels(labels, count):
    if not labels:
        return None
    labels = re.sub(r"\s*\(.*?\)", "", labels).strip()
    out = []
    for part in [p.strip() for p in labels.split(",")]:
        m = re.fullmatch(r"(.*?)(\d+)\.\.(.*?)(\d+)", part)
        if m and (m.group(3) == "" or m.group(3) == m.group(1)):
            out += [f"{m.group(1)}{i}" for i in range(int(m.group(2)), int(m.group(4)) + 1)]
        else:
            out.append(part)
    return out if len(out) == count else None

def expand_count(names):
    m = re.search(r"(\d+)\.\.(\d+)$", names)
    return int(m.group(2)) - int(m.group(1)) + 1 if m else 1

def module_title(text):
    m = re.search(r"([A-Z0-9\-]*(UM|NM|EM)[A-Z0-9\-]*)", text or "")
    return m.group(1) if m else None

def convert(entry):
    groups = []
    for g in entry["groups"]:
        kind, pos = g["kind"], g.get("position") or "left"
        if kind == "module-slot":
            groups.append({"kind": "module-slot", "position": pos, "label": module_title(g.get("names")) or ""})
            continue
        names = clean_names(g.get("names")) if kind not in DECORATION_KINDS else None
        if kind in DECORATION_KINDS or names is None:
            label = g.get("labels") or g.get("names") or ""
            dkind = kind if kind in DECORATION_KINDS else ("sfp-aux" if kind.startswith("sfp") else "aux")
            groups.append({"kind": dkind, "position": pos, "label": label})
            continue
        count = expand_count(names)
        item = {"kind": kind, "names": names, "rows": g.get("rows") or 1, "order": g.get("order") or "single-row",
                "block": g.get("block") or 0, "position": pos}
        labels = clean_labels(g.get("labels"), count)
        if labels:
            item["labels"] = labels
        if g.get("block_sizes"):
            item["blockSizes"] = g["block_sizes"]
        groups.append(item)
    return {"model": entry["model"], "match": entry["match"], "vendor": entry.get("vendor"), "form": entry.get("form"),
            "groups": groups}

def main():
    research = json.load(open(sys.argv[1]))
    out = [convert(e) for e in research if e["model"] not in SKIP_MODELS]
    path = "Sources/NetdeckCore/Resources/Faceplates/faceplates.json"
    with open(path, "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"{len(out)} models -> {path}")

if __name__ == "__main__":
    main()
