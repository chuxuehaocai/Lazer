"""Validate the actual plist generated for the Simulator UIKit fixture."""

import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class IosAudioSmokeBundleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        git_bash = Path("C:/Program Files/Git/bin/bash.exe")
        bash = str(git_bash) if os.name == "nt" and git_bash.is_file() else shutil.which("bash")
        if not bash:
            raise unittest.SkipTest("bash is needed to execute the fixture plist generation")
        source = (REPO / "ci/smoke-ios-audio.sh").read_text(encoding="utf-8")
        block = re.search(r"^cat > .*? <<'PLIST'\n.*?^PLIST$", source, re.MULTILINE | re.DOTALL)
        if block is None:
            raise AssertionError("No fixture plist generation block found")
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Audio Smoke.app"
            app.mkdir()
            # Run the production heredoc itself, without an Xcode dependency or
            # a second hand-maintained fixture that could drift from the app.
            subprocess.run(
                [bash, "-c", block.group()], check=True, capture_output=True,
                env={**os.environ, "app": app.as_posix()}, timeout=10,
            )
            with (app / "Info.plist").open("rb") as generated:
                cls.info = plistlib.load(generated)

    def test_uikit_bundle_identity_and_platform_metadata_are_valid(self):
        self.assertEqual(self.info["CFBundleExecutable"], "AudioSmoke")
        self.assertEqual(self.info["CFBundleIdentifier"], "dev.naominet.lazer.audiosmoke")
        self.assertEqual(self.info["CFBundlePackageType"], "APPL")
        self.assertEqual(self.info["CFBundleInfoDictionaryVersion"], "6.0")
        self.assertRegex(self.info["CFBundleVersion"], r"^[1-9][0-9]*(\.[0-9]+){0,2}$")
        self.assertRegex(self.info["CFBundleShortVersionString"], r"^[0-9]+(\.[0-9]+){1,2}$")
        self.assertEqual(self.info["MinimumOSVersion"], "15.0")
        self.assertIs(self.info["LSRequiresIPhoneOS"], True)
        self.assertEqual(self.info["UIDeviceFamily"], [1, 2])

    def test_both_device_families_have_explicit_valid_launch_orientations(self):
        valid = {
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
        }
        # SplashBoard cannot construct launch requests for an empty orientation
        # mask, even if UIKit would later supply defaults after main() starts.
        for suffix in ("", "~iphone", "~ipad"):
            with self.subTest(device=suffix or "default"):
                values = self.info.get("UISupportedInterfaceOrientations" + suffix, self.info["UISupportedInterfaceOrientations"])
                self.assertIsInstance(values, list)
                self.assertTrue(values)
                self.assertTrue(set(values) <= valid)
                self.assertIn("UIInterfaceOrientationPortrait", values)

    def test_launch_screen_and_background_audio_contract_are_preserved(self):
        self.assertIsInstance(self.info["UILaunchScreen"], dict)
        self.assertIn("audio", self.info["UIBackgroundModes"])


if __name__ == "__main__":
    unittest.main()
