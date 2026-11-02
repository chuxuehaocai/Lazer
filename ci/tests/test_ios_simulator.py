"""Device-free fixtures for simulator choice, hangs and integration retries."""

import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "ios_simulator", REPO / "ci/ios-simulator.py"
)
SIMULATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SIMULATOR
SPEC.loader.exec_module(SIMULATOR)


def runtime(version, available=True, platform="iOS"):
    return {
        "identifier": f"com.apple.CoreSimulator.SimRuntime.{platform}-{version.replace('.', '-')}",
        "version": version,
        "isAvailable": available,
    }


def device(udid, name="iPhone 16", state="Shutdown", available=True):
    return {
        "udid": udid, "name": name, "state": state, "isAvailable": available,
    }


class SimulatorSelectionTest(unittest.TestCase):
    def choose(self, runtimes, devices):
        return SIMULATOR.select_device(
            {"runtimes": runtimes}, {"devices": devices}
        )

    def test_numeric_runtime_order_18_10_is_newer_than_18_9(self):
        old, new = runtime("18.9"), runtime("18.10")
        result = self.choose([old, new], {
            old["identifier"]: [device("old")],
            new["identifier"]: [device("new")],
        })
        self.assertEqual(result["udid"], "new")

    def test_unavailable_runtime_and_non_ios_runtime_are_ignored(self):
        ios, missing, tv = runtime("18.5"), runtime("26.0", False), runtime("27.0", platform="tvOS")
        result = self.choose([ios, missing, tv], {
            ios["identifier"]: [device("available")],
            missing["identifier"]: [device("missing")],
            tv["identifier"]: [device("tv")],
        })
        self.assertEqual(result["udid"], "available")

    def test_reuses_booted_iphone_even_when_shutdown_iphone_is_first(self):
        ios = runtime("18.5")
        result = self.choose([ios], {
            ios["identifier"]: [device("shutdown"), device("booted", state="Booted")],
        })
        self.assertEqual(result["udid"], "booted")

    def test_booted_only_device_is_supported(self):
        ios = runtime("18.5")
        result = self.choose([ios], {
            ios["identifier"]: [device("booted", state="Booted")],
        })
        self.assertEqual(result["udid"], "booted")

    def test_falls_back_when_newest_runtime_has_no_usable_iphone(self):
        old, new = runtime("18.5"), runtime("26.0")
        result = self.choose([old, new], {
            old["identifier"]: [device("fallback")],
            new["identifier"]: [
                device("ipad", name="iPad Pro"),
                device("missing", available=False),
                device("booting", state="Booting"),
            ],
        })
        self.assertEqual(result["udid"], "fallback")

    def test_empty_candidates_are_a_failure_not_an_empty_udid(self):
        with self.assertRaisesRegex(ValueError, "No available iPhone"):
            self.choose([runtime("18.5")], {})

    def test_already_booted_device_does_not_issue_boot(self):
        with patch.object(SIMULATOR, "checked") as checked:
            SIMULATOR.boot_device("booted", "Booted", "fixture")
        self.assertEqual(checked.call_count, 1)
        self.assertEqual(
            checked.call_args.args[0],
            ["xcrun", "simctl", "bootstatus", "booted", "-b"],
        )


class CommandDeadlineTest(unittest.TestCase):
    def execute(self, source, **kwargs):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "command.log"
            with contextlib.redirect_stdout(io.StringIO()):
                result = SIMULATOR.run(
                    [sys.executable, "-u", "-c", source], log,
                    echo=False, **kwargs,
                )
            return result, log.read_text()

    def test_preserves_real_failure_and_its_log(self):
        result, log = self.execute("print('assertion failed'); raise SystemExit(7)", timeout=3)
        self.assertEqual(result.returncode, 7)
        self.assertFalse(result.timed_out)
        self.assertIn("assertion failed", log)

    def test_hung_command_is_terminated_before_global_job_timeout(self):
        started = time.monotonic()
        result, _ = self.execute("import time; time.sleep(30)", timeout=0.2)
        self.assertEqual(result.returncode, 124)
        self.assertTrue(result.timed_out)
        self.assertLess(time.monotonic() - started, 3)

    def test_cold_build_can_be_quiet_before_install_phase(self):
        result, log = self.execute(
            "import time; time.sleep(1); print('Xcode build done.'); print('test passed')",
            timeout=5, idle_timeout=0.5, idle_after=("Xcode build done.",),
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("test passed", log)

    def test_install_phase_inactivity_has_its_own_deadline(self):
        result, _ = self.execute(
            "import time; print('Xcode build done.'); time.sleep(30)",
            timeout=5, idle_timeout=0.2, idle_after=("Xcode build done.",),
        )
        self.assertEqual(result.returncode, 124)
        self.assertTrue(result.timed_out)

    @unittest.skipIf(sys.platform == "win32", "process sessions are a macOS/Linux facility")
    def test_timeout_kills_children_including_ones_ignoring_sigterm(self):
        with tempfile.TemporaryDirectory() as directory:
            child_pid = Path(directory) / "child.pid"
            source = (
                "import subprocess,sys,time; "
                "child=subprocess.Popen([sys.executable,'-c',"
                "'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)']); "
                f"open({str(child_pid)!r},'w').write(str(child.pid)); "
                "time.sleep(30)"
            )
            with contextlib.redirect_stdout(io.StringIO()):
                result = SIMULATOR.run(
                    [sys.executable, "-u", "-c", source],
                    Path(directory) / "parent.log", timeout=0.5, echo=False,
                )
            self.assertTrue(result.timed_out)
            pid = int(child_pid.read_text())
            probe = subprocess.run(
                ["ps", "-o", "stat=", "-p", str(pid)], text=True, capture_output=True,
            )
            self.assertTrue(
                probe.returncode != 0 or probe.stdout.strip().startswith("Z"),
                f"child {pid} is still running: {probe.stdout}",
            )


class IntegrationRecoveryTest(unittest.TestCase):
    def test_ordinary_test_failure_is_never_retried(self):
        with patch.object(SIMULATOR, "run", return_value=SIMULATOR.CommandResult(1)) as run, \
                patch.object(SIMULATOR, "collect_diagnostics") as diagnostics, \
                patch.object(SIMULATOR, "boot_device") as boot:
            result = SIMULATOR.test("fixture")
        self.assertEqual(result, 1)
        self.assertEqual(run.call_count, 1)
        diagnostics.assert_called_once()
        boot.assert_not_called()
        self.assertIn("integration_test/ios_native_engine_test.dart", run.call_args.args[0])

    def test_stalled_launch_reboots_and_retries_the_same_real_test_once(self):
        with patch.object(SIMULATOR, "run", side_effect=[
            SIMULATOR.CommandResult(124, True), SIMULATOR.CommandResult(0),
        ]) as run, patch.object(SIMULATOR, "collect_diagnostics"), \
                patch.object(SIMULATOR, "checked") as checked, \
                patch.object(SIMULATOR, "boot_device") as boot, \
                contextlib.redirect_stdout(io.StringIO()):
            result = SIMULATOR.test("fixture")
        self.assertEqual(result, 0)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0].args[0], run.call_args_list[1].args[0])
        checked.assert_called_once_with(
            ["xcrun", "simctl", "shutdown", "fixture"], "recovery-shutdown", 30
        )
        boot.assert_called_once_with("fixture", "Shutdown", "recovery")

    def test_second_stall_fails_and_leaves_both_diagnostics(self):
        with patch.object(SIMULATOR, "run", return_value=SIMULATOR.CommandResult(124, True)) as run, \
                patch.object(SIMULATOR, "collect_diagnostics") as diagnostics, \
                patch.object(SIMULATOR, "checked"), patch.object(SIMULATOR, "boot_device"), \
                contextlib.redirect_stdout(io.StringIO()):
            result = SIMULATOR.test("fixture")
        self.assertEqual(result, 124)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(diagnostics.call_count, 2)


if __name__ == "__main__":
    unittest.main()
