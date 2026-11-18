"""Execute the re-signing workflow with per-target profiles and a fake signer.

The fake signer writes a real Mach-O LC_CODE_SIGNATURE / XML entitlement blob,
so the production signature reader, packaging and secret exclusion all run.
No test pretends to validate an Apple certificate or an on-device install.
"""

import importlib.util
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from zipfile import ZipFile


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "ci/resign-ios-ipa.py"
SPEC = importlib.util.spec_from_file_location("resign_ios_ipa", SCRIPT)
SIGNING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNING)
APP_ID = "dev.naominet.lazer"
WIDGET_ID = APP_ID + ".PlayCountWidget"
GROUP = "group.com.example.lazer"
SECRET = "fixture-p12-password-must-never-ship"

FAKE_SIGNER = r'''
import json, os, pathlib, plistlib, struct, sys
args = sys.argv[1:]
with open(os.environ['SIGNER_LOG'], 'a', encoding='utf-8') as log:
    log.write(json.dumps(args) + '\n')
signing = args[0] == 'sign' or '--force' in args
if (args[0] == 'verify' or '--verify' in args) and os.environ.get('SIGNER_VERIFY_FAIL'):
    sys.exit(9)
if signing:
    if os.environ.get('SIGNER_FAIL'):
        sys.exit(7)
    bundle = pathlib.Path(args[-1])
    option = '--entitlements-xml-file' if '--entitlements-xml-file' in args else '--entitlements'
    if option in args:
        entitlement_path = pathlib.Path(args[args.index(option) + 1])
        entitlements = plistlib.loads(entitlement_path.read_bytes())
        if os.environ.get('SIGNER_DROP_ENTITLEMENTS'):
            entitlements.pop('com.apple.developer.team-identifier', None)
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        xml = plistlib.dumps(entitlements)
        blob = struct.pack('>II', 0xfade7171, 8 + len(xml)) + xml
        signature = struct.pack('>IIIII', 0xfade0cc0, 20 + len(blob), 1, 5, 20) + blob
        header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x100000c, 0, 2, 1, 16, 0, 0)
        command = struct.pack('<IIII', 0x1d, 16, 48, len(signature))
        (bundle / info['CFBundleExecutable']).write_bytes(header + command + signature)
sys.exit(0)
'''


class ResignIpaExecutionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lazer signing fixture ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        fake = self.tools / "fake_signer.py"
        fake.write_text(FAKE_SIGNER, encoding="utf-8")
        for name in ("rcodesign", "codesign"):
            if os.name == "nt":
                (self.tools / (name + ".cmd")).write_text(
                    f'@"{sys.executable}" "{fake}" %*\n', encoding="utf-8")
            else:
                tool = self.tools / name
                tool.write_text(f"#!{sys.executable}\n" + FAKE_SIGNER, encoding="utf-8")
                tool.chmod(0o755)
        self.env = {**os.environ, "PATH": str(self.tools) + os.pathsep + os.environ["PATH"],
                    "SIGNER_LOG": str(self.root / "calls.jsonl"), "PYTHONIOENCODING": "utf-8"}
        self.ipa = self.root / "input.ipa"
        self.output = self.root / "output.ipa"
        self.profile = self.root / "app.mobileprovision"
        self.widget_profile = self.root / "widget.mobileprovision"
        self.p12 = self.root / "certificate.p12"
        self.p12.write_bytes(b"certificate fixture")
        self.password = self.root / "p12-password.txt"
        self.password.write_text(SECRET)
        self.make_ipa()
        self.make_profile(self.profile, APP_ID)
        self.make_profile(self.widget_profile, WIDGET_ID)

    def make_profile(self, path, identifier, *, groups=(GROUP,), team="TEAM123", expired=False):
        entitlements = {"application-identifier": team + "." + identifier,
                        SIGNING.TEAM: team, "get-task-allow": True,
                        "keychain-access-groups": [team + ".*"]}
        if groups:
            entitlements[SIGNING.GROUPS] = list(groups)
        # Exercise extraction from a CMS-like binary envelope as well as plist
        # parsing; actual certificate/CMS trust is the native signer's job.
        expires = datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=-1 if expired else 30)
        path.write_bytes(b"\x30\x82\xff\x00" + plistlib.dumps(
            {"Entitlements": entitlements, "ExpirationDate": expires}) + b"\xffsignature")

    def make_ipa(self):
        with ZipFile(self.ipa, "w") as package:
            for root, identifier, executable, kind in (
                ("Payload/Runner.app/", APP_ID, "Runner", "APPL"),
                ("Payload/Runner.app/PlugIns/Widget.appex/", WIDGET_ID, "Widget", "XPC!"),
            ):
                info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                        "CFBundlePackageType": kind, "CFBundleName": executable,
                        "CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "17",
                        "LazerAppGroupIdentifier": "group.dev.naominet.lazer"}
                if kind == "XPC!":
                    info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
                package.writestr(root + "Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
                package.writestr(root + executable, b"unsigned fixture")
            package.writestr("Payload/Runner.app/Frameworks/Test.framework/Info.plist",
                             plistlib.dumps({"CFBundleExecutable": "Test"}))
            package.writestr("Payload/Runner.app/Frameworks/Test.framework/Test", b"framework")

    def run_signing(self, *, backend="rcodesign", extra=(), overrides=None, extensions=True):
        command = [sys.executable, str(SCRIPT), "--backend", backend,
                   "--ipa", str(self.ipa), "--out", str(self.output), "--profile", str(self.profile)]
        if extensions:
            command += ["--extension-profile", WIDGET_ID + "=" + str(self.widget_profile)]
        if backend == "rcodesign":
            command += ["--p12", str(self.p12), "--password-file", str(self.password)]
        else:
            command += ["--identity", "fixture identity"]
        return subprocess.run([*command, *extra], env={**self.env, **(overrides or {})},
                              capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20)

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def assert_valid_package(self):
        with ZipFile(self.output) as package:
            self.assertTrue(all(name.startswith("Payload/") for name in package.namelist()))
            self.assertFalse(any("password" in name or "entitlements-" in name for name in package.namelist()))
            self.assertFalse(any(SECRET.encode() in package.read(name) for name in package.namelist()))
            for root, identifier, profile, executable in (
                ("Payload/Runner.app/", APP_ID, self.profile, "Runner"),
                ("Payload/Runner.app/PlugIns/Widget.appex/", WIDGET_ID, self.widget_profile, "Widget"),
            ):
                self.assertEqual(package.read(root + "embedded.mobileprovision"), profile.read_bytes())
                info = plistlib.loads(package.read(root + "Info.plist"))
                self.assertEqual(info["LazerAppGroupIdentifier"], GROUP)
                binary = self.root / executable
                binary.write_bytes(package.read(root + executable))
                entitlements = SIGNING.signed_entitlements(binary)
                self.assertEqual(entitlements["application-identifier"], "TEAM123." + identifier)
                self.assertEqual(entitlements["keychain-access-groups"], ["TEAM123." + identifier])
                self.assertEqual(entitlements[SIGNING.GROUPS], [GROUP])
                self.assertEqual((package.getinfo(root + executable).external_attr >> 16) & 0o111, 0o111)

    def test_windows_backend_embeds_each_profile_and_keeps_secret_outside_payload(self):
        result = self.run_signing(extra=("--app-group", GROUP))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_valid_package()
        calls = self.calls()
        signs = [call for call in calls if call[0] == "sign"]
        self.assertTrue(all("--shallow" in call for call in signs))
        self.assertTrue(signs[-1][-1].endswith("Runner.app"))
        self.assertTrue(any("Widget.appex" in call[-1] for call in signs[:-1]))
        self.assertEqual(sum(call[0] == "verify" for call in calls), 3)
        for call in signs:
            if "--entitlements-xml-file" in call:
                self.assertNotIn(":", call[call.index("--entitlements-xml-file") + 1])

    def test_macos_backend_executes_target_specific_sign_and_verification(self):
        result = self.run_signing(backend="codesign", extra=("--app-group", GROUP))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_valid_package()
        self.assertEqual(sum("--verify" in call for call in self.calls()), 2)

    def test_wrong_profile_and_ungranted_group_fail_before_signing(self):
        for flag in ("wrong-identifier", "wrong-group", "wrong-team", "expired"):
            with self.subTest(flag=flag):
                self.make_profile(self.widget_profile, "dev.other.widget" if flag == "wrong-identifier" else WIDGET_ID,
                                  groups=() if flag == "wrong-group" else (GROUP,),
                                  team="OTHERTEAM" if flag == "wrong-team" else "TEAM123",
                                  expired=flag == "expired")
                result = self.run_signing(extra=("--app-group", GROUP))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())
                self.assertFalse((self.root / "calls.jsonl").exists())

    def test_wildcard_profile_resolves_identifiers_without_app_group(self):
        self.make_profile(self.profile, "*", groups=())
        self.make_profile(self.widget_profile, "*", groups=())
        result = self.run_signing(extensions=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with ZipFile(self.output) as package:
            self.assertEqual(plistlib.loads(package.read("Payload/Runner.app/Info.plist"))["LazerAppGroupIdentifier"], "")
            self.assertEqual(package.read("Payload/Runner.app/PlugIns/Widget.appex/embedded.mobileprovision"),
                             self.profile.read_bytes())

    def test_signer_failure_or_dropped_entitlements_cannot_replace_existing_output(self):
        for override in ({"SIGNER_FAIL": "1"}, {"SIGNER_DROP_ENTITLEMENTS": "1"}, {"SIGNER_VERIFY_FAIL": "1"}):
            with self.subTest(override=override):
                self.output.write_bytes(b"previous package")
                result = self.run_signing(overrides=override)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.output.read_bytes(), b"previous package")

    def test_powershell_wrapper_runs_and_deletes_the_password_file(self):
        pwsh = shutil.which("pwsh")
        if not pwsh:
            self.skipTest("PowerShell is unavailable")
        def quote(value):
            return "'" + str(value).replace("'", "''") + "'"
        command = (f"& {quote(REPO / 'ci/resign-ios-ipa.ps1')} -Ipa {quote(self.ipa)} "
                   f"-P12 {quote(self.p12)} -P12Password (ConvertTo-SecureString {quote(SECRET)} -AsPlainText -Force) "
                   f"-Profile {quote(self.profile)} -Out {quote(self.output)} -AppGroup {quote(GROUP)} "
                   f"-ExtensionProfiles @{{ {quote(WIDGET_ID)} = {quote(self.widget_profile)} }}")
        result = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-Command", command],
                                env=self.env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=25)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_valid_package()
        for call in self.calls():
            if "--p12-password-file" in call:
                self.assertFalse(Path(call[call.index("--p12-password-file") + 1]).exists())


if __name__ == "__main__":
    unittest.main()
