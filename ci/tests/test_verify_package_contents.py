"""Checks the FFmpeg exclusions in runnable and relinking packages."""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from zipfile import ZipFile


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_package_contents", REPO / "ci/verify-package-contents.py"
)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class PackageContentsTest(unittest.TestCase):
    def test_rejects_ffmpeg_sources_and_notices_in_archives(self):
        forbidden = (
            "Payload/Runner.app/Resources/licenses/lazer-ffmpeg/ffmpeg-source.tar.gz",
            "assets/licenses/lazer-ffmpeg/arm64-v8a/COPYING.LGPLv2.1",
            "ffmpeg/COPYING.LGPLv2.1",
            "ffmpeg/BUILDINFO.txt",
            "ffmpeg/PROFILE.txt",
            "ffmpeg-source.tar.gz",
        )
        with tempfile.TemporaryDirectory() as directory:
            for suffix in (".ipa", ".apk", ".zip", ".tar.gz"):
                path = Path(directory) / ("Lazer" + suffix)
                for name in forbidden:
                    with self.subTest(suffix=suffix, name=name):
                        if suffix == ".tar.gz":
                            with tarfile.open(path, "w:gz") as archive:
                                info = tarfile.TarInfo(name)
                                info.size = 1
                                archive.addfile(info, io.BytesIO(b"x"))
                        else:
                            with ZipFile(path, "w") as archive:
                                archive.writestr(name, b"x")
                        with self.assertRaisesRegex(ValueError, "excluded FFmpeg materials"):
                            VERIFY.verify_package(path)

    def test_rejects_materials_in_staged_appimage_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "usr/bin/lib/licenses/lazer-ffmpeg/ffmpeg-source.tar.gz"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"source archive")
            with self.assertRaisesRegex(ValueError, "excluded FFmpeg materials"):
                VERIFY.verify_package(root)

    def test_checks_archives_inside_release_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with ZipFile(root / "Lazer-Windows-x86_64.zip", "w") as archive:
                archive.writestr("licenses/lazer-ffmpeg/BUILDINFO.txt", b"build")
            with self.assertRaisesRegex(ValueError, "excluded FFmpeg materials"):
                VERIFY.verify_package(root)

    def test_accepts_required_ffmpeg_runtime_and_relink_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Lazer.zip"
            with ZipFile(path, "w") as archive:
                for name in ("avcodec-62.dll", "libavcodec.so", "libavcodec.dylib", "ffmpeg/lib/libavcodec.a"):
                    archive.writestr(name, b"library")
            with contextlib.redirect_stdout(io.StringIO()):
                VERIFY.verify_package(path)

    def test_android_relink_package_excludes_sdk_source_and_notices(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / "build"
            objects = build / "lazer-audio/CMakeFiles/lazer-audio.dir"
            objects.mkdir(parents=True)
            (objects / "engine.cpp.o").write_bytes(b"engine object")
            sdk = root / "ffmpeg"
            (sdk / "lib").mkdir(parents=True)
            for component in ("avformat", "avcodec", "swresample", "avutil"):
                (sdk / "lib" / f"lib{component}.a").write_bytes(b"static library")
            notices = sdk / "share/lazer-ffmpeg"
            notices.mkdir(parents=True)
            for name in ("COPYING.LGPLv2.1", "BUILDINFO.txt", "PROFILE.txt", "ffmpeg-source.tar.gz"):
                (notices / name).write_bytes(b"excluded material")
            output = root / "Lazer-Android-Audio-Relink-arm64-v8a.tar.gz"
            subprocess.run(
                [sys.executable, str(REPO / "ci/package-android-audio.py"),
                 "--build", str(build), "--ffmpeg", str(sdk),
                 "--abi", "arm64-v8a", "--output", str(output)],
                check=True, capture_output=True, text=True,
            )
            with contextlib.redirect_stdout(io.StringIO()):
                VERIFY.verify_package(output)
            with tarfile.open(output) as archive:
                names = archive.getnames()
                self.assertIn("objects/engine.cpp.o", names)
                self.assertIn("ffmpeg/lib/libavcodec.a", names)
                manifest = json.load(archive.extractfile("SHA256.json"))
                for name, digest in manifest.items():
                    self.assertEqual(hashlib.sha256(archive.extractfile(name).read()).hexdigest(), digest)


if __name__ == "__main__":
    unittest.main()
