#!/usr/bin/env python3
"""Find MediaQuery reads in initState, and reduce-motion flags that go stale.

`MediaQuery.of`/`disableAnimationsOf` inside `initState` either asserts (no
inherited dependency allowed there) or captures a value that never refreshes
when the window, text scale or accessibility flags change. The correct place is
`didChangeDependencies`.
"""
from __future__ import annotations

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ui_audit_scan import blank_out, find_blocks, find_methods  # noqa: E402

MQ = re.compile(r"MediaQuery\.(?:of|maybeOf|sizeOf|paddingOf|disableAnimationsOf|maybeDisableAnimationsOf|platformBrightnessOf|textScalerOf|viewInsetsOf|viewPaddingOf|orientationOf|devicePixelRatioOf|highContrastOf|boldTextOf|navigationModeOf|gestureSettingsOf|accessibleNavigationOf|invertColorsOf|displayFeaturesOf|systemGestureInsetsOf|supportsShowingSystemContextMenuOf)")
FLAG = re.compile(r"\b(?:bool|double)\s+(_?\w*(?:[Rr]educe\w*|[Rr]educed\w*|[Mm]otion\w*|[Dd]isable\w*[Aa]nim\w*))\b")
READS = ("MediaQuery.disableAnimationsOf", "MediaQuery.maybeDisableAnimationsOf",
         "disableAnimations", "MediaQuery.of", "MediaQuery.maybeOf", "sizeOf",
         "paddingOf", "textScalerOf")

lib = sys.argv[1] if len(sys.argv) > 1 else "lib"
hits: list[tuple[str, int, str, str, str]] = []

for root, _d, names in os.walk(lib):
    for nm in sorted(names):
        if not nm.endswith(".dart"):
            continue
        path = os.path.join(root, nm).replace("\\", "/")
        raw = open(path, encoding="utf-8").read()
        clean = blank_out(raw)
        for b in find_blocks(clean):
            if b.kind != "class":
                continue
            methods = find_methods(b)
            init = methods.get("initState")
            if init:
                body = init[0]
                for m in MQ.finditer(body):
                    line = b.line + b.body[: init[1] + m.start()].count("\n")
                    hits.append((path, line, b.name, "initState", m.group(0)))
            # reduce-motion flags: cached in didChangeDependencies => fine,
            # cached only in initState or only at a field initialiser => stale
            for m in FLAG.finditer(b.body):
                flag = m.group(1)
                if not re.search(r"\b" + re.escape(flag) + r"\b", b.body):
                    continue
                assigned_in_init = bool(
                    init and re.search(r"\b" + re.escape(flag) + r"\s*=", init[0])
                )
                assigned_in_dcd = False
                dcd = methods.get("didChangeDependencies")
                if dcd and re.search(r"\b" + re.escape(flag) + r"\s*=", dcd[0]):
                    assigned_in_dcd = True
                if assigned_in_init and not assigned_in_dcd:
                    line = b.line + b.body[: m.start()].count("\n")
                    hits.append(
                        (
                            path,
                            line,
                            b.name,
                            "flag set only in initState",
                            flag,
                        )
                    )

print(f"{len(hits)} findings\n")
cur = None
for path, line, owner, kind, detail in hits:
    if path != cur:
        print(f"\n{path}")
        cur = path
    print(f"  {line:5}  [{kind:24}] {owner}: {detail}")
