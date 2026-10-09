#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File:        check_genicam_xml.py
# Description: Validates the feature description the server serves. Checking
#              that the document is well formed is not enough: a client rejects
#              it for child elements in the wrong order or a feature declared
#              with the wrong type, neither of which affects well formedness.
# -----------------------------------------------------------------------------

import os
import re
import sys
import xml.etree.ElementTree as ET

def _find_header():
    d = os.path.dirname(os.path.abspath(__file__))
    for _ in range(6):
        for rel in (
            ("include", "gvcp_server.hpp"),
            ("sw", "include", "gvcp_server.hpp"),
            ("sw", "kv260", "gvsp_server", "include", "gvcp_server.hpp"),
        ):
            cand = os.path.join(d, *rel)
            if os.path.isfile(cand):
                return cand
        d = os.path.dirname(d)
    sys.exit("gvcp_server.hpp not found (searched upwards from this script)")

HDR = _find_header()

ORDER = {
    "Integer": [
        "ToolTip",
        "Description",
        "DisplayName",
        "Visibility",
        "Streamable",
        "Value",
        "pValue",
        "Min",
        "pMin",
        "Max",
        "pMax",
        "Inc",
        "pInc",
        "Unit",
        "Representation",
        "ValidValueSet",
        "pSelected",
    ],
    "Enumeration": [
        "ToolTip",
        "Description",
        "DisplayName",
        "Visibility",
        "Streamable",
        "EnumEntry",
        "Value",
        "pValue",
    ],
    "EnumEntry": [
        "ToolTip",
        "Description",
        "DisplayName",
        "Visibility",
        "Value",
        "pValue",
        "Symbolic",
        "NumericValue",
    ],
    "Command": [
        "ToolTip",
        "Description",
        "DisplayName",
        "Visibility",
        "Value",
        "pValue",
        "CommandValue",
        "pCommandValue",
    ],
    "IntReg": [
        "ToolTip",
        "Description",
        "DisplayName",
        "Visibility",
        "Streamable",
        "Address",
        "pAddress",
        "IntSwissKnife",
        "Length",
        "AccessMode",
        "pPort",
        "Cachable",
        "PollingTime",
        "Sign",
        "Endianess",
    ],
    "StringReg": [
        "ToolTip",
        "Description",
        "DisplayName",
        "Visibility",
        "Streamable",
        "Address",
        "Length",
        "AccessMode",
        "pPort",
    ],
    "Boolean": [
        "ToolTip",
        "Description",
        "DisplayName",
        "Visibility",
        "Streamable",
        "Value",
        "pValue",
        "OnValue",
        "OffValue",
    ],
    "Category": ["ToolTip", "Description", "DisplayName", "Visibility", "pFeature"],
}

SFNC_TYPE = {
    "ExposureTime": "Float",
    "Gain": "Float",
    "BlackLevel": "Float",
    "Gamma": "Float",
    "AcquisitionFrameRate": "Float",
    "ExposureAuto": "Enumeration",
    "GainAuto": "Enumeration",
    "BalanceWhiteAuto": "Enumeration",
    "PixelFormat": "Enumeration",
    "AcquisitionMode": "Enumeration",
    "TestPattern": "Enumeration",
    "ReverseX": "Boolean",
    "ReverseY": "Boolean",
    "Width": "Integer",
    "Height": "Integer",
    "PayloadSize": "Integer",
    "AcquisitionStart": "Command",
    "AcquisitionStop": "Command",
    "GevSCPSFireTestPacket": "Boolean",
}

def build_xml_from_header():
    src = open(HDR, encoding="utf-8").read()
    mi = re.search(r"char\s+b\[16384\]\s*;", src)
    mj = re.search(r"xml_\s*\.\s*assign\s*\(\s*b\s*,", src)
    if not mi or not mj:
        sys.exit("build_xml() not found (has the server source been restructured?)")
    blk = src[mi.start() : mj.start()]
    lits = re.findall(r'"((?:[^"\\]|\\.)*)"', blk)
    fmt = "".join(l.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t") for l in lits)
    vals = [1920, 1920, 1920, 1080, 1080, 1080, 6220800, 6220800, 6220800]
    out, k, n = [], 0, 0
    while n < len(fmt):
        if fmt[n] == "%" and n + 1 < len(fmt) and fmt[n + 1] == "u":
            out.append(str(vals[k]))
            k += 1
            n += 2
        else:
            out.append(fmt[n])
            n += 1
    xml = "".join(out)
    end = xml.find("</RegisterDescription>")
    if end < 0:
        sys.exit("</RegisterDescription> not found")
    return xml[: end + len("</RegisterDescription>")]

def _xsd_candidates():
    out = [os.environ.get("GENAPI_XSD", "")]
    d = os.path.dirname(os.path.abspath(__file__))
    for _ in range(6):
        out.append(os.path.join(d, "output", "refs", "aravis", "src", "GenApiSchema_Version_1_1.xsd"))
        d = os.path.dirname(d)
    return out

def validate_with_xsd(xml):
    """Validate against the GenApi schema. Returns (None, reason) when that is not possible."""
    path = next((p for p in _xsd_candidates() if p and os.path.exists(p)), None)
    if not path:
        return None, "schema not found (set GENAPI_XSD to GenApiSchema_Version_1_1.xsd)"
    try:
        from lxml import etree
    except ImportError:
        return None, "lxml is not available"
    sch = etree.XMLSchema(etree.parse(path))
    doc = etree.fromstring(xml.encode())
    if sch.validate(doc):
        return [], path
    return ["line %-4d %s" % (e.line, e.message) for e in sch.error_log], path

def main():
    xml = build_xml_from_header()
    errs = []

    xsd_errs, info = validate_with_xsd(xml)
    if xsd_errs is None:
        if "--require-xsd" in sys.argv:
            sys.exit("schema validation not possible: %s" % info)
        print("  note: no schema validation (%s); the checks below are approximate." % info)
    else:
        print("  XSD: %s" % info)
        errs += xsd_errs

    try:
        root = ET.fromstring(xml)
    except ET.ParseError as e:
        sys.exit("not well formed: %s" % e)
    ns = root.tag[: root.tag.index("}") + 1] if root.tag.startswith("{") else ""
    strip = (lambda t: t[len(ns) :]) if ns else (lambda t: t)

    for el in root.iter():
        kind = strip(el.tag)
        order = ORDER.get(kind)
        if not order:
            continue
        seen = [strip(c.tag) for c in el]
        unknown = [c for c in seen if c not in order]
        if unknown:
            errs.append(
                "%s '%s': child element %s is not in the order table; add it to ORDER"
                % (kind, el.get("Name", "?"), unknown)
            )
            continue
        idx = [order.index(c) for c in seen]
        if idx != sorted(idx):
            errs.append(
                "%s '%s': child elements violate the schema order\n    found:    %s\n    expected: %s"
                % (kind, el.get("Name", "?"), seen, [c for c in order if c in seen])
            )

    for el in root.iter():
        kind = strip(el.tag)
        if kind not in ("Integer", "Float", "Enumeration", "Boolean", "Command", "String"):
            continue
        if el.get("NameSpace") != "Standard":
            continue
        want = SFNC_TYPE.get(el.get("Name"))
        if want and want != kind:
            errs.append(
                '%s \'%s\': declared in the standard namespace but the standard type is %s. '
                'Match the type or move it to the custom namespace' % (kind, el.get("Name"), want)
            )

    names = {el.get("Name") for el in root.iter() if el.get("Name")}
    for el in root.iter():
        t = strip(el.tag)
        if t in ("pFeature", "pValue", "pMin", "pMax", "pInc") and el.text:
            if el.text.strip() not in names:
                errs.append("<%s>%s</%s> refers to a node that does not exist" % (t, el.text.strip(), t))

    for el in root.iter():
        if strip(el.tag) != "Integer":
            continue
        g = {strip(c.tag): c.text for c in el}
        if "Min" in g and "Max" in g and int(g["Min"]) > int(g["Max"]):
            errs.append("Integer '%s': Min > Max" % el.get("Name"))
        if "Inc" in g and int(g["Inc"]) <= 0:
            errs.append("Integer '%s': Inc <= 0" % el.get("Name"))

    if len(xml) >= 16384:
        errs.append("the document is %d bytes and does not fit the 16384 byte buffer" % len(xml))

    print("document %d bytes, %d nodes" % (len(xml), len(names)))
    if errs:
        print("\n".join("  - " + e for e in errs))
        print(">>> GENICAM XML CHECK FAIL (%d problems)" % len(errs))
        return 1
    print(">>> GENICAM XML CHECK PASS")
    return 0

if __name__ == "__main__":
    sys.exit(main())
