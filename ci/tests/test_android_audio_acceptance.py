"""Device-free checks for the shipped USB capability and LGPL relink package."""

import hashlib
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile, ZIP_DEFLATED


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_android_audio", REPO / "ci/verify-android-audio.py"
)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)
USB_EXPORT = "lazer_audio_android_usb_backend_version"


def elf_exports(symbols):
    """Minimal ARM64 DSO with a real dynamic export table and 16 KiB LOAD."""
    strings = bytearray(b"\0")
    entries = bytearray(24)
    for symbol in sorted(symbols):
        name = len(strings)
        strings.extend(symbol.encode() + b"\0")
        entries.extend(struct.pack("<IBBHQQ", name, 0x12, 0, 1, 0, 0))
    string_offset = 64 + 56 + 3 * 64
    symbol_offset = (string_offset + len(strings) + 7) & ~7
    data = bytearray(symbol_offset + len(entries))
    data[:16] = b"\x7fELF\x02\x01\x01" + bytes(9)
    struct.pack_into(
        "<HHIQQQIHHHHHH", data, 16,
        3, 183, 1, 0, 64, 120, 0, 64, 56, 1, 64, 3, 0,
    )
    struct.pack_into(
        "<IIQQQQQQ", data, 64, 1, 5, 0, 0, 0, len(data), len(data), 16384,
    )
    struct.pack_into(
        "<IIQQQQIIQQ", data, 184,
        0, 3, 0, 0, string_offset, len(strings), 0, 0, 1, 0,
    )
    struct.pack_into(
        "<IIQQQQIIQQ", data, 248,
        0, 11, 0, 0, symbol_offset, len(entries), 1, 0, 8, 24,
    )
    data[string_offset:string_offset + len(strings)] = strings
    data[symbol_offset:] = entries
    return data


class AndroidUsbPackageTest(unittest.TestCase):
    def apk(self, path, *, abis=("arm64-v8a", "armeabi-v7a"), omit=(), extra=()):
        with ZipFile(path, "w", compression=ZIP_DEFLATED) as package:
            for abi in abis:
                for library in (
                    "libflutter.so", "libapp.so", "liblazer-audio.so",
                    "liblazer-audio-bridge.so",
                ):
                    name = f"lib/{abi}/{library}"
                    if name not in omit:
                        package.writestr(name, b"payload fixture")
            for name in extra:
                package.writestr(name, b"third-party payload fixture")

    def verify_apk(self, path, *arguments):
        # Isolate APK completeness from the separately tested ELF parser.
        with patch.object(sys, "argv", ["verify-android-audio", "--apk", str(path), *arguments]), \
                patch.object(VERIFY, "verify_elf", return_value="ELF fixture accepted"), \
                contextlib.redirect_stdout(io.StringIO()):
            VERIFY.main()

    def test_complete_arm_apk_preserves_the_existing_release_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.apk"
            self.apk(path)
            self.verify_apk(path)

    def test_apk_rejects_an_extra_abi_with_only_plugin_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.apk"
            self.apk(path, extra=("lib/x86_64/libplugin.so",))
            with self.assertRaisesRegex(ValueError, "incomplete ABI x86_64"):
                self.verify_apk(path)

    def test_apk_requires_flutter_and_app_for_every_advertised_abi(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.apk"
            for abi in ("arm64-v8a", "armeabi-v7a"):
                for library in ("libflutter.so", "libapp.so"):
                    with self.subTest(abi=abi, library=library):
                        self.apk(path, omit=(f"lib/{abi}/{library}",))
                        with self.assertRaisesRegex(ValueError, "incomplete ABI " + abi):
                            self.verify_apk(path)

    def test_explicit_split_abi_is_complete_without_the_other_arm_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app-arm64.apk"
            self.apk(path, abis=("arm64-v8a",))
            self.verify_apk(path, "--abi", "arm64-v8a")
            with self.assertRaisesRegex(ValueError, "missing required APK ABI"):
                self.verify_apk(path)

    def test_engine_without_usb_capability_is_rejected(self):
        with self.assertRaisesRegex(ValueError, USB_EXPORT):
            VERIFY.verify_elf(
                elf_exports(VERIFY.ENGINE_EXPORTS - {USB_EXPORT}),
                "arm64-v8a", "liblazer-audio.so",
            )

    def test_engine_and_bridge_keep_the_existing_export_gate(self):
        for library, symbols in (
            ("liblazer-audio.so", VERIFY.ENGINE_EXPORTS | {USB_EXPORT}),
            ("liblazer-audio-bridge.so", VERIFY.BRIDGE_EXPORTS),
        ):
            with self.subTest(library=library):
                VERIFY.verify_elf(elf_exports(symbols), "arm64-v8a", library)
                with self.assertRaisesRegex(ValueError, "missing ABI exports"):
                    VERIFY.verify_elf(
                        elf_exports(symbols - {sorted(symbols)[0]}),
                        "arm64-v8a", library,
                    )

    def package_fixture(self, root):
        repo = root / "repo"
        script = repo / "ci/package-android-audio.py"
        script.parent.mkdir(parents=True)
        shutil.copyfile(REPO / "ci/package-android-audio.py", script)
        for relative in (
            "native/lazer-audio/src/exports_android.map",
            "native/lazer-audio/cmake/AndroidUac2.cmake",
            "native/lazer-audio/tools/build_android_dsd_ffmpeg.sh",
        ):
            path = repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("recipe fixture\n", encoding="utf-8")
        build = root / "engine-build"
        objects = build / "lazer-audio/CMakeFiles/lazer-audio.dir"
        objects.mkdir(parents=True)
        (objects / "engine.cpp.o").write_bytes(b"engine object fixture")
        ffmpeg = root / "ffmpeg/lib"
        ffmpeg.mkdir(parents=True)
        for component in ("avformat", "avcodec", "swresample", "avutil"):
            (ffmpeg / f"lib{component}.a").write_bytes(b"ffmpeg archive fixture")
        # Deliberately outside build/_deps: use the actual recorded source override.
        source = root / "custom libusb source"
        (source / "libusb").mkdir(parents=True)
        (source / "COPYING").write_text("license fixture\n", encoding="utf-8")
        (source / "libusb/core.c").write_text("custom source fixture\n", encoding="utf-8")
        (source / ".git").mkdir()
        (source / ".git/config").write_text("private git fixture\n", encoding="utf-8")
        usb = root / "actual-usb/libusb-1.0.a"
        usb.parent.mkdir()
        usb.write_bytes(b"custom libusb archive fixture")
        (build / "lazer-audio/android-usb-relink.json").write_text(
            json.dumps({"archive": str(usb), "source": str(source)}), encoding="utf-8",
        )
        output = root / "dist/audio.tar.gz"
        command = [
            sys.executable, str(script), "--build", str(build),
            "--ffmpeg", str(ffmpeg.parent), "--abi", "arm64-v8a",
            "--output", str(output),
        ]
        return command, output, usb

    def test_relink_package_carries_actual_libusb_source_and_hashes(self):
        with tempfile.TemporaryDirectory(prefix="lazer usb relink ") as directory:
            command, output, _ = self.package_fixture(Path(directory))
            subprocess.run(command, check=True, capture_output=True, text=True)
            with tarfile.open(output) as archive:
                names = set(archive.getnames())
                self.assertTrue({
                    "libusb/lib/libusb-1.0.a", "libusb/COPYING",
                    "libusb/source/libusb/core.c", "libusb/AndroidUac2.cmake",
                    "libusb/CMakeLists.txt", "build_android_dsd_ffmpeg.sh",
                } <= names)
                self.assertFalse(any(".git" in Path(name).parts for name in names))
                manifest = json.load(archive.extractfile("SHA256.json"))
                self.assertEqual(set(manifest), names - {"SHA256.json"})
                for name, digest in manifest.items():
                    self.assertEqual(
                        hashlib.sha256(archive.extractfile(name).read()).hexdigest(), digest,
                    )
                relink = archive.extractfile("relink.sh").read().decode()
                self.assertIn("libusb/lib/libusb-1.0.a", relink)
                self.assertIn("-Wl,-z,defs", relink)
                self.assertIn("max-page-size=16384", relink)
            checksum = hashlib.sha256(output.read_bytes()).hexdigest()
            self.assertEqual(
                Path(str(output) + ".sha256").read_text().split()[0], checksum,
            )

    def test_missing_recorded_libusb_archive_stops_packaging(self):
        with tempfile.TemporaryDirectory(prefix="lazer usb missing ") as directory:
            command, output, usb = self.package_fixture(Path(directory))
            usb.unlink()
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Missing relinking material", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
