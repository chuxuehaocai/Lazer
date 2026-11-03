"""Check local iOS engine builds and CI archive reuse without an Apple SDK."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "prepare_ios_audio", REPO / "ci/prepare-ios-audio.py"
)
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


class IosAudioPreparationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lazer ios build ")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.calls = []
        for relative in (
            "native/CMakeLists.txt",
            "native/lazer-audio/src/api.cpp",
            "ci/build-ios-audio.sh",
            "ci/prepare-ios-audio.py",
            "ci/verify-ios-audio.py",
        ):
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n", encoding="utf-8")

    def stage(self, directory):
        directory.mkdir(parents=True, exist_ok=True)
        for archive in PREPARE.ARCHIVES:
            (directory / archive).write_bytes(b"static-archive")

    def run_command(self, command, **kwargs):
        self.calls.append(command)
        self.assertTrue(kwargs["check"])
        self.assertEqual(kwargs["cwd"], self.repo)
        if command[0] == "bash":
            self.stage(
                self.repo / "build/ios-audio" / command[-1] / "stage/lib"
            )

    def prepare(self, sdk="iphoneos", directory=None):
        PREPARE.prepare(
            self.repo, sdk, directory, environment={}, run=self.run_command
        )

    def test_clean_checkout_builds_before_verifying_and_caches(self):
        self.prepare()
        self.assertEqual(self.calls[0][-1], "device")
        self.assertIn("--archive", self.calls[1])
        self.calls.clear()
        self.prepare()
        self.assertEqual(len(self.calls), 1)
        self.assertIn("--archive", self.calls[0])

    def test_native_source_change_rebuilds_the_archives(self):
        self.prepare()
        self.calls.clear()
        (self.repo / "native/lazer-audio/src/api.cpp").write_text(
            "changed ABI\n", encoding="utf-8"
        )
        self.prepare()
        self.assertEqual(self.calls[0][0], "bash")

    def test_missing_cached_archive_rebuilds(self):
        self.prepare()
        self.calls.clear()
        archive = self.repo / "build/ios-audio/device/stage/lib/liblazer-audio.a"
        archive.unlink()
        self.prepare()
        self.assertEqual(self.calls[0][0], "bash")

    def test_new_xcode_sdk_rebuilds_cached_native_code(self):
        self.prepare()
        self.calls.clear()
        PREPARE.prepare(
            self.repo,
            "iphoneos",
            environment={"SDKROOT": "/Xcode/iPhoneOS28.sdk", "XCODE_VERSION_ACTUAL": "2800"},
            run=self.run_command,
        )
        self.assertEqual(self.calls[0][0], "bash")

    def test_simulator_has_separate_archives_and_stamp(self):
        self.prepare()
        self.calls.clear()
        self.prepare("iphonesimulator")
        self.assertEqual(self.calls[0][-1], "simulator")
        for platform in ("device", "simulator"):
            self.assertTrue(
                (self.repo / "build/ios-audio" / platform / "stage/inputs.sha256").is_file()
            )

    def test_ci_archives_are_verified_without_rebuilding(self):
        directory = self.repo / "build/native-deps-ios/lib"
        self.stage(directory)
        self.prepare(directory=directory)
        self.assertEqual(len(self.calls), 1)
        self.assertIn("--archive", self.calls[0])

    def test_incomplete_ci_archives_fail_without_building_somewhere_else(self):
        with self.assertRaisesRegex(RuntimeError, "Missing iOS Audio Engine"):
            self.prepare(directory=self.repo / "build/native-deps-ios/lib")
        self.assertEqual(self.calls, [])

    def test_failed_verification_does_not_cache_a_success(self):
        def failing_run(command, **kwargs):
            self.run_command(command, **kwargs)
            if command[0] != "bash":
                raise subprocess.CalledProcessError(1, command)

        with self.assertRaises(subprocess.CalledProcessError):
            PREPARE.prepare(self.repo, "iphoneos", environment={}, run=failing_run)
        self.assertFalse(
            (self.repo / "build/ios-audio/device/stage/inputs.sha256").exists()
        )

    def test_failed_native_build_propagates_instead_of_reusing_old_archives(self):
        self.prepare()
        self.calls.clear()
        (self.repo / "native/lazer-audio/src/api.cpp").write_text(
            "invalid source\n", encoding="utf-8"
        )

        def failing_build(command, **kwargs):
            self.calls.append(command)
            raise subprocess.CalledProcessError(1, command)

        with self.assertRaises(subprocess.CalledProcessError):
            PREPARE.prepare(self.repo, "iphoneos", environment={}, run=failing_build)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][0], "bash")


if __name__ == "__main__":
    unittest.main()
