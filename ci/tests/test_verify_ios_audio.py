"""Device-free checks of the iOS binary export gate."""

import contextlib
import importlib.util
import io
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_ios_audio", REPO / "ci/verify-ios-audio.py"
)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class IosAudioExportsTest(unittest.TestCase):
    def test_gate_covers_every_reader_symbol_dart_looks_up(self):
        dart = (REPO / "lib/audio/native/lazer_audio_library.dart").read_text(
            encoding="utf-8"
        )
        required = set(re.findall(r"'(lazer_bridge_reader_\w+)'", dart))
        self.assertEqual(set(VERIFY.BRIDGE_SYMBOLS), required)
        self.assertEqual(len(required), 10)

    def test_executable_rejects_each_missing_reader_symbol(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "Runner"
            binary.touch()
            all_symbols = set(VERIFY.ABI_SYMBOLS + VERIFY.BRIDGE_SYMBOLS)
            with patch.object(VERIFY, "run", return_value="architecture: arm64"):
                for symbol in VERIFY.BRIDGE_SYMBOLS:
                    with self.subTest(symbol=symbol):
                        with patch.object(
                            VERIFY, "exported_symbols", return_value=all_symbols - {symbol}
                        ), contextlib.redirect_stderr(io.StringIO()):
                            self.assertEqual(VERIFY.verify_executable(binary), 1)

    def test_archive_rejects_each_missing_reader_symbol(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in (
                "liblazer-audio.a", "liblazer-audio-bridge.a", "libavformat.a",
                "libavcodec.a", "libavutil.a", "libswresample.a",
            ):
                (root / name).touch()
            for symbol in VERIFY.BRIDGE_SYMBOLS:
                with self.subTest(symbol=symbol):
                    def symbols(path):
                        if path.name == "liblazer-audio.a":
                            return set(VERIFY.ABI_SYMBOLS)
                        return set(VERIFY.BRIDGE_SYMBOLS) - {symbol}

                    with patch.object(VERIFY, "run", return_value="architecture: arm64"), \
                            patch.object(VERIFY, "defined_symbols", side_effect=symbols), \
                            contextlib.redirect_stderr(io.StringIO()):
                        self.assertEqual(VERIFY.verify_archive(root), 1)


if __name__ == "__main__":
    unittest.main()
