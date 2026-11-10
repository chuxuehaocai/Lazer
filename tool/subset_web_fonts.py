"""Build the MiSans subsets that ship with the web build.

The browser has no system font fallback for CanvasKit, so every glyph the UI
can show has to be inside the bundled font.  The full MiSans files cover 29.5k
glyphs and weigh ~8 MB each, which is 22 MB of font traffic on first load.
This script keeps the repertoire the client actually needs:

* the complete GB2312 set, so ordinary Chinese metadata keeps rendering;
* Big5 level-1 and JIS level-1, for traditional Chinese and Japanese titles;
* every character that appears in the Dart sources and the l10n assets;
* Latin/Greek/Cyrillic, punctuation, box drawing and common symbols.

The result is written to ``web/assets/assets/fonts``.  Flutter copies the
``web`` directory over the generated bundle last, so every ``flutter build
web`` ships these files in place of the full ones.  Native builds read
``assets/fonts`` and keep the full glyph repertoire.

Usage: python tool/subset_web_fonts.py
"""

from __future__ import annotations

import glob
import os
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "web", "assets", "assets", "fonts")
FAMILIES = ("Regular", "Medium", "Semibold", "Bold")

# Ranges that are cheap and keep Latin metadata, symbols and lyric punctuation
# intact.  Any codepoint the font does not actually carry is dropped later.
EXTRA_RANGES = (
    (0x0020, 0x02FF),  # ASCII, Latin-1, Latin Extended A/B, IPA
    (0x0300, 0x036F),  # combining diacritics
    (0x0370, 0x03FF),  # Greek
    (0x0400, 0x04FF),  # Cyrillic
    (0x1E00, 0x1EFF),  # Latin Extended Additional
    (0x2000, 0x206F),  # general punctuation
    (0x20A0, 0x20CF),  # currency
    (0x2100, 0x214F),  # letterlike symbols
    (0x2190, 0x21FF),  # arrows
    (0x2200, 0x22FF),  # mathematical operators
    (0x2500, 0x257F),  # box drawing
    (0x25A0, 0x25FF),  # geometric shapes
    (0x2600, 0x26FF),  # miscellaneous symbols
    (0x3000, 0x30FF),  # CJK punctuation, hiragana, katakana
    (0x3100, 0x312F),  # bopomofo
    (0x3190, 0x31FF),  # kanbun, bopomofo extended, CJK strokes
    (0x3200, 0x33FF),  # enclosed CJK, CJK compatibility
    (0xFE10, 0xFE1F),  # vertical forms
    (0xFE30, 0xFE4F),  # CJK compatibility forms
    (0xFF00, 0xFFEF),  # halfwidth and fullwidth forms
)


def coded_charset(encoding: str, lead: range, trail: tuple[range, ...]) -> set[str]:
    chars: set[str] = set()
    for first in lead:
        for second in range(0x100):
            if not any(second in part for part in trail):
                continue
            try:
                chars.add(bytes((first, second)).decode(encoding))
            except UnicodeDecodeError:
                continue
    return chars


def gb2312() -> set[str]:
    return coded_charset("gb2312", range(0xA1, 0xF8), (range(0xA1, 0xFF),))


def big5_level1() -> set[str]:
    return coded_charset(
        "big5",
        range(0xA4, 0xC7),
        (range(0x40, 0x7F), range(0xA1, 0xFF)),
    )


def jis_level1() -> set[str]:
    chars: set[str] = set()
    for row in range(16, 49):
        for cell in range(1, 95):
            try:
                chars.add(bytes((row + 0x80, cell + 0x80)).decode("euc_jp"))
            except UnicodeDecodeError:
                continue
    return chars


def source_text() -> str:
    parts: list[str] = []
    for path in glob.glob(os.path.join(ROOT, "lib", "**", "*.dart"), recursive=True):
        with open(path, encoding="utf-8") as handle:
            parts.append(handle.read())
    for path in glob.glob(
        os.path.join(ROOT, "assets", "**", "*.json"), recursive=True
    ):
        with open(path, encoding="utf-8") as handle:
            parts.append(handle.read())
    return "\n".join(parts)


def build_charset(cmap: dict[int, str]) -> set[str]:
    chars = gb2312() | big5_level1() | jis_level1() | set(source_text())
    for first, last in EXTRA_RANGES:
        chars.update(chr(cp) for cp in range(first, last + 1))
    return {char for char in chars if ord(char) in cmap}


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    for family in FAMILIES:
        source = os.path.join(ROOT, "assets", "fonts", f"MiSans-{family}.ttf")
        target = os.path.join(OUT_DIR, f"MiSans-{family}.ttf")
        font = TTFont(source, recalcTimestamp=False)
        charset = build_charset(font.getBestCmap())
        options = subset.Options()
        options.layout_features = ["*"]
        options.name_IDs = ["*"]
        options.name_legacy = True
        options.name_languages = ["*"]
        options.notdef_glyph = True
        options.notdef_outline = True
        options.recommended_glyphs = True
        options.glyph_names = False
        options.legacy_cmap = True
        options.symbol_cmap = True
        subsetter = subset.Subsetter(options=options)
        subsetter.populate(unicodes=[ord(char) for char in charset])
        subsetter.subset(font)
        # Keep the committed subsets byte-for-byte reproducible.
        font["head"].modified = 0
        font.save(target)
        print(
            f"{family}: {len(charset)} codepoints, "
            f"{os.path.getsize(target) / 1024 / 1024:.2f} MB -> {target}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
