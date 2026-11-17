#!/usr/bin/env python3
"""Run the fixture app with bounded Simulator startup and actionable logs."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid


class SmokeFailure(RuntimeError):
    pass


class SmokeSession:
    def __init__(
        self,
        app: Path,
        out: Path,
        bundle: str,
        *,
        simctl: tuple[str, ...] = ("xcrun", "simctl"),
        timeouts: dict[str, float] | None = None,
        playback_timeout: float = 90,
        poll_interval: float = 1,
    ):
        self.app, self.out, self.bundle = app, out, bundle
        self.simctl = simctl
        self.timeouts = {
            "list": 30, "create": 30, "boot": 60, "bootstatus": 300,
            "install": 120, "container": 30, "launch": 120,
            "diagnostics": 20, "terminate": 10, "shutdown": 10, "delete": 10,
            **(timeouts or {}),
        }
        self.playback_timeout, self.poll_interval = playback_timeout, poll_interval
        self.device: str | None = None
        self.container: Path | None = None
        self.out.mkdir(parents=True, exist_ok=True)

    def note(self, message: str) -> None:
        line = f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {message}"
        print(line, flush=True)
        with (self.out / "harness.log").open("a", encoding="utf-8") as log:
            log.write(line + "\n")

    def command(self, stage: str, *args: str) -> str:
        self.note(f"{stage}: begin")
        process = subprocess.Popen(
            [*self.simctl, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace",
            start_new_session=os.name != "nt",
        )
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=self.timeouts[stage])
        except subprocess.TimeoutExpired:
            timed_out = True
            # Kill only this command's process group, never the runner's shared
            # Simulator services or other pre-existing devices.
            if os.name == "nt":
                process.kill()
            else:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            stdout, stderr = process.communicate(timeout=2)
        (self.out / f"{stage}.log").write_text(stdout + stderr, encoding="utf-8")
        if stdout.strip() and stage not in ("list", "container"):
            print(stdout[-16000:], end="" if stdout.endswith("\n") else "\n", flush=True)
        if stderr.strip():
            print(stderr[-16000:], end="" if stderr.endswith("\n") else "\n", flush=True)
        if timed_out:
            raise SmokeFailure(f"{stage}: timed out after {self.timeouts[stage]}s")
        if process.returncode:
            raise SmokeFailure(f"{stage}: simctl exited {process.returncode}")
        self.note(f"{stage}: complete")
        return stdout.strip()

    @staticmethod
    def select_device(catalog: dict) -> tuple[str, str]:
        types = {item["name"]: item["identifier"] for item in catalog["devicetypes"]}
        for runtime, entries in reversed(list(catalog["devices"].items())):
            if ".iOS-" not in runtime:
                continue
            for entry in entries:
                kind = entry.get("deviceTypeIdentifier") or types.get(entry["name"], "")
                if ".iPhone-" in kind and entry.get("isAvailable", False):
                    return kind, runtime
        raise SmokeFailure("No available iPhone Simulator runtime found")

    def copy_console(self) -> str:
        if self.container is None:
            return ""
        source = self.container / "Documents" / "smoke-console.log"
        try:
            if not source.is_file():
                return ""
            content = source.read_text(encoding="utf-8", errors="replace")
            (self.out / "console.log").write_text(content, encoding="utf-8")
            return content
        except OSError as error:
            self.note(f"console unavailable: {error}")
            return ""

    def playback(self) -> None:
        catalog_text = self.command("list", "list", "--json")
        (self.out / "devices.json").write_text(catalog_text, encoding="utf-8")
        kind, runtime = self.select_device(json.loads(catalog_text))
        created = self.command("create", "create", "Lazer Native Audio Smoke", kind, runtime)
        # Do not run cleanup against aliases such as "all" or "booted" if an
        # unexpected tool response is received.
        try:
            uuid.UUID(created)
        except ValueError as error:
            raise SmokeFailure("create: simctl did not return one device UUID") from error
        self.device = created
        self.command("boot", "boot", self.device)
        self.command("bootstatus", "bootstatus", self.device, "-b")
        self.command("install", "install", self.device, str(self.app))
        self.container = Path(self.command("container", "get_app_container", self.device, self.bundle, "data"))
        if not self.container.is_absolute():
            raise SmokeFailure("container: simctl did not return an absolute path")
        # Unlike --console, launch returns after the app has actually launched.
        # The fixture writes unbuffered diagnostics directly into its container.
        launched = self.command("launch", "launch", self.device, self.bundle)
        if not re.search(rf"^{re.escape(self.bundle)}:\s+[1-9][0-9]*\s*$", launched, re.MULTILINE):
            raise SmokeFailure("launch: simctl returned no application PID")
        self.note("playback: launched; waiting for fixture result")
        deadline = time.monotonic() + self.playback_timeout
        result = self.container / "Documents" / "smoke-result.txt"
        while time.monotonic() < deadline:
            if result.is_file():
                content = result.read_text(encoding="utf-8")
                (self.out / "result.txt").write_text(content, encoding="utf-8")
                print(self.copy_console(), end="", flush=True)
                if not content.startswith("PASS "):
                    raise SmokeFailure(f"playback: {content.strip()}")
                self.note(content.strip())
                return
            time.sleep(self.poll_interval)
        console = self.copy_console()
        last_stage = next((line for line in reversed(console.splitlines()) if line.startswith("stage=")), "no app stage recorded")
        raise SmokeFailure(f"playback: no result after {self.playback_timeout}s; {last_stage}")

    def run(self) -> None:
        failure: Exception | None = None
        try:
            self.playback()
        except Exception as error:
            failure = error
            self.note(f"FAILED {error}")
            self.copy_console()
            if self.device:
                try:
                    # This fixture has no user data; restrict diagnostic logs to
                    # its own process/bundle rather than collecting all logs.
                    self.command("diagnostics", "spawn", self.device, "log", "show", "--last", "3m", "--style", "compact", "--predicate", f'process == "AudioSmoke" OR eventMessage CONTAINS "{self.bundle}"')
                except Exception as diagnostic_error:
                    self.note(f"diagnostics unavailable: {diagnostic_error}")
        finally:
            if self.device:
                for stage, args in (
                    ("terminate", ("terminate", self.device, self.bundle)),
                    ("shutdown", ("shutdown", self.device)),
                    ("delete", ("delete", self.device)),
                ):
                    try:
                        if stage == "shutdown":
                            self.copy_console()
                        self.command(stage, *args)
                    except Exception as cleanup_error:
                        # The runner is disposable. Cleanup failures must not
                        # replace the actual launch/playback result.
                        self.note(f"WARNING cleanup failed: {cleanup_error}")
        if failure is not None:
            raise failure


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--bundle", required=True)
    args = parser.parse_args()
    try:
        SmokeSession(args.app, args.out, args.bundle).run()
    except Exception as error:
        print(f"::error::iOS native smoke {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
