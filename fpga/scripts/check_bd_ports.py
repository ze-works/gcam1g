#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File:        check_bd_ports.py
# Description: Checks, before anything is packaged, that every port the block
#              design refers to actually exists in that IP's RTL. Port names
#              are written by hand in both places and nothing generates one
#              from the other, so renaming one side silently breaks the other;
#              where the reference is wrapped in a catch, it leaves a pin
#              unconnected instead of failing.
# -----------------------------------------------------------------------------

from __future__ import annotations

import re
import sys
from pathlib import Path

CELL_RE = re.compile(r"create_bd_cell\s+-type\s+ip\s+-vlnv\s+user\.org:gcam:([a-z0-9_]+):\S+\s+([a-z0-9_]+)")
PIN_RE = re.compile(r"get_bd_(intf_)?pins\s+([a-z0-9_]+)/([a-z0-9_]+)")
VAR_PIN_RE = re.compile(r"get_bd_(?:intf_)?pins\s+\$")

def module_ports(sv: Path, top: str) -> set[str]:
    """Collect the port names of the top module."""
    text = sv.read_text(encoding="utf-8")
    m = re.search(rf"\bmodule\s+{re.escape(top)}\b", text)
    if not m:
        raise SystemExit(f"  module {top} not found in {sv}")
    i = m.end()
    j = text.find("(", i)
    if text[i:j].strip().startswith("#"):
        depth, k = 0, j
        while k < len(text):
            if text[k] == "(":
                depth += 1
            elif text[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        j = text.find("(", k + 1)
    depth, k, start = 0, j, j + 1
    while k < len(text):
        if text[k] == "(":
            depth += 1
        elif text[k] == ")":
            depth -= 1
            if depth == 0:
                break
        k += 1
    body = text[start:k]
    body = re.sub(r"/\*.*?\*/", " ", body, flags=re.S)
    body = re.sub(r"//[^\n]*", " ", body)

    ports, depth, item = set(), 0, []
    for ch in body:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            ports.add("".join(item))
            item = []
        else:
            item.append(ch)
    ports.add("".join(item))
    out = set()
    for p in ports:
        ids = re.findall(r"[A-Za-z_]\w*", p)
        if ids:
            out.add(ids[-1])
    return out

BUSIF_RE = re.compile(r"<spirit:busInterface>.*?<spirit:name>([A-Za-z0-9_]+)</spirit:name>", re.S)

def packaged_interfaces(component: Path) -> set[str]:
    """Bus interface names from component.xml (the first name in each block)."""
    t = component.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"<spirit:busInterfaces>(.*?)</spirit:busInterfaces>", t, re.S)
    if not m:
        return set()
    out = set()
    for blk in re.split(r"(?=<spirit:busInterface>)", m.group(1)):
        n = re.search(r"<spirit:name>([A-Za-z0-9_]+)</spirit:name>", blk)
        if n:
            out.add(n.group(1))
    return out

def main(argv: list[str]) -> int:
    iprepo = None
    argv = list(argv)
    if "--packaged" in argv:
        i = argv.index("--packaged")
        iprepo = Path(argv[i + 1])
        del argv[i : i + 2]
    if len(argv) < 4:
        print("usage: check_bd_ports.py [--packaged <ip_repo>] <root> <bd.tcl> <name|top|files> ...",
              file=sys.stderr)
        return 2
    root, bd = Path(argv[1]), Path(argv[2])
    tops: dict[str, tuple[str, Path]] = {}
    for row in argv[3:]:
        name, top, files = row.split("|", 2)
        topf = [f for f in files.split(",") if Path(f).name == f"{top}.sv"]
        if not topf:
            print(f"  {name}: the top level .sv is not in the file list", file=sys.stderr)
            return 1
        tops[name] = (top, root / topf[0])

    text = bd.read_text(encoding="utf-8")
    cells = {cell: ip for ip, cell in CELL_RE.findall(text)}
    missing_cells = sorted(set(cells.values()) - set(tops))
    if missing_cells:
        print(f"  the block design instantiates IPs missing from the table: {missing_cells}", file=sys.stderr)
        return 1

    ports = {ip: module_ports(sv, top) for ip, (top, sv) in tops.items()}
    ifs = {}
    if iprepo is not None:
        for ip in tops:
            c = iprepo / ip / "component.xml"
            if not c.is_file():
                print(f"  {ip}: component.xml not found ({c})", file=sys.stderr)
                return 1
            ifs[ip] = packaged_interfaces(c)

    bad: list[str] = []
    checked = 0
    for is_intf, cell, pin in PIN_RE.findall(text):
        ip = cells.get(cell)
        if ip is None:
            continue
        checked += 1
        if is_intf:
            if not any(p.startswith(pin + "_") for p in ports[ip]):
                bad.append(f"  {cell}({ip})/{pin}: no {pin}_* ports in the RTL for this interface")
            elif iprepo is not None and pin not in ifs[ip]:
                bad.append(
                    f"  {cell}({ip})/{pin}: the ports exist in the RTL but no bus interface was"
                    f" inferred; a signal of the bundle is missing. Inferred: {sorted(ifs[ip])}"
                )
        elif pin not in ports[ip]:
            near = sorted(p for p in ports[ip] if p.startswith(pin[:6]))[:3]
            bad.append(
                f"  {cell}({ip})/{pin}: this port does not exist in the RTL"
                + (f" (did you mean: {', '.join(near)})" if near else "")
            )

    for b in sorted(set(bad)):
        print(b, file=sys.stderr)
    if bad:
        print(
            f"  BD PORT MISMATCH: {len(set(bad))} - the names the block design refers to"
            " disagree with the actual ports and bus interfaces",
            file=sys.stderr,
        )
        return 1

    nvar = len(VAR_PIN_RE.findall(text))
    where = "packaged IP" if iprepo is not None else "RTL"
    print(f"  block design port references OK vs {where} ({checked} checked, "
          f"{nvar} variable references cannot be resolved statically)")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
