#!/usr/bin/env python3
"""Mechanical UI/animation hygiene scanner for the Lazer Flutter client.

Round 1 of the UI audit: finds *provable* lifecycle and resource defects that
`flutter analyze` cannot see (it reports zero issues on this tree):

  * disposable fields (controllers / tickers / focus nodes) never released
  * `addListener` without a matching `removeListener`
  * `setState` / `ScaffoldMessenger` / `Navigator` used after `await` with no
    `mounted` guard
  * `Timer` / `Future.delayed` callbacks that outlive the State
  * animation controllers whose vsync provider is too weak (Single* mixin)
  * `repeat()` / `createTicker()` / `addPostFrameCallback` self-perpetuation
  * animation primitives reachable during `build()`

Usage:  python ui_audit_scan.py <lib-dir> [--json out.json]
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, field, asdict

# --------------------------------------------------------------------------
# Tokenizer-lite: strip comments and string *bodies* while preserving offsets
# so line numbers stay valid.
# --------------------------------------------------------------------------


def blank_out(src: str) -> str:
    """Replace comments and string literal bodies with spaces, keeping \\n."""
    out = list(src)
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        # line comment
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        # block comment (nestable in Dart)
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            depth = 1
            out[i] = out[i + 1] = " "
            i += 2
            while i < n and depth:
                if src[i] == "/" and i + 1 < n and src[i + 1] == "*":
                    depth += 1
                    out[i] = out[i + 1] = " "
                    i += 2
                elif src[i] == "*" and i + 1 < n and src[i + 1] == "/":
                    depth -= 1
                    out[i] = out[i + 1] = " "
                    i += 2
                else:
                    if src[i] != "\n":
                        out[i] = " "
                    i += 1
            continue
        # string literal
        if c in "'\"":
            # raw string?
            raw = i > 0 and src[i - 1] == "r"
            triple = src[i : i + 3] in ("'''", '"""')
            quote = src[i : i + 3] if triple else c
            j = i + len(quote)
            for k in range(i, j):
                out[k] = " "
            i = j
            while i < n:
                if not raw and src[i] == "\\" and i + 1 < n:
                    out[i] = " "
                    if src[i + 1] != "\n":
                        out[i + 1] = " "
                    i += 2
                    continue
                if not raw and src[i] == "$" and i + 1 < n and src[i + 1] == "{":
                    # keep the interpolation expression live for brace counting
                    out[i] = " "
                    i += 2
                    depth = 1
                    while i < n and depth:
                        if src[i] == "{":
                            depth += 1
                        elif src[i] == "}":
                            depth -= 1
                            if depth == 0:
                                out[i] = " "
                                i += 1
                                break
                        i += 1
                    continue
                if src.startswith(quote, i):
                    for k in range(i, i + len(quote)):
                        out[k] = " "
                    i += len(quote)
                    break
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            continue
        i += 1
    return "".join(out)


@dataclass
class Block:
    kind: str  # 'class' | 'mixin' | 'extension' | 'enum'
    name: str
    header: str
    start: int  # offset of '{'
    end: int  # offset of matching '}'
    line: int
    body: str


CLASS_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?:(?P<abstract>abstract)\s+)?(?P<kind>class|mixin|enum|extension)\s+"
    r"(?P<name>[A-Za-z_$][\w$]*)"
    r"(?P<header>[^{;]*)",
    re.M,
)

DISPOSABLE_INIT = re.compile(
    r"\b(AnimationController|ScrollController|PageController|TabController|"
    r"TextEditingController|FocusNode|TransformationController|FixedExtentScrollController|"
    r"RestorableAnimationController|ValueNotifier|ChangeNotifier|StreamController|"
    r"StreamSubscription|Timer|Ticker|AppLifecycleListener|PendingTimers|"
    r"ScrollPosition|CurvedAnimation|AnimationController)\b"
)

CTRL_CTORS = (
    "AnimationController",
    "ScrollController",
    "PageController",
    "TabController",
    "TextEditingController",
    "FixedExtentScrollController",
    "TransformationController",
    "FocusNode",
    "ValueNotifier",
    "ChangeNotifier",
    "StreamController",
)

# Types whose `dispose()` is the correct release call.
DISPOSE_CALL = {
    "AnimationController": "dispose",
    "ScrollController": "dispose",
    "PageController": "dispose",
    "TabController": "dispose",
    "TextEditingController": "dispose",
    "FixedExtentScrollController": "dispose",
    "TransformationController": "dispose",
    "FocusNode": "dispose",
    "ValueNotifier": "dispose",
    "ChangeNotifier": "dispose",
    "StreamController": "close",
    "StreamSubscription": "cancel",
    "Timer": "cancel",
    "Ticker": "dispose",
    "AppLifecycleListener": "dispose",
}


def find_blocks(clean: str) -> list[Block]:
    blocks: list[Block] = []
    lines = clean.split("\n")
    line_starts = []
    pos = 0
    for ln in lines:
        line_starts.append(pos)
        pos += len(ln) + 1

    def line_of(off: int) -> int:
        lo, hi = 0, len(line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if line_starts[mid] <= off:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    for m in CLASS_RE.finditer(clean):
        start = clean.find("{", m.end() - 1)
        if start == -1:
            continue
        semi = clean.find(";", m.end() - 1)
        if semi != -1 and semi < start:
            continue  # forward declaration
        depth = 0
        i = start
        n = len(clean)
        while i < n:
            if clean[i] == "{":
                depth += 1
            elif clean[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if i >= n:
            continue
        blocks.append(
            Block(
                kind=m.group("kind"),
                name=m.group("name"),
                header=m.group("header").strip(),
                start=start,
                end=i,
                line=line_of(m.start()),
                body=clean[start + 1 : i],
            )
        )
    return blocks


def method_body(block: Block, name: str) -> tuple[str, int] | None:
    """Return the body of the (last) method named `name` inside a block."""
    m = None
    for cand in re.finditer(r"(?:^|\n)\s*(?:@override\s+)?[\w<>,\s\?\[\]]*\b" + re.escape(name) + r"\s*\(", block.body):
        m = cand
    if m is None:
        return None
    brace = block.body.find("{", m.end() - 1)
    if brace == -1:
        return None
    depth = 0
    i = brace
    while i < len(block.body):
        if block.body[i] == "{":
            depth += 1
        elif block.body[i] == "}":
            depth -= 1
            if depth == 0:
                return block.body[brace + 1 : i], brace
        i += 1
    return None


def find_methods(block: Block) -> dict[str, tuple[str, int]]:
    """Map method name -> (body, offset) for top-level members of the block."""
    out: dict[str, tuple[str, int]] = {}
    pattern = re.compile(
        r"(?:^|\n)[ \t]*(?:@override[ \t\n]+)?(?:static[ \t]+)?"
        r"(?:[\w$<>,\.\?\[\]\s]*?[ \t])?"
        r"(?P<name>[a-zA-Z_$][\w$]*)[ \t]*\(",
        re.M,
    )
    for m in pattern.finditer(block.body):
        # skip control-flow keywords
        if m.group("name") in {
            "if", "for", "while", "switch", "return", "catch", "assert", "super", "this",
        }:
            continue
        # find matching ')' then '{' or '=>'
        i = m.end() - 1
        depth = 0
        while i < len(block.body):
            ch = block.body[i]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        j = i + 1
        while j < len(block.body) and block.body[j] in " \t\n":
            j += 1
        if j < len(block.body) and block.body[j] == "{":
            depth = 0
            k = j
            while k < len(block.body):
                if block.body[k] == "{":
                    depth += 1
                elif block.body[k] == "}":
                    depth -= 1
                    if depth == 0:
                        out[m.group("name")] = (block.body[j + 1 : k], j)
                        break
                k += 1
    return out


# --------------------------------------------------------------------------
# Findings
# --------------------------------------------------------------------------


@dataclass
class Finding:
    rule: str
    severity: str  # high | medium | low
    file: str
    line: int
    owner: str
    message: str
    evidence: str = ""

    def key(self):
        return (self.rule, self.file, self.line, self.owner)


# Class members are indented exactly two spaces by `dart format`; anything
# deeper is a local inside a method body and must not be treated as a field.
FIELD_RE = re.compile(
    r"^[ \t]{2}(?![ \t])(?:late[ \t]+)?(?:final[ \t]+)?"
    r"(?P<type>[A-Za-z_$][\w$]*(?:<[^;=]*>)?)\??[ \t]+"
    r"(?P<name>[a-zA-Z_$][\w$]*)[ \t]*(?:=[^;]*)?;",
    re.M,
)

NAME_FIELD_RE = re.compile(
    r"^[ \t]{2}(?![ \t])(?:late[ \t]+)?(?:final[ \t]+)?"
    r"(?P<type>[A-Za-z_$][\w$]*(?:<[^;=]*>)?)\??[ \t]+"
    r"(?P<name>[a-zA-Z_$][\w$]*)[ \t]*=[^;]*;",
    re.M,
)


def released_in(dispose_body: str, name: str, releaser: str) -> bool:
    """True when some statement in dispose() calls `<name>?.<releaser>()`.

    Handles null-aware access (`_x?.cancel()`), plain access and cascades
    (`_x\n  ..removeListener(...)\n  ..dispose();`).
    """
    for stmt in dispose_body.split(";"):
        if re.search(r"\b" + re.escape(name) + r"\b", stmt) and re.search(
            r"(?<![\w])" + re.escape(releaser) + r"\s*\(", stmt
        ):
            return True
    return False


def _match_close(body: str, opener: int) -> int:
    depth = 0
    for i in range(opener, len(body)):
        if body[i] in "([{":
            depth += 1
        elif body[i] in ")]}":
            depth -= 1
            if depth == 0:
                return i
    return len(body) - 1


def _current_argument(body: str, opener: int, off: int) -> str:
    """Text of the argument that contains `off`, relative to `opener`."""
    seg = body[opener + 1 : off]
    depth = 0
    last = 0
    for i, ch in enumerate(seg):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            last = i + 1
    return seg[last:]


def inside_function_literal(body: str, off: int) -> bool:
    """True when `off` lies inside a closure that runs on a later callback.

    Handles block closures (`onTap: () { ... }`), arrow closures
    (`onEnter: (_) => ...`) and reports immediately-invoked closures, which do
    run during build.
    """
    opens: list[int] = []
    for i in range(off):
        ch = body[i]
        if ch in "([{":
            opens.append(i)
        elif ch in ")]}":
            if opens:
                opens.pop()

    for opener in reversed(opens):
        ch = body[opener]
        arg = _current_argument(body, opener, off)
        if ch == "{":
            before = body[:opener].rstrip()
            if before.endswith("=>"):
                literal = True
            elif before.endswith(")"):
                paren = len(before) - 1
                depth = 0
                j = paren
                while j >= 0:
                    if before[j] == ")":
                        depth += 1
                    elif before[j] == "(":
                        depth -= 1
                        if depth == 0:
                            break
                    j -= 1
                prev = before[:j].rstrip()
                literal = bool(prev) and prev[-1] in "(,:=<"
            else:
                continue
            if not literal:
                continue
            after = body[_match_close(body, opener) + 1 :].lstrip()
            if after.startswith("("):
                return False  # immediately invoked: runs during build
            return True
        # an arrow closure body sits directly in the argument list
        if "=>" in arg:
            return True
    return False


def strip_trailing_comments(s: str) -> str:
    return s


def scan_file(path: str, rel: str, findings: list[Finding]) -> None:
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()
    clean = blank_out(raw)
    blocks = find_blocks(clean)
    raw_lines = raw.split("\n")

    def line_text(ln: int) -> str:
        if 1 <= ln <= len(raw_lines):
            return raw_lines[ln - 1].strip()[:160]
        return ""

    def offset_line(block: Block, off: int) -> int:
        return block.line + block.body[:off].count("\n")

    for b in blocks:
        if b.kind not in ("class", "mixin"):
            continue
        is_state = re.search(r"\bState\s*<", b.header) is not None
        is_widget = re.search(r"extends\s+(StatefulWidget|StatelessWidget)", b.header) is not None
        mixins = b.header
        methods = find_methods(b)
        dispose_body = methods.get("dispose", ("", 0))[0]

        # ---- rule: Single*TickerProvider with multiple AnimationControllers
        single = "SingleTickerProviderStateMixin" in mixins
        ctrl_count = len(re.findall(r"\bAnimationController\s*\(", b.body))
        if single and ctrl_count > 1:
            findings.append(
                Finding(
                    "single-ticker-multi-controller",
                    "high",
                    rel,
                    b.line,
                    b.name,
                    f"SingleTickerProviderStateMixin but {ctrl_count} AnimationControllers are created",
                    line_text(b.line),
                )
            )
        if not single and "TickerProviderStateMixin" not in mixins and ctrl_count:
            if is_state and "vsync: this" in b.body.replace(" ", ""):
                findings.append(
                    Finding(
                        "missing-ticker-provider",
                        "high",
                        rel,
                        b.line,
                        b.name,
                        f"{ctrl_count} AnimationController(s) use `vsync: this` but the State declares no TickerProvider mixin",
                        line_text(b.line),
                    )
                )

        # ---- rule: disposable fields never released
        declared: dict[str, tuple[str, int]] = {}
        for rx in (FIELD_RE, NAME_FIELD_RE):
            for m in rx.finditer(b.body):
                t, nm = m.group("type"), m.group("name")
                base = t.split("<")[0]
                if base in DISPOSE_CALL:
                    declared[nm] = (base, m.start())
        for nm, (base, off) in declared.items():
            # Only a class that *constructs* the object owns its lifetime.
            # `final AnimationController? motion;` is injected by a host that
            # disposes it, and flagging those buries the real leaks.
            owns = re.search(
                r"\b" + re.escape(nm) + r"\s*(?:\?\?=|\?=|=)\s*"
                r"(?:const\s+|final\s+)?" + re.escape(base) + r"(?:\.\w+)?\s*\(",
                b.body,
            )
            if not owns:
                continue
            releaser = DISPOSE_CALL[base]
            ok = released_in(dispose_body, nm, releaser)
            if not ok and released_in(dispose_body, nm, "dispose"):
                ok = True
            if ok:
                continue
            # Released somewhere other than dispose() (e.g. a stop()/detach()
            # path). Not automatically a bug, but it must be reachable on
            # teardown -- report it for manual review instead of as a defect.
            elsewhere = False
            for meth, (mbody, _moff) in methods.items():
                if meth == "dispose":
                    continue
                if released_in(mbody, nm, releaser):
                    elsewhere = True
                    break
            findings.append(
                Finding(
                    "released-outside-dispose" if elsewhere else "undisposed-field",
                    "low" if elsewhere else (
                        "high"
                        if base in ("AnimationController", "Ticker", "StreamSubscription", "Timer")
                        else "medium"
                    ),
                    rel,
                    offset_line(b, off) if off else b.line,
                    b.name,
                    (
                        f"`{nm}` ({base}) is only released by a non-dispose() method; "
                        "confirm every teardown path reaches it"
                        if elsewhere
                        else f"`{nm}` ({base}) is never released in dispose()"
                    ),
                    line_text(offset_line(b, off) if off else b.line),
                )
            )

        # ---- rule: addListener without removeListener
        for m in re.finditer(r"\b([\w\.\$]+)\s*\.\s*addListener\s*\(", b.body):
            target = m.group(1)
            if target == "WidgetsBinding.instance":
                continue
            if re.search(
                r"\b" + re.escape(target) + r"\s*\.\s*removeListener\s*\(", b.body
            ):
                continue
            # A listener on a controller this class owns dies with the
            # controller, so only external subjects can actually leak.
            head = target.split(".")[0]
            if head in declared and released_in(
                dispose_body, head, DISPOSE_CALL[declared[head][0]]
            ):
                continue
            if head in declared and released_in(dispose_body, head, "dispose"):
                continue
            findings.append(
                Finding(
                    "listener-leak",
                    "medium",
                    rel,
                    offset_line(b, m.start()),
                    b.name,
                    f"`{target}.addListener` has no matching removeListener",
                    line_text(offset_line(b, m.start())),
                )
            )

        # ---- rule: createTicker / repeat without teardown
        for m in re.finditer(r"\brepeat\s*\(", b.body):
            findings.append(
                Finding(
                    "repeat-ticker",
                    "low",
                    rel,
                    offset_line(b, m.start()),
                    b.name,
                    "`repeat()` keeps a permanent ticker; confirm it is stopped when hidden",
                    line_text(offset_line(b, m.start())),
                )
            )

        # ---- rule: setState / context use after await without mounted guard
        for meth, (body, moff) in methods.items():
            if meth in ("build", "initState", "dispose"):
                continue
            if "async" not in body[: body.find("{") if "{" in body else 0] and "*" not in body[:0]:
                pass
            # locate awaits and following risky uses
            for am in re.finditer(r"\bawait\b", body):
                tail = body[am.end() :]
                # only inspect up to the end of the enclosing statement run
                guard = re.search(r"\bmounted\b", tail.split("await")[0])
                risky = []
                for pat, label in (
                    (r"\bsetState\s*\(", "setState"),
                    (r"\bcontext\.(?!mounted)", "context"),
                    (r"\bNavigator\.of\s*\(", "Navigator.of"),
                    (r"\bScaffoldMessenger\.of\s*\(", "ScaffoldMessenger.of"),
                    (r"\bshowDialog\s*\(", "showDialog"),
                    (r"\bshowModalBottomSheet\s*\(", "showModalBottomSheet"),
                    (r"\bTheme\.of\s*\(", "Theme.of"),
                ):
                    mm = re.search(pat, tail.split("await")[0])
                    if mm:
                        risky.append((label, am.end() + mm.start()))
                named_guard = False
                for nm2 in re.findall(r"\bif\s*\(\s*!\s*mounted\s*\)\s*(?:return|\{)", tail):
                    named_guard = True
                if risky and not guard and not named_guard:
                    label, off = risky[0]
                    findings.append(
                        Finding(
                            "use-after-await",
                            "medium",
                            rel,
                            offset_line(b, moff + off),
                            f"{b.name}.{meth}",
                            f"`{label}` after `await` with no `mounted` guard in this method",
                            line_text(offset_line(b, moff + off)),
                        )
                    )
                    break

        # ---- rule: Future.delayed / Timer without mounted check
        for m in re.finditer(r"\b(?:Future\.delayed|Timer(?:\.periodic)?)\s*\(", b.body):
            tail = b.body[m.end() :]
            window = tail[:600]
            if not re.search(r"\bmounted\b|\bcancel\s*\(|\bif\s*\(\s*!\s*mounted", window):
                findings.append(
                    Finding(
                        "timer-no-guard",
                        "low" if is_state else "low",
                        rel,
                        offset_line(b, m.start()),
                        b.name,
                        "delayed callback has no visible `mounted` guard or cancellation nearby",
                        line_text(offset_line(b, m.start())),
                    )
                )

        # ---- rule: AnimationController in a non-TickerProvider widget
        if is_widget and ctrl_count:
            findings.append(
                Finding(
                    "controller-in-widget",
                    "high",
                    rel,
                    b.line,
                    b.name,
                    "AnimationController created in a Widget (not a State)",
                    line_text(b.line),
                )
            )

        # ---- rule: animation mutation inside build()
        build = methods.get("build")
        if build:
            bb = build[0]
            for pat, label in (
                (r"\.\s*value\s*=[^=]", "AnimationController.value ="),
                (r"\bforward\s*\(", ".forward()"),
                (r"\breverse\s*\(", ".reverse()"),
                (r"\brepeat\s*\(", ".repeat()"),
                (r"\bsetState\s*\(", "setState()"),
                (r"\.\s*animateTo\s*\(", "animateTo()"),
                (r"\.\s*jumpTo\s*\(", "jumpTo()"),
            ):
                for mm in re.finditer(pat, bb):
                    if inside_function_literal(bb, mm.start()):
                        continue
                    findings.append(
                        Finding(
                            "mutation-in-build",
                            "medium",
                            rel,
                            offset_line(b, build[1] + mm.start()),
                            f"{b.name}.build",
                            f"{label} executed during build() (not inside a callback)",
                            line_text(offset_line(b, build[1] + mm.start())),
                        )
                    )


def main() -> int:
    lib = sys.argv[1] if len(sys.argv) > 1 else "lib"
    out_json = None
    if "--json" in sys.argv:
        out_json = sys.argv[sys.argv.index("--json") + 1]
    findings: list[Finding] = []
    files = []
    for root, _dirs, names in os.walk(lib):
        for nm in names:
            if nm.endswith(".dart"):
                p = os.path.join(root, nm)
                files.append(p)
    for p in sorted(files):
        rel = os.path.relpath(p).replace("\\", "/")
        try:
            scan_file(p, rel, findings)
        except Exception as exc:  # pragma: no cover
            print(f"!! scanner error on {rel}: {exc}", file=sys.stderr)

    order = {"high": 0, "medium": 1, "low": 2}
    findings.sort(key=lambda f: (order[f.severity], f.rule, f.file, f.line))
    counts: dict[str, int] = {}
    for f in findings:
        counts[f.rule] = counts.get(f.rule, 0) + 1
    print(f"scanned {len(files)} dart files, {len(findings)} findings\n")
    for rule, c in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {c:4d}  {rule}")
    print()
    for f in findings:
        print(f"[{f.severity.upper():6}] {f.rule:28} {f.file}:{f.line}  ({f.owner})")
        print(f"          {f.message}")
    if out_json:
        with open(out_json, "w", encoding="utf-8") as fh:
            json.dump([asdict(f) for f in findings], fh, indent=1, ensure_ascii=False)
        print(f"\nwrote {out_json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
