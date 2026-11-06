#!/usr/bin/env python3
"""Find implicit animations that ignore the reduce-motion preference.

The app promises (docs/ui.md): "Reduced motion removes decorative travel and
stops ambient flow." Every `Animated*` widget that supplies a non-zero
`duration:` must therefore collapse to `Duration.zero` when
`MediaQuery.disableAnimationsOf(context)` is true, either inline or through a
helper that already gates it.
"""
from __future__ import annotations

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ui_audit_scan import blank_out  # noqa: E402

IMPLICIT = re.compile(
    r"\b(Animated[A-Z]\w*|TweenAnimationBuilder|AnimatedSwitcher|"
    r"AnimatedCrossFade|AnimatedSize|AnimatedTheme|Hero)\s*\("
)
DURATION = re.compile(r"duration\s*:")
GATES = ("disableAnimations", "MotionTiming", "imu", "Duration.zero")

lib = sys.argv[1] if len(sys.argv) > 1 else "lib"
hits = []
for root, _d, names in os.walk(lib):
    for nm in sorted(names):
        if not nm.endswith(".dart"):
            continue
        path = os.path.join(root, nm)
        raw = open(path, encoding="utf-8").read()
        clean = blank_out(raw)
        lines = raw.split("\n")
        for m in IMPLICIT.finditer(clean):
            # slice the widget's argument list
            i = m.end() - 1
            depth = 0
            while i < len(clean):
                if clean[i] == "(":
                    depth += 1
                elif clean[i] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            args = clean[m.end() : i]
            if not DURATION.search(args):
                continue
            if any(g in args for g in GATES):
                continue
            line = clean[: m.start()].count("\n") + 1
            snippet = lines[line - 1].strip()[:110]
            hits.append((path.replace("\\", "/"), line, m.group(1), snippet))

print(f"{len(hits)} implicit animations with an ungated duration\n")
cur = None
for path, line, widget, snippet in hits:
    if path != cur:
        print(f"\n{path}")
        cur = path
    print(f"  {line:5}  {widget:22} {snippet}")
