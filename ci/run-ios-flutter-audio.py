#!/usr/bin/env python3
"""Exercise Dart FFI, the worker and HiFi through the real iOS Flutter app."""

from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import sys


SPEC = importlib.util.spec_from_file_location(
    "ios_audio_smoke_runner", Path(__file__).with_name("run-ios-audio-smoke.py")
)
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)


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
        result = "PASS Flutter iOS native audio integration\n"
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
