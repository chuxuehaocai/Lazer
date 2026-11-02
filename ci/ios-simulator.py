#!/usr/bin/env python3
"""Select an iOS simulator and run the real engine test with bounded recovery."""

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time


REPO = Path(__file__).resolve().parents[1]
DIAGNOSTICS = REPO / "build/ios-simulator-diagnostics"


def version_tuple(value):
    parts = tuple(int(part) for part in re.findall(r"\d+", value))
    return (parts + (0, 0, 0))[:3]


def select_device(runtimes, devices):
    """Use an available iPhone on the newest runtime; reuse an already booted one."""
    available = [
        runtime for runtime in runtimes.get("runtimes", [])
        if runtime.get("isAvailable") is True
        and runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
    ]
    for runtime in sorted(
        available,
        key=lambda item: version_tuple(item.get("version", "")),
        reverse=True,
    ):
        candidates = [
            device for device in devices.get("devices", {}).get(runtime["identifier"], [])
            if device.get("isAvailable") is True
            and device.get("name", "").startswith("iPhone")
            and device.get("state") in ("Booted", "Shutdown")
            and device.get("udid")
        ]
        if candidates:
            chosen = min(
                candidates,
                key=lambda device: (
                    device["state"] != "Booted", device["name"], device["udid"]
                ),
            )
            return {**chosen, "runtime": runtime["identifier"]}
    raise ValueError("No available iPhone on an available iOS runtime")


@dataclass
class CommandResult:
    returncode: int
    timed_out: bool = False


def stop_process(process):
    if os.name == "nt":
        if process.poll() is None:
            process.terminate()
    else:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            process.kill()
        else:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
    # A parent can exit on SIGTERM while a child ignores it and keeps the pipe
    # open. Kill the entire session even after the parent has returned.
    if os.name != "nt":
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def run(command, log, timeout, idle_timeout=None, echo=True, idle_after=None):
    """Stream logs without allowing a blocked simctl child to outlive its runner."""
    log = Path(log)
    log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    last_output = [started]
    watch_idle = [idle_after is None]
    print(f"Running ({timeout}s limit): {' '.join(command)}", flush=True)
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(
            command,
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            start_new_session=os.name != "nt",
        )

        def copy_output():
            for line in process.stdout:
                last_output[0] = time.monotonic()
                if idle_after and any(marker in line for marker in idle_after):
                    watch_idle[0] = True
                output.write(line)
                output.flush()
                if echo:
                    print(line, end="", flush=True)

        reader = threading.Thread(target=copy_output, daemon=True)
        reader.start()
        timed_out = False
        while process.poll() is None:
            now = time.monotonic()
            if now - started > timeout or (
                watch_idle[0]
                and idle_timeout is not None
                and now - last_output[0] > idle_timeout
            ):
                timed_out = True
                reason = (
                    f"no output for {idle_timeout}s"
                    if watch_idle[0]
                    and idle_timeout is not None
                    and now - last_output[0] > idle_timeout
                    else f"exceeded {timeout}s"
                )
                print(f"::error::{command[0]} {reason}; terminating its process group", flush=True)
                stop_process(process)
                break
            time.sleep(0.1)
        reader.join(timeout=10)
        if reader.is_alive():
            # This is a stalled child process, even if its direct parent quit.
            timed_out = True
            stop_process(process)
            reader.join(timeout=5)
        process.stdout.close()
    return CommandResult(124 if timed_out else process.returncode, timed_out)


def checked(command, name, timeout, echo=True):
    log = DIAGNOSTICS / f"{name}.log"
    result = run(command, log, timeout, echo=echo)
    if result.returncode:
        raise RuntimeError(f"{name} failed ({result.returncode}); see {log}")
    return log.read_text(encoding="utf-8")


def collect_diagnostics(udid, suffix):
    commands = [
        ("processes", ["ps", "-axo", "pid,ppid,etime,command"]),
        ("devices", ["xcrun", "simctl", "list", "--json"]),
        ("xcode", ["xcodebuild", "-version"]),
    ]
    if udid:
        commands += [
            ("launch-services", ["xcrun", "simctl", "spawn", udid, "launchctl", "print", "system"]),
            ("simulator-log", [
                "xcrun", "simctl", "spawn", udid, "log", "show", "--last", "3m",
                "--style", "compact", "--predicate",
                'process == "Runner" OR process == "SpringBoard" OR process == "installd"',
            ]),
        ]
    for name, command in commands:
        try:
            run(command, DIAGNOSTICS / f"{suffix}-{name}.log", 15, echo=False)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"Diagnostic {name}: {error}", flush=True)


def boot_device(udid, state, suffix):
    if state != "Booted":
        checked(["xcrun", "simctl", "boot", udid], f"{suffix}-boot", 30)
    checked(
        ["xcrun", "simctl", "bootstatus", udid, "-b"],
        f"{suffix}-bootstatus",
        180,
    )


def prepare():
    runtimes = json.loads(checked(
        ["xcrun", "simctl", "list", "runtimes", "--json"], "runtimes", 30, echo=False
    ))
    devices = json.loads(checked(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        "devices", 30, echo=False,
    ))
    chosen = select_device(runtimes, devices)
    udid = chosen["udid"]
    print(f"Selected {chosen['name']} / {chosen['runtime']} ({chosen['state']})", flush=True)
    # Persist the choice before boot, so a boot failure also has targeted logs.
    (DIAGNOSTICS / "selected-device.json").write_text(
        json.dumps(chosen, indent=2) + "\n", encoding="utf-8"
    )
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"udid={udid}\n")
    boot_device(udid, chosen["state"], "initial")
    return 0


def test(udid):
    # The reported 1h failure built FFmpeg in 99s and Xcode in 251s, then sat
    # after "Xcode build done" with an orphan simctl. Keep the real integration
    # test, expose the install/launch logs, and recover that stalled simulator
    # once. Assertions and ordinary build failures must fail immediately.
    command = [
        "flutter", "test", "integration_test/ios_native_engine_test.dart",
        "--no-pub", "-d", udid, "--timeout=2m",
        "--reporter=expanded", "--verbose",
    ]
    for attempt in (1, 2):
        result = run(
            command, DIAGNOSTICS / f"integration-{attempt}.log",
            timeout=720, idle_timeout=180,
            # Flutter buffers Xcode output while compiling. A cold build
            # therefore has the full build budget before inactivity matters.
            idle_after=("Xcode build done.", "simctl install", "simctl launch"),
        )
        if result.returncode == 0:
            return 0
        collect_diagnostics(udid, f"attempt-{attempt}")
        if not result.timed_out or attempt == 2:
            return result.returncode
        print("Restarting the selected simulator after a stalled install/launch", flush=True)
        checked(["xcrun", "simctl", "shutdown", udid], "recovery-shutdown", 30)
        boot_device(udid, "Shutdown", "recovery")
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "test"))
    parser.add_argument("--udid")
    args = parser.parse_args()
    try:
        if args.operation == "prepare":
            return prepare()
        if not args.udid:
            parser.error("--udid is required for test")
        return test(args.udid)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"::error::{error}", file=sys.stderr, flush=True)
        selected = DIAGNOSTICS / "selected-device.json"
        udid = args.udid
        if not udid and selected.exists():
            udid = json.loads(selected.read_text(encoding="utf-8"))["udid"]
        collect_diagnostics(udid, "failure")
        return 1


if __name__ == "__main__":
    sys.exit(main())
