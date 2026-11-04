"""Device-free checks of the iOS binary export gate."""

import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import re
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile


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

    def test_symbol_table_cannot_substitute_for_empty_dynamic_exports(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "Runner"
            binary.touch()
            with patch.object(VERIFY, "run", return_value="architecture: arm64"), \
                    patch.object(VERIFY, "exported_symbols", return_value=set()), \
                    patch.object(VERIFY, "defined_symbols") as ordinary_symbols, \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(VERIFY.verify_executable(binary), 1)
                ordinary_symbols.assert_not_called()

    def test_failed_dynamic_export_inspection_fails_the_gate(self):
        with patch.object(VERIFY, "run", side_effect=SystemExit("dyld_info failed")):
            with self.assertRaisesRegex(SystemExit, "dyld_info failed"):
                VERIFY.exported_symbols(Path("Runner"))

    def test_executable_rejects_each_shared_ffmpeg_component(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "Runner"
            binary.touch()
            all_symbols = set(VERIFY.ABI_SYMBOLS + VERIFY.BRIDGE_SYMBOLS)
            for component in ("avformat", "avcodec", "avutil", "swresample"):
                with self.subTest(component=component):
                    def run(*command):
                        if command[0] == "lipo":
                            return "architecture: arm64"
                        return f"Runner:\n    @rpath/lib{component}.dylib (version 1.0)"

                    with patch.object(VERIFY, "run", side_effect=run), \
                            patch.object(VERIFY, "exported_symbols", return_value=all_symbols):
                        with self.assertRaisesRegex(SystemExit, "must be linked statically"):
                            VERIFY.verify_executable(binary)

    def ipa(self, path, *, executable="Runner", binary=b"packaged Mach-O"):
        with ZipFile(path, "w") as package:
            package.writestr("Payload/Runner.app/Info.plist", plistlib.dumps({
                "CFBundleExecutable": executable,
            }))
            if binary is not None:
                package.writestr("Payload/Runner.app/" + executable, binary)

    def test_ipa_verifies_the_packaged_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "Lazer-iOS-aarch64.ipa"
            self.ipa(ipa)

            def verify(binary):
                self.assertEqual(binary.name, "Runner")
                self.assertEqual(binary.read_bytes(), b"packaged Mach-O")
                return 0

            with patch.object(VERIFY, "verify_executable", side_effect=verify) as check, \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(VERIFY.verify_ipa(ipa), 0)
                check.assert_called_once()

    def test_ipa_propagates_missing_native_exports(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "Lazer-iOS-aarch64.ipa"
            self.ipa(ipa)
            with patch.object(VERIFY, "run", return_value="architecture: arm64"), \
                    patch.object(VERIFY, "exported_symbols", return_value=set(VERIFY.ABI_SYMBOLS)), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(VERIFY.verify_ipa(ipa), 1)

    def test_ipa_rejects_missing_or_empty_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "Lazer-iOS-aarch64.ipa"
            for binary in (None, b""):
                with self.subTest(binary=binary):
                    self.ipa(ipa, binary=binary)
                    with self.assertRaises(SystemExit):
                        VERIFY.verify_ipa(ipa)

    def test_ipa_rejects_invalid_executable_path(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "Lazer-iOS-aarch64.ipa"
            self.ipa(ipa, executable="../../wrong-binary")
            with self.assertRaisesRegex(SystemExit, "invalid CFBundleExecutable"):
                VERIFY.verify_ipa(ipa)

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
