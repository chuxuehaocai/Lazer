"""Exercise the Flutter integration runner's real subprocess/cleanup contract."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ios_flutter_audio_runner", REPO / "ci/run-ios-flutter-audio.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)

DEFAULT_FLUTTER_OUTPUT = """\
Flutter fixture output
00:00 +0: loading integration_test/ios_native_engine_test.dart
00:00 +0: iOS selects the linked native engine
00:00 +1: iOS factory plays through the native engine and worker
00:01 +2: iOS decodes high resolution PCM and DSD through RemoteIO
00:02 +3: iOS HiFi controller applies audible-path DSP
00:03 +4: iOS plays HTTP audio through the native growing reader
00:04 +5: iOS strict USB PCM refuses a non-USB route without fallback
00:05 +6: iOS required DoP refuses a non-USB route without PCM fallback
00:06 +7: All tests passed!
"""

FAKE_TOOL = r'''
import json, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
tool = sys.argv[2]
args = sys.argv[3:]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps([tool, *args]) + '\n')
config = json.loads((root / 'config.json').read_text())
if tool == 'flutter':
    time.sleep(config.get('delay', 0))
    print(config['flutter_output'], flush=True)
    sys.exit(config.get('result', 0))
if args[0] == 'list':
    print(json.dumps({'devicetypes': [], 'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [{'name': 'iPhone Test', 'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-Test', 'isAvailable': True}]}}))
elif args[0] == 'create':
    print('849CC263-E7E6-4976-9E68-86550BD95858')
elif args[0] == 'spawn':
    print('Runner diagnostics')
'''


class IosFlutterAudioRunnerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.out = self.repo / "build/ios-flutter-audio"
        self.fake = self.repo / "fake_tool.py"
        self.fake.write_text(FAKE_TOOL, encoding="utf-8")

    def session(self, **config):
        config.setdefault("flutter_output", DEFAULT_FLUTTER_OUTPUT)
        (self.repo / "config.json").write_text(json.dumps(config), encoding="utf-8")
        return RUNNER.FlutterAudioSession(
            self.repo, self.out,
            simctl=(sys.executable, str(self.fake), str(self.repo), "simctl"),
            flutter=(sys.executable, str(self.fake), str(self.repo), "flutter"),
            timeouts={"flutter": 0.5},
        )

    def run_session(self, session):
        with contextlib.redirect_stdout(io.StringIO()):
            session.run()

    def calls(self):
        return [json.loads(line) for line in (self.repo / "calls.jsonl").read_text().splitlines()]

    def test_runs_real_integration_target_after_boot_and_keeps_result(self):
        self.run_session(self.session())
        calls = self.calls()
        flutter = next(call for call in calls if call[0] == "flutter")
        self.assertEqual(flutter, [
            "flutter", "test", "--no-pub", "--reporter", "expanded",
            "integration_test/ios_native_engine_test.dart", "-d",
            "849CC263-E7E6-4976-9E68-86550BD95858",
        ])
        self.assertEqual([call[1] for call in calls[:4]], ["list", "create", "boot", "bootstatus"])
        self.assertEqual([call[1] for call in calls[-3:]], ["terminate", "shutdown", "delete"])
        self.assertIn("PASS Flutter", (self.out / "result.txt").read_text())
        self.assertIn("Flutter fixture output", (self.out / "flutter.log").read_text())

    def test_zero_exit_with_skipped_test_cannot_create_a_pass(self):
        output = DEFAULT_FLUTTER_OUTPUT.replace(
            "00:06 +7: All tests passed!",
            "00:06 +6 ~1: All tests passed!",
        )
        with self.assertRaisesRegex(
            RUNNER.SMOKE.SmokeFailure,
            "expected 7 passed and 0 skipped; got 6 passed, 1 skipped",
        ):
            self.run_session(self.session(flutter_output=output))
        self.assertFalse((self.out / "result.txt").exists())

    def test_zero_exit_with_a_missing_expected_test_cannot_create_a_pass(self):
        output = DEFAULT_FLUTTER_OUTPUT.replace(
            "iOS required DoP refuses a non-USB route without PCM fallback",
            "an unrelated test",
        )
        with self.assertRaisesRegex(
            RUNNER.SMOKE.SmokeFailure,
            "expected integration tests did not run: iOS required DoP",
        ):
            self.run_session(self.session(flutter_output=output))
        self.assertFalse((self.out / "result.txt").exists())

    def test_test_failure_keeps_flutter_output_and_runner_diagnostics_then_cleans_up(self):
        self.out.mkdir(parents=True)
        (self.out / "result.txt").write_text("PASS from a prior run\n", encoding="utf-8")
        with self.assertRaisesRegex(RUNNER.SMOKE.SmokeFailure, "exited 7"):
            self.run_session(self.session(result=7))
        self.assertFalse((self.out / "result.txt").exists())
        self.assertIn("Flutter fixture output", (self.out / "flutter.log").read_text())
        self.assertIn("Runner diagnostics", (self.out / "diagnostics.log").read_text())
        diagnostic = next(call for call in self.calls() if call[1] == "spawn")
        self.assertIn('process == "Runner"', diagnostic[-1])
        self.assertEqual(self.calls()[-1], ["simctl", "delete", "849CC263-E7E6-4976-9E68-86550BD95858"])

    def test_hung_flutter_is_bounded_and_does_not_leave_a_pass(self):
        with self.assertRaisesRegex(RUNNER.SMOKE.SmokeFailure, "flutter: timed out"):
            self.run_session(self.session(delay=10))
        self.assertFalse((self.out / "result.txt").exists())
        self.assertEqual(self.calls()[-1][1], "delete")


if __name__ == "__main__":
    unittest.main()
