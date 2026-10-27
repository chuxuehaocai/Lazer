#!/usr/bin/env python3
"""i18n coverage checker for lazer_nextgen.

Two things are enforced:

1. No Chinese source string reaches a Flutter text sink (`Text`, tooltips,
   semantics labels, input decoration, ...) without going through `context.tr`
   / `TrText`. Strings that the app's own widgets render are translated inside
   that widget once (`TRANSLATING_WIDGETS` below).
2. The four tables under `assets/l10n/` carry exactly the same key set, and
   every key the code emits exists in them.

Files that only *declare* Chinese source strings for another widget to
translate (state layer, catalogue messages) opt out of rule 1 with an
`// i18n:data` marker near the top; rule 2 still applies to them.

Usage:
  python tool/check_i18n.py            # gate mode, exit 1 on findings
  python tool/check_i18n.py --verbose  # list every finding
  python tool/check_i18n.py --keys     # dump the key set as JSON
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "lib"
L10N = ROOT / "assets" / "l10n"

CJK = re.compile(
    r"[\u3000-\u303f\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff00-\uffef]"
)
DATA_MARKER = "i18n:data"
KEY_MARKER = "i18n:key"

# Calls that turn their argument into a translated string themselves.
KEYED_CALLS = {"tr", "TrText", "_tr", "text"}

# Project widgets whose String parameters are translated inside their build.
# Keep this in sync when a widget starts calling context.tr on a parameter.
TRANSLATING_WIDGETS: dict[str, set[str | None]] = {
    # lib/widgets/accessible_controls.dart
    "AccessibleIconButton": {"tooltip"},
    "AccessibleTooltip": {"message"},
    "AccessibleSlider": {"semanticLabel", "label", "semanticFormatterCallback"},
    # lib/widgets/apple_ui.dart
    "ApplePageTitle": {"title", "subtitle"},
    "AppleEmptyState": {"message"},
    "AppleSearchField": {"hintText"},
    "AnimatedNotice": {"message"},
    # lib/widgets/song_comments_view.dart
    "_CommentsSectionLabel": {None},
    # lib/widgets/legacy/legacy_widgets.dart
    "LegacySectionHeader": {"title", "subtitle"},
    "LegacyNotice": {"message", None},
    "LegacyRailItem": {"label"},
    # lib/legacy/legacy_pages.dart (settings scaffolding)
    "_LegacySectionLabel": {None},
    "_LegacySettingRow": {"label", "subtitle"},
    "_LegacySwitchRow": {"label", "subtitle"},
    "_LegacySliderRow": {"label", "valueText", "subtitle"},
    "_LegacyChoiceRow": {"label", "valueText", "labelOf"},
    "_LegacyGradientSlider": {"label"},
    "_SearchTabButton": {"label"},
    "_ChartLoadCard": {"message"},
    "_HomeActionCard": {"title", "subtitle"},
    "_StationCard": {"title", "detail"},
    # lib/legacy/legacy_player_bar.dart
    "LegacyThinSeekBar": {"semanticLabel"},
    "_VerticalVolumeBar": {"semanticLabel"},
    # lib/legacy/legacy_shell.dart
    "_CompactIcon": {"tooltip"},
    "_ToolbarButton": {"tooltip"},
    "_Avatar": {"label"},
    # lib/theme/paper_widgets.dart
    "InlineLabel": {None},
    "SectionHeading": {None},
    "IvoryButton": {"label"},
    # lib/player/desktop_now_playing.dart
    "_PaneTab": {"label"},
    # lib/player/now_playing_page.dart
    "_ControlIcon": {"tooltip"},
}

# Project helper functions that run their String argument through `context.tr`
# before painting it (snack bars, inline status rows).
TRANSLATING_CALLS: dict[str, set[str | None]] = {
    "_message": {None},
    "_notify": {None},
    "_showLocalMessage": {None},
}

# Flutter APIs that paint a String on screen.
TEXT_WIDGETS = {"Text", "SelectableText"}
TEXT_ARGUMENTS = {
    ("Tooltip", "message"),
    ("IconButton", "tooltip"),
    ("NavigationDestination", "label"),
    ("NavigationRailDestination", "label"),
    ("Semantics", "label"),
    ("Chip", "label"),
    ("Image", "semanticLabel"),
    ("SnackBarAction", "label"),
    ("SearchBar", "hintText"),
    ("PopupMenuButton", "tooltip"),
    # Renders its parameters raw; call sites own the translation.
    ("AppleListTile", "title"),
    ("AppleListTile", "subtitle"),
}


def strip_dart(src: str) -> str:
    """Blank out comments while keeping offsets stable."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif c == "/" and src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                out[k] = " " if src[k] != "\n" else "\n"
            i = j
        elif c in "'\"" or (c == "r" and i + 1 < n and src[i + 1] in "'\""):
            raw = c == "r"
            quote_at = i + 1 if raw else i
            q = src[quote_at]
            close = q * 3 if src.startswith(q * 3, quote_at) else q
            j = quote_at + len(close)
            while j < n:
                if not raw and src[j] == "\\":
                    j += 2
                    continue
                if src.startswith(close, j):
                    break
                j += 1
            i = j + len(close)
        else:
            i += 1
    return "".join(out)


def _unescape_dart(value: str) -> str:
    """Decode the escapes Dart accepts, so escaped CJK is still visible."""
    if "\\" not in value:
        return value
    out: list[str] = []
    i = 0
    while i < len(value):
        c = value[i]
        if c != "\\" or i + 1 >= len(value):
            out.append(c)
            i += 1
            continue
        nxt = value[i + 1]
        simple = {
            "n": "\n",
            "r": "\r",
            "t": "\t",
            "b": "\b",
            "f": "\f",
            "v": "\v",
            "\\": "\\",
            "'": "'",
            '"': '"',
            "$": "$",
        }
        if nxt in simple:
            out.append(simple[nxt])
            i += 2
        elif nxt == "u" and value.startswith("u{", i + 1):
            end = value.find("}", i + 3)
            if end < 0:
                out.append(c)
                i += 1
            else:
                try:
                    out.append(chr(int(value[i + 3 : end], 16)))
                except ValueError:
                    out.append(value[i : end + 1])
                i = end + 1
        elif nxt == "u" and re.fullmatch(
            r"[0-9a-fA-F]{4}", value[i + 2 : i + 6] or ""
        ):
            out.append(chr(int(value[i + 2 : i + 6], 16)))
            i += 6
        elif nxt == "x" and re.fullmatch(
            r"[0-9a-fA-F]{2}", value[i + 2 : i + 4] or ""
        ):
            out.append(chr(int(value[i + 2 : i + 4], 16)))
            i += 4
        else:
            out.append(c)
            i += 1
    return "".join(out)


def string_spans(src: str) -> list[tuple[int, int, str]]:
    """(start, end, value) for every string literal in stripped source."""
    spans: list[tuple[int, int, str]] = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        raw = c == "r" and i + 1 < n and src[i + 1] in "'\""
        if c not in "'\"" and not raw:
            i += 1
            continue
        quote_at = i + 1 if raw else i
        q = src[quote_at]
        close = q * 3 if src.startswith(q * 3, quote_at) else q
        j = quote_at + len(close)
        buf: list[str] = []
        while j < n:
            if not raw and src[j] == "\\":
                buf.append(src[j : j + 2])
                j += 2
                continue
            if src.startswith(close, j):
                break
            buf.append(src[j])
            j += 1
        spans.append(
            (i, j + len(close), "".join(buf) if raw else _unescape_dart("".join(buf)))
        )
        i = j + len(close)
    return spans


def mask_strings(src: str) -> str:
    """Blank string literals (keeping offsets) so bracket scanning is safe."""
    out = list(src)
    for start, end, _value in string_spans(src):
        for k in range(start, end):
            if out[k] != "\n":
                out[k] = " "
    return "".join(out)


def _identifier_before(code: str, pos: int) -> str | None:
    j = pos
    while j >= 0 and code[j] in " \t\n":
        j -= 1
    if j >= 0 and code[j] == ">":
        # Skip the generic arguments of `Widget<T>(...)`.
        depth = 1
        k = j - 1
        while k >= 0 and depth:
            if code[k] == ">":
                depth += 1
            elif code[k] == "<":
                depth -= 1
            k -= 1
        j = k
    end = j + 1
    while j >= 0 and (code[j].isalnum() or code[j] in "_$."):
        j -= 1
    return code[j + 1 : end].split(".")[-1] or None


# Keywords that own a `(...)` but are not calls whose String argument would be
# rendered directly. A switch expression's arms are still part of the outer
# call's argument, so keep walking out past these frames.
CONTROL_CALLS = {"if", "for", "while", "switch", "catch", "assert"}


def _argument_name(code: str, open_paren: int, pos: int) -> str | None:
    """Name of the top-level argument of the call opened at `open_paren`."""
    start = open_paren + 1
    depth = 0
    colon = None
    for i in range(start, pos):
        c = code[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            start = i + 1
            colon = None
        elif c == ":" and depth == 0 and colon is None:
            colon = i
    if colon is None:
        return None
    name = code[start:colon].strip()
    if re.fullmatch(r"[A-Za-z_$][\w$]*", name):
        return name
    return None


def _nearest_context(
    stack: list[tuple[str, int, str | None]], code: str, pos: int
) -> tuple[str | None, str | None]:
    """Call and named argument around `pos`, skipping blocks and controls."""
    for opener, open_pos, call in reversed(stack):
        if opener != "(" or call is None or call in CONTROL_CALLS:
            continue
        return call, _argument_name(code, open_pos, pos)
    return None, None


def string_contexts(src: str) -> list[tuple[int, int, str, str | None, str | None]]:
    """`(start, end, value, call, argument)` for every string literal.

    A stack of brackets is walked once, so ternaries, collection literals and
    switch expressions all keep their enclosing call and named argument.
    """
    code = strip_dart(src)
    masked = mask_strings(code)
    spans = string_spans(code)
    contexts: list[tuple[int, int, str, str | None, str | None]] = []
    stack: list[tuple[str, int, str | None]] = []
    span_i = 0
    i = 0
    while i < len(masked):
        if span_i < len(spans) and spans[span_i][0] == i:
            start, end, value = spans[span_i]
            call, argument = _nearest_context(stack, masked, start)
            contexts.append((start, end, value, call, argument))
            span_i += 1
            i = max(i, end)
            continue
        c = masked[i]
        if c in "([{":
            call = _identifier_before(masked, i - 1) if c == "(" else None
            stack.append((c, i, call))
        elif c in ")]}":
            if stack:
                stack.pop()
        i += 1
    return contexts


def is_data_file(src: str) -> bool:
    return DATA_MARKER in "\n".join(src.splitlines()[:40])


def audit_code(verbose: bool) -> list[str]:
    findings: list[str] = []
    for path in sorted(LIB.rglob("*.dart")):
        if path.name.endswith(".g.dart"):
            continue
        src = path.read_text(encoding="utf-8")
        code = strip_dart(src)
        data = is_data_file(src)
        for start, _end, value, call, argument in string_contexts(src):
            if not CJK.search(value):
                continue
            if call in KEYED_CALLS:
                continue
            if (
                call in TRANSLATING_CALLS
                and argument in TRANSLATING_CALLS[call]
            ):
                continue
            if call in TRANSLATING_WIDGETS and argument in TRANSLATING_WIDGETS[call]:
                continue
            if data:
                continue
            sink = call in TEXT_WIDGETS or (call, argument) in TEXT_ARGUMENTS
            if not sink:
                continue
            line = code.count("\n", 0, start) + 1
            findings.append(
                f"{path.relative_to(ROOT)}:{line}: {' '.join(value.split())[:70]}"
            )
    return findings


PLACEHOLDER = re.compile(r"\{\w+\}")


def as_pattern(key: str) -> re.Pattern[str] | None:
    """A table key with `{name}` holes as a regex matching runtime strings."""
    if not PLACEHOLDER.search(key):
        return None
    parts = [re.escape(part) for part in PLACEHOLDER.split(key)]
    expression = "".join(
        part + (".*" if index < len(parts) - 1 else "")
        for index, part in enumerate(parts)
    )
    return re.compile(expression, re.DOTALL)


def counts_as_key(value: str, keys: set[str]) -> bool:
    """Whether a table key is still produced by one of the runtime strings."""
    if value in keys:
        return True
    pattern = as_pattern(value)
    return pattern is not None and any(pattern.fullmatch(key) for key in keys)


def covered_by(value: str, keys: set[str]) -> bool:
    """Whether a runtime string is covered by an exact or patterned table key."""
    if value in keys:
        return True
    return any(
        (pattern := as_pattern(key)) is not None and pattern.fullmatch(value)
        for key in keys
    )


def data_keys() -> tuple[set[str], list[str]]:
    """Keys the code emits: every wrapped literal and every declared message."""
    keys: set[str] = set()
    stray: list[str] = []
    for path in sorted(LIB.rglob("*.dart")):
        if path.name.endswith(".g.dart"):
            continue
        src = path.read_text(encoding="utf-8")
        code = strip_dart(src)
        data = is_data_file(src)
        for start, _end, value, call, argument in string_contexts(src):
            if not CJK.search(value):
                continue
            line = src.count("\n", 0, start) + 1
            line_start = src.rfind("\n", 0, start) + 1
            line_end = src.find("\n", start)
            marked = KEY_MARKER in src[
                line_start : len(src) if line_end < 0 else line_end
            ]
            if call in KEYED_CALLS or (
                call in TRANSLATING_WIDGETS
                and argument in TRANSLATING_WIDGETS[call]
            ) or (
                call in TRANSLATING_CALLS
                and argument in TRANSLATING_CALLS[call]
            ):
                keys.add(value)
            elif data or marked:
                keys.add(value)
            elif call in TEXT_WIDGETS or (call, argument) in TEXT_ARGUMENTS:
                stray.append(
                    f"{path.relative_to(ROOT)}:{line}: {' '.join(value.split())[:60]}"
                )
    return keys, stray


def load_tables() -> dict[str, dict[str, str]]:
    return {
        path.stem: json.loads(path.read_text(encoding="utf-8"))
        for path in sorted(L10N.glob("*.json"))
    }


# Japanese shares these words with Chinese source strings; identical values
# are correct there and must not count as untranslated.
SAME_AS_ZH_OK = {
    "ja": {
        "保存",
        "最小化",
        "最大化",
        "音量",
        "背景",
        "{seconds} 秒",
        "{score} 点",
        "{year} · {month}月{day}日",
        "下降",
        "明度",
        "管理",
        "色相",
        "配色",
        "ID：{id}",
    },
}


def audit_tables(tables: dict[str, dict[str, str]]) -> list[str]:
    base = tables["zh_Hans"]
    problems: list[str] = []
    for name, table in tables.items():
        if name == "zh_Hans":
            continue
        missing = sorted(set(base) - set(table))
        extra = sorted(set(table) - set(base))
        if missing:
            problems.append(f"{name}.json missing {len(missing)}: {missing[:4]}")
        if extra:
            problems.append(f"{name}.json extra {len(extra)}: {extra[:4]}")
        if name != "zh_Hant":
            ok = SAME_AS_ZH_OK.get(name, set())
            copied = [
                k
                for k, v in table.items()
                if k in base and v == base[k] and k not in ok
            ]
            if copied:
                problems.append(
                    f"{name}.json copies {len(copied)} zh_Hans values: {copied[:4]}"
                )
    return problems


def main() -> int:
    verbose = "--verbose" in sys.argv
    tables = load_tables()
    keys, _stray = data_keys()

    if "--keys" in sys.argv:
        print(json.dumps(sorted(keys), ensure_ascii=False, indent=2))
        return 0

    code_problems = audit_code(verbose)
    table_problems = audit_tables(tables)

    base = tables["zh_Hans"]
    missing_keys = sorted(k for k in keys if not covered_by(k, set(base)))
    stale = sorted(k for k in base if not counts_as_key(k, keys))

    print(f"unwrapped text sinks: {len(code_problems)}")
    for line in code_problems if verbose else code_problems[:25]:
        print("  " + line)
    print(f"\ntable mismatches: {len(table_problems)}")
    for line in table_problems:
        print("  " + line)
    print(f"\nkeys in code: {len(keys)}   table keys: {len(base)}")
    print(f"missing from tables: {len(missing_keys)}")
    for key in missing_keys if verbose else missing_keys[:15]:
        print(f"  {json.dumps(key, ensure_ascii=False)[:90]}")
    print(f"stale table keys: {len(stale)}")
    for key in stale if verbose else stale[:15]:
        print(f"  {json.dumps(key, ensure_ascii=False)[:90]}")

    bad = len(code_problems) + len(table_problems) + len(missing_keys) + len(stale)
    print(f"\n{'FAIL' if bad else 'OK'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
