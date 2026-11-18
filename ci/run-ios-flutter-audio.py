#!/usr/bin/env python3
"""Exercise Dart FFI, the worker and HiFi through the real iOS Flutter app."""

from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import re
import sys


SPEC = importlib.util.spec_from_file_location(
    "ios_audio_smoke_runner", Path(__file__).with_name("run-ios-audio-smoke.py")
)
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)

EXPECTED_TESTS = (
    "iOS selects the linked native engine",
    "iOS factory plays through the native engine and worker",
    "iOS decodes high resolution PCM and DSD through RemoteIO",
    "iOS HiFi controller applies audible-path DSP",
    "iOS plays HTTP audio through the native growing reader",
    "iOS strict USB PCM refuses a non-USB route without fallback",
    "iOS required DoP refuses a non-USB route without PCM fallback",
)

_TEST_SUMMARY = re.compile(
    r"^\d+:\d{2} \+(\d+)(?: ~(\d+))?(?: -(\d+))?: "
    r"(All tests passed!|Some tests failed\.)$"
)
_ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def verify_flutter_report(path: Path) -> int:
    """Require every expected iOS integration test to run and pass."""
    if not path.is_file():
        raise SMOKE.SmokeFailure("flutter: test output was not captured")
    report = _ANSI_ESCAPE.sub("", path.read_text(encoding="utf-8", errors="replace"))
    summaries = [
        match
        for line in report.splitlines()
        if (match := _TEST_SUMMARY.match(line.strip())) is not None
    ]
    if not summaries:
        raise SMOKE.SmokeFailure("flutter: no final test summary")
    summary = summaries[-1]
    passed = int(summary.group(1))
    skipped = int(summary.group(2) or 0)
    failed = int(summary.group(3) or 0)
    expected = len(EXPECTED_TESTS)
    if (
        summary.group(4) != "All tests passed!"
        or passed != expected
        or skipped
        or failed
    ):
        raise SMOKE.SmokeFailure(
            "flutter: expected "
            f"{expected} passed and 0 skipped; got {passed} passed, "
            f"{skipped} skipped, {failed} failed"
        )
    missing = [name for name in EXPECTED_TESTS if name not in report]
    if missing:
        raise SMOKE.SmokeFailure(
            "flutter: expected integration tests did not run: "
            + ", ".join(missing)
        )
    return passed


class FlutterAudioSession(SMOKE.SmokeSession):
    def __init__(self, repo: Path, out: Path, *, flutter: tuple[str, ...] = ("flutter",), **kwargs):
        super().__init__(repo / "build/ios/iphonesimulator/Runner.app", out,
                         "dev.naominet.lazer", process_name="Runner", **kwargs)
        self.repo = repo
        self.flutter = flutter
        self.timeouts.setdefault("flutter", 1200)

    def playback(self) -> None:
        self.boot_simulator("Lazer Flutter Native Audio Integration")
        self.command(
            "flutter", "test", "--no-pub", "--reporter", "expanded",
            "integration_test/ios_native_engine_test.dart", "-d", self.device,
            tool=self.flutter, cwd=self.repo,
        )
        passed = verify_flutter_report(self.out / "flutter.log")
        result = (
            "PASS Flutter iOS native audio integration "
            f"({passed}/{len(EXPECTED_TESTS)} passed, 0 skipped)\n"
        )
        (self.out / "result.txt").write_text(result, encoding="utf-8")
        self.note(result.strip())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("build/ios-flutter-audio"))
    args = parser.parse_args()
    try:
        FlutterAudioSession(Path(__file__).resolve().parents[1], args.out.resolve()).run()
    except Exception as error:
        print(f"::error::iOS Flutter native audio integration {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
