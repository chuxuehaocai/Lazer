"""Execute the SDK-specific archive override generator without Xcode."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class IosAudioXcconfigTest(unittest.TestCase):
    def setUp(self):
        git_bash = Path("C:/Program Files/Git/bin/bash.exe")
        self.bash = str(git_bash) if os.name == "nt" and git_bash.is_file() else shutil.which("bash")
        if not self.bash:
            self.skipTest("bash is needed to execute the xcconfig generator")
        self.temporary = tempfile.TemporaryDirectory(prefix="lazer ios xcconfig ")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        (self.repo / "ci").mkdir()
        (self.repo / "ios/Flutter").mkdir(parents=True)
        self.script = self.repo / "ci/ios-audio-xcconfig.sh"
        shutil.copyfile(REPO / "ci/ios-audio-xcconfig.sh", self.script)
        self.lib = self.repo / "custom archives & output" / "lib"
        self.lib.mkdir(parents=True)
        for name in ("lazer-audio", "lazer-audio-bridge", "avformat", "avcodec", "avutil", "swresample"):
            (self.lib / f"lib{name}.a").write_bytes(b"archive")

    def test_overrides_only_the_requested_sdk_and_preserves_paths(self):
        for platform, sdk in (("device", "iphoneos"), ("simulator", "iphonesimulator")):
            with self.subTest(platform=platform):
                subprocess.run([self.bash, self.script.as_posix(), self.lib.as_posix(), platform],
                               capture_output=True, text=True, check=True, timeout=10)
                generated = (self.repo / "ios/Flutter/LazerAudio.xcconfig").read_text()
                settings = [line for line in generated.splitlines() if line.startswith("LAZER_AUDIO_LIB_DIR")]
                self.assertEqual(len(settings), 1)
                self.assertTrue(settings[0].startswith(f"LAZER_AUDIO_LIB_DIR[sdk={sdk}*] = "))
                self.assertTrue(settings[0].endswith("/custom archives & output/lib"))

    def test_invalid_sdk_does_not_write_an_override(self):
        result = subprocess.run([self.bash, self.script.as_posix(), self.lib.as_posix(), "macos"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.repo / "ios/Flutter/LazerAudio.xcconfig").exists())


if __name__ == "__main__":
    unittest.main()
