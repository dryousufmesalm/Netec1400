#!/usr/bin/env python3
"""Read-only OOXML/DataMashup contract check for the AmarTrading workbook.

This intentionally does not open Excel or modify the input package.  It checks
the three independent names involved in a Power Query load: the embedded M
query name, the connection Location/command, and the query-table connection
reference.  A workbook can contain a perfectly valid M query while still
failing at refresh if one of those names drifts.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
EXPECTED = {"AmarTrading_Baskets", "AmarTrading_SyncStatus"}


def _xml(z: zipfile.ZipFile, name: str):
    return ET.fromstring(z.read(name))


def _m_text(z: zipfile.ZipFile) -> str:
    payload = None
    for name in z.namelist():
        if not name.startswith("customXml/") or not name.endswith(".xml"):
            continue
        raw = z.read(name)
        for encoding in ("utf-16", "utf-8"):
            try:
                text = raw.decode(encoding)
            except UnicodeDecodeError:
                continue
            match = re.search(r"<DataMashup[^>]*>(.*?)</DataMashup>", text, re.S)
            if match:
                payload = base64.b64decode(match.group(1))
                break
        if payload is not None:
            break
    if payload is None:
        raise ValueError("package has no embedded DataMashup payload")
    # DataMashup has an eight-byte header before its inner zip package.
    start = payload.find(b"PK\x03\x04")
    # Some Excel writers leave a second, empty EOCD record in the DataMashup
    # blob.  zipfile otherwise chooses that trailing record and reports no
    # members, even though the first archive is complete.
    end = payload.find(b"PK\x05\x06", start)
    archive = payload[start : end + 22] if end >= 0 else payload[start:]
    inner = zipfile.ZipFile(io.BytesIO(archive))
    return inner.read("Formulas/Section1.m").decode("utf-8", "replace")


def inspect(path: Path) -> dict:
    with zipfile.ZipFile(path) as z:
        connections = _xml(z, "xl/connections.xml")
        conn = {}
        for c in connections.findall("x:connection", NS):
            db = c.find("x:dbPr", NS)
            if db is None:
                continue
            location = re.search(r"Location=([^;]+)", db.attrib.get("connection", ""))
            conn[c.attrib["id"]] = {
                "id": c.attrib["id"], "name": c.attrib.get("name"),
                "location": location.group(1) if location else None,
                "command": db.attrib.get("command"),
            }
        worksheet_tables = []
        for name in sorted(n for n in z.namelist() if n.startswith("xl/tables/table") and n.endswith(".xml")):
            root = _xml(z, name)
            worksheet_tables.append({"part": name, "name": root.attrib.get("name"),
                           "ref": root.attrib.get("ref")})
        query_tables = []
        for name in sorted(n for n in z.namelist() if n.startswith("xl/queryTables/") and n.endswith(".xml")):
            root = _xml(z, name)
            query_tables.append({"part": name, "name": root.attrib.get("name"),
                           "connectionId": root.attrib.get("connectionId"),
                           "fields": [f.attrib.get("name") for f in root.findall(".//x:queryTableField", NS)]})
        m = _m_text(z)
        embedded = set(re.findall(r"\bshared\s+([A-Za-z][A-Za-z0-9_]*)\s*=", m))
        paths = sorted(set(re.findall(r"Folder\.Files\(([^)]+)\)", m)))
        wired = []
        for name in sorted(n for n in z.namelist() if n.startswith("xl/worksheets/_rels/") and n.endswith(".rels")):
            relroot = ET.fromstring(z.read(name))
            for rel in relroot:
                if rel.attrib.get("Type", "").endswith("/queryTable"):
                    wired.append({"worksheet_rels": name, "target": rel.attrib.get("Target")})
        return {"file": str(path), "embedded_queries": sorted(embedded),
                "connections": list(conn.values()), "worksheet_tables": worksheet_tables,
                "query_tables": query_tables,
                "wired_query_tables": wired,
                "folder_files_arguments": paths,
                "uses_onedrive_amartrading": bool(re.search(r"OneDriveRoot.{0,250}amartrading", m, re.I | re.S))}


def failures(report: dict) -> list[str]:
    issues = []
    embedded = set(report["embedded_queries"])
    if embedded != EXPECTED:
        issues.append(f"embedded queries are {sorted(embedded)}, expected {sorted(EXPECTED)}")
    if len(report["connections"]) != 2:
        issues.append(f"workbook has {len(report['connections'])} connections; expected exactly 2")
    if len(report["wired_query_tables"]) != 2:
        issues.append(f"workbook has {len(report['wired_query_tables'])} worksheet-wired query tables; expected exactly 2")
    for c in report["connections"]:
        if c["location"] not in EXPECTED:
            issues.append(f"connection {c['id']} Location={c['location']!r} is not an expected query")
        if c["location"] and c["location"] not in (c["command"] or ""):
            issues.append(f"connection {c['id']} command does not select {c['location']}")
    for q in report["query_tables"]:
        ids = {c["id"]: c["location"] for c in report["connections"]}
        if q["connectionId"] not in ids:
            issues.append(f"{q['part']} references missing connection {q['connectionId']}")
        elif ids[q["connectionId"]] not in EXPECTED:
            issues.append(f"{q['part']} resolves to unexpected query {ids[q['connectionId']]!r}")
    if not report["uses_onedrive_amartrading"]:
        issues.append("embedded queries do not use OneDriveRoot \\amartrading")
    return issues


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("workbook", type=Path)
    args = ap.parse_args(argv)
    try:
        report = inspect(args.workbook)
        report["issues"] = failures(report)
    except (OSError, KeyError, ValueError, zipfile.BadZipFile) as exc:
        print(json.dumps({"file": str(args.workbook), "issues": [str(exc)]}, indent=2))
        return 2
    print(json.dumps(report, indent=2))
    return 1 if report["issues"] else 0


if __name__ == "__main__":
    sys.exit(main())
