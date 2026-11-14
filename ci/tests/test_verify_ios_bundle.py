"""Tests for iOS app and extension bundle metadata validation."""

import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from zipfile import ZipFile


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_ios_bundle", REPO / "ci/verify-ios-bundle.py"
)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


def bundle_info(
    *,
    identifier: str,
    package_type: str,
    executable: str | None,
    short_version: str = "2.0.200",
    build_version: str = "200",
) -> dict:
    info = {
        "CFBundleIdentifier": identifier,
        "CFBundlePackageType": package_type,
        "CFBundleShortVersionString": short_version,
        "CFBundleVersion": build_version,
    }
    if executable is not None:
        info["CFBundleExecutable"] = executable
    return info


class IosBundleMetadataTest(unittest.TestCase):
    def make_app(self, root: Path, *, extension_executable: str | None = "Widget"):
        app = root / "Runner.app"
        extension = app / "PlugIns/PlayCount.appex"
        extension.mkdir(parents=True)
        (app / "Runner").write_bytes(b"app")
        if extension_executable is not None:
            (extension / extension_executable).write_bytes(b"widget")
        (app / "Info.plist").write_bytes(
            plistlib.dumps(
                bundle_info(
                    identifier="dev.naominet.lazer",
                    package_type="APPL",
                    executable="Runner",
                )
            )
        )
        (extension / "Info.plist").write_bytes(
            plistlib.dumps(
                bundle_info(
                    identifier="dev.naominet.lazer.PlayCountWidget",
                    package_type="XPC!",
                    executable=extension_executable,
                )
            )
        )
        return app

    def test_valid_app_and_extension_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            VERIFY.verify_app(self.make_app(Path(directory)))

    def test_missing_extension_executable_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory), extension_executable=None)
            with self.assertRaisesRegex(ValueError, "CFBundleExecutable"):
                VERIFY.verify_app(app)

    def test_missing_extension_executable_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            (app / "PlugIns/PlayCount.appex/Widget").unlink()
            with self.assertRaisesRegex(ValueError, "no executable named Widget"):
                VERIFY.verify_app(app)

    def test_extension_version_must_match_the_app(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            info_path = app / "PlugIns/PlayCount.appex/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["CFBundleVersion"] = "1"
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "does not match"):
                VERIFY.verify_app(app)

    def test_ipa_checks_extension_metadata_after_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "Lazer-iOS-aarch64.ipa"
            extension = "Payload/Runner.app/PlugIns/PlayCount.appex/"
            with ZipFile(ipa, "w") as package:
                package.writestr(
                    "Payload/Runner.app/Info.plist",
                    plistlib.dumps(
                        bundle_info(
                            identifier="dev.naominet.lazer",
                            package_type="APPL",
                            executable="Runner",
                        )
                    ),
                )
                package.writestr("Payload/Runner.app/Runner", b"app")
                package.writestr(
                    extension + "Info.plist",
                    plistlib.dumps(
                        bundle_info(
                            identifier="dev.naominet.lazer.PlayCountWidget",
                            package_type="XPC!",
                            executable="Widget",
                        )
                    ),
                )
                package.writestr(extension + "Widget", b"widget")
            VERIFY.verify_ipa(ipa)

    def test_ipa_rejects_missing_extension_executable_key(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "Lazer-iOS-aarch64.ipa"
            extension = "Payload/Runner.app/PlugIns/PlayCount.appex/"
            with ZipFile(ipa, "w") as package:
                package.writestr(
                    "Payload/Runner.app/Info.plist",
                    plistlib.dumps(
                        bundle_info(
                            identifier="dev.naominet.lazer",
                            package_type="APPL",
                            executable="Runner",
                        )
                    ),
                )
                package.writestr("Payload/Runner.app/Runner", b"app")
                package.writestr(
                    extension + "Info.plist",
                    plistlib.dumps(
                        bundle_info(
                            identifier="dev.naominet.lazer.PlayCountWidget",
                            package_type="XPC!",
                            executable=None,
                        )
                    ),
                )
                package.writestr(extension + "Widget", b"widget")
            with self.assertRaisesRegex(ValueError, "CFBundleExecutable"):
                VERIFY.verify_ipa(ipa)


if __name__ == "__main__":
    unittest.main()
