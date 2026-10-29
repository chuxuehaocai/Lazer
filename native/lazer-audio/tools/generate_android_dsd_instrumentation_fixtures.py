"""Generate compact DSD fixtures for Android JNI instrumentation tests."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def run_generator(script: Path, *arguments: str) -> None:
    subprocess.run([sys.executable, str(script), *arguments], check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()

    tools = Path(__file__).resolve().parent
    output = args.directory.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="lazer-android-dsd-") as temporary:
        fixtures = Path(temporary)
        run_generator(
            tools / "generate_dsf_test_fixtures.py",
            str(fixtures), "--duration-ms", "100", "--rates",
            "64", "128", "256", "512", "1024",
        )
        run_generator(
            tools / "generate_dff_test_fixtures.py",
            str(fixtures), "--duration-ms", "100", "--rates",
            "64", "128", "256", "512", "1024",
        )
        run_generator(
            tools / "generate_dst_test_fixtures.py",
            str(fixtures), "--frames", "75", "--rate", "64",
        )

        # Keep fixtures short while covering every PCM rate and each Android DoP rate.
        names = [
            *(f"dsd{rate}_test.dsf" for rate in (64, 128, 256, 512, 1024)),
            *(f"dff{rate}_test.dff" for rate in (64, 128, 256, 512, 1024)),
            "dst64_verbatim.dff",
        ]
        for name in names:
            shutil.copyfile(fixtures / name, output / name)

        # Keep a recognizable .dsf name/MIME while making the native parser reject the container.
        malformed_dsf = bytearray((fixtures / "dsd64_test.dsf").read_bytes())
        malformed_dsf[:4] = b"BAD "
        (output / "malformed_test.dsf").write_bytes(malformed_dsf)


if __name__ == "__main__":
    main()
