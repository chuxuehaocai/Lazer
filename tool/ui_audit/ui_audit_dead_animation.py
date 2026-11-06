#!/usr/bin/env python3
"""Find implicit animations whose animated property can never change.

An `AnimatedOpacity(opacity: 1, ...)` or an `AnimatedScale(scale: 2, ...)`
never animates: the tween always starts and ends at the same value, so the
implicit animation is dead code and the intended transition does not happen.
"""
from __future__ import annotations

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ui_audit_scan import blank_out  # noqa: E402

# widget -> the argument that must vary for the animation to mean anything
PROPS = {
    "AnimatedOpacity": ["opacity"],
    "AnimatedScale": ["scale"],
    "AnimatedRotation": ["turns"],
    "AnimatedSlide": ["offset"],
    "AnimatedAlign": ["alignment"],
    "AnimatedPadding": ["padding"],
    "AnimatedPositioned": ["left", "top", "right", "bottom"],
    "AnimatedCrossFade": ["crossFadeState"],
    "AnimatedDefaultTextStyle": ["style"],
    "AnimatedPhysicalModel": ["elevation", "color", "shape"],
    "AnimatedContainer": [
        "width", "height", "color", "padding", "margin", "alignment",
        "decoration", "transform", "constraints",
    ],
}

WIDGET_RE = re.compile(r"\b(" + "|".join(PROPS) + r")\s*\(")
LITERAL = re.compile(r"^(?:const\s+)?-?\d+(?:\.\d+)?$|^(?:const\s+)?(?:true|false)$")


def arg_list(src: str, open_paren: int) -> str:
    depth = 0
    i = open_paren
    while i < len(src):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                return src[open_paren + 1 : i]
        i += 1
    return ""


def top_level_args(args: str) -> dict[str, str]:
    """Split an argument list into name -> expression at nesting depth 0."""
    out: dict[str, str] = {}
    depth = 0
    start = 0
    parts: list[str] = []
    for i, ch in enumerate(args):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(args[start:i])
            start = i + 1
    parts.append(args[start:])
    for part in parts:
        if ":" not in part:
            continue
        name, _, value = part.partition(":")
        out[name.strip()] = value.strip()
    return out


lib = sys.argv[1] if len(sys.argv) > 1 else "lib"
hits: list[tuple[str, int, str, str]] = []
for root, _d, names in os.walk(lib):
    for nm in sorted(names):
        if not nm.endswith(".dart"):
            continue
        path = os.path.join(root, nm)
        raw = open(path, encoding="utf-8").read()
        clean = blank_out(raw)
        lines = raw.split("\n")
        for m in WIDGET_RE.finditer(clean):
            args = top_level_args(arg_list(clean, m.end() - 1))
            props = PROPS[m.group(1)]
            present = [p for p in props if p in args]
            if not present:
                continue
            literal = [p for p in present if LITERAL.match(args[p])]
            # every animatable property is frozen -> the widget cannot animate
            if len(literal) == len(present):
                line = clean[: m.start()].count("\n") + 1
                hits.append(
                    (
                        path.replace("\\", "/"),
                        line,
                        m.group(1),
                        ", ".join(f"{p}: {args[p]}" for p in present),
                    )
                )

print(f"{len(hits)} dead implicit animations (every animated property is a literal)\n")
cur = None
for path, line, widget, detail in hits:
    if path != cur:
        print(f"\n{path}")
        cur = path
    print(f"  {line:5}  {widget:24} {detail[:100]}")
