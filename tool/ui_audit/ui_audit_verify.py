#!/usr/bin/env python3
"""Verify undisposed-field findings: print each owner class's dispose() body."""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ui_audit_scan import find_blocks, find_methods, blank_out  # noqa: E402

data = json.load(open(sys.argv[1], encoding="utf-8"))
cache: dict[str, str] = {}
only = sys.argv[2] if len(sys.argv) > 2 else None

for f in data:
    if f["rule"] != "undisposed-field":
        continue
    if only and only not in f["rule"]:
        continue
    path = f["file"]
    if path not in cache:
        cache[path] = open(path, encoding="utf-8").read()
    clean = blank_out(cache[path])
    blocks = [b for b in find_blocks(clean) if b.name == f["owner"]]
    print("=" * 100)
    print(f"{f['file']}:{f['line']}  {f['owner']}  ->  {f['message']}")
    if not blocks:
        print("   !! class block not found")
        continue
    b = blocks[-1]
    methods = find_methods(b)
    if "dispose" in methods:
        body = methods["dispose"][0]
        print(f"   dispose() body ({body.count(chr(10)) + 1} lines):")
        for ln in body.split("\n"):
            if ln.strip():
                print("      " + ln.strip())
    else:
        print("   !! NO dispose() METHOD AT ALL")
    # show every mention of the field in the class
    nm = re.search(r"`([^`]+)`", f["message"]).group(1)
    print(f"   --- all `{nm}` mentions in class ---")
    for i, ln in enumerate(b.body.split("\n")):
        if re.search(r"\b" + re.escape(nm) + r"\b", ln):
            print(f"      L{b.line + i}: {ln.strip()[:130]}")
