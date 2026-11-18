import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ios_audio_smoke_runner", REPO / "ci/run-ios-audio-smoke.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)

FAKE_SIMCTL = r'''
import json, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
args = sys.argv[2:]
config = json.loads((root / 'config.json').read_text())
command = args[0]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
device = '849CC263-E7E6-4976-9E68-86550BD95858'
container = root / 'data'
documents = container / 'Documents'
documents.mkdir(parents=True, exist_ok=True)
if command == 'list':
    print(json.dumps({'devicetypes': [{'name': 'iPhone Test', 'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-Test'}], 'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [{'name': 'iPhone Test', 'isAvailable': True}]}}))
elif command == 'create':
    print(config.get('device', device))
elif command == 'get_app_container':
    print(container)
elif command == 'launch':
    time.sleep(config.get('launch_delay', 0))
    if config.get('launch_error'):
        print('fixture launch denied', file=sys.stderr)
        sys.exit(7)
    (documents / 'smoke-console.log').write_text('stage=main\nstage=application active\nstage=file open\n')
    if not config.get('no_result'):
        (documents / 'smoke-result.txt').write_text(config.get('result', 'PASS file=309ms reader=309ms ABI=29\n'))
    print(args[-1] + ': 12345')
elif command in ('terminate', 'shutdown', 'delete'):
    if config.get('cleanup_hang'):
        time.sleep(10)
    if config.get('cleanup_error'):
        print('fixture cleanup failure', file=sys.stderr)
        sys.exit(8)
elif command == 'spawn':
    print('fixture diagnostic log')
'''


class IosAudioSmokeRunnerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fake = self.root / "fake_simctl.py"
        self.fake.write_text(FAKE_SIMCTL, encoding="utf-8")
        self.out = self.root / "diagnostics"

    def session(self, **config):
        (self.root / "config.json").write_text(json.dumps(config), encoding="utf-8")
        return RUNNER.SmokeSession(
            self.root / "AudioSmoke.app", self.out, "dev.naominet.lazer.audiosmoke",
            simctl=(sys.executable, str(self.fake), str(self.root)),
            # Normal cleanup must allow Python startup on a busy runner. The
            # dedicated hang case below supplies deliberately short deadlines.
            timeouts={"launch": 1, "terminate": 1, "shutdown": 1, "delete": 1},
            playback_timeout=0.12, poll_interval=0.01,
        )

    def run_session(self, session):
        with contextlib.redirect_stdout(io.StringIO()):
            session.run()

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def test_waits_for_launch_before_playback_deadline_and_keeps_proof(self):
        # Launch takes longer than the complete playback deadline. The result
        # still passes because launch is awaited, rather than detached.
        self.run_session(self.session(launch_delay=0.25))
        self.assertIn("PASS file=309ms reader=309ms", (self.out / "result.txt").read_text())
        self.assertIn("stage=main", (self.out / "console.log").read_text())
        calls = self.calls()
        self.assertEqual(calls[-3:], [
            ["terminate", "849CC263-E7E6-4976-9E68-86550BD95858", "dev.naominet.lazer.audiosmoke"],
            ["shutdown", "849CC263-E7E6-4976-9E68-86550BD95858"],
            ["delete", "849CC263-E7E6-4976-9E68-86550BD95858"],
        ])

    def test_launch_failure_is_immediate_and_retains_stderr(self):
        session = self.session(launch_error=True)
        with self.assertRaisesRegex(RUNNER.SmokeFailure, "launch: simctl exited 7"):
            self.run_session(session)
        self.assertIn("fixture launch denied", (self.out / "launch.log").read_text())
        self.assertFalse((self.out / "result.txt").exists())
        self.assertIn("fixture diagnostic log", (self.out / "diagnostics.log").read_text())

    def test_playback_failure_keeps_native_error(self):
        session = self.session(result="FAIL play status=-6: AudioOutputUnitStart OSStatus=-50\n")
        with self.assertRaisesRegex(RUNNER.SmokeFailure, "AudioOutputUnitStart OSStatus=-50"):
            self.run_session(session)
        self.assertTrue((self.out / "result.txt").read_text().startswith("FAIL "))

    def test_no_result_reports_last_native_stage(self):
        with self.assertRaisesRegex(RUNNER.SmokeFailure, "stage=file open"):
            self.run_session(self.session(no_result=True))

    def test_launch_and_cleanup_hangs_are_bounded_without_losing_launch_error(self):
        session = self.session(launch_delay=10, cleanup_hang=True)
        session.timeouts.update({stage: 0.15 for stage in ("launch", "terminate", "shutdown", "delete")})
        started = time.monotonic()
        with self.assertRaisesRegex(RUNNER.SmokeFailure, "launch: timed out"):
            self.run_session(session)
        self.assertLess(time.monotonic() - started, 4)
        harness = (self.out / "harness.log").read_text()
        self.assertIn("WARNING cleanup failed: shutdown: timed out", harness)
        self.assertIn("WARNING cleanup failed: delete: timed out", harness)

    def test_cleanup_failure_does_not_turn_playback_pass_into_failure(self):
        self.run_session(self.session(cleanup_error=True))
        self.assertIn("PASS ", (self.out / "result.txt").read_text())
        self.assertIn("WARNING cleanup failed", (self.out / "harness.log").read_text())

    def test_console_read_failure_does_not_replace_native_failure(self):
        session = self.session(result="FAIL original native error\n")
        original_read = Path.read_text

        def read(path, *args, **kwargs):
            if path.name == "smoke-console.log":
                raise PermissionError("fixture unreadable")
            return original_read(path, *args, **kwargs)

        with patch.object(Path, "read_text", read):
            with self.assertRaisesRegex(RUNNER.SmokeFailure, "original native error"):
                self.run_session(session)
        self.assertIn("console unavailable", (self.out / "harness.log").read_text())

    def test_rejects_shared_device_alias_without_any_cleanup(self):
        with self.assertRaisesRegex(RUNNER.SmokeFailure, "one device UUID"):
            self.run_session(self.session(device="all"))
        self.assertEqual([call[0] for call in self.calls()], ["list", "create"])


if __name__ == "__main__":
    unittest.main()
