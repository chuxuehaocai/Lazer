"""The App Group is a build setting, so the bundles agree without a rebuild."""

from pathlib import Path
import plistlib
import re
import unittest


REPO = Path(__file__).resolve().parents[2]
SETTING = "LAZER_APP_GROUP_IDENTIFIER"
XCCONFIG = REPO / "ios/Flutter/LazerAppGroup.xcconfig"
PLISTS = (
    REPO / "ios/Runner/Info.plist",
    REPO / "ios/Widget/Info.plist",
)
ENTITLEMENTS = (
    REPO / "ios/Runner/Runner.entitlements",
    REPO / "ios/Widget/Widget.entitlements",
)


def configured_group() -> str:
    value = None
    for raw in XCCONFIG.read_text(encoding="utf-8").splitlines():
        line = raw.split("//", 1)[0].strip()
        if line.startswith(f"{SETTING} "):
            value = line.split("=", 1)[1].strip()
    assert value is not None, f"{XCCONFIG} does not define {SETTING}"
    return value


class AppGroupSettingTest(unittest.TestCase):
    def test_the_setting_has_one_default(self):
        group = configured_group()
        self.assertTrue(group.startswith("group."))
        self.assertNotIn(" ", group)

    def test_both_bundles_read_the_setting_instead_of_a_literal(self):
        # A literal in a plist cannot be rewritten by a re-signing step, and the
        # group a re-signed install needs is never the one this repo ships with.
        for path in PLISTS:
            info = plistlib.loads(path.read_bytes())
            self.assertEqual(
                info.get("LazerAppGroupIdentifier"),
                f"$({SETTING})",
                f"{path.name} must resolve the group from the build setting",
            )

    def test_the_entitlements_use_the_same_setting(self):
        for path in ENTITLEMENTS:
            info = plistlib.loads(path.read_bytes())
            groups = info["com.apple.security.application-groups"]
            self.assertEqual(
                groups,
                [f"$({SETTING})"],
                f"{path.name} must name the setting, not a literal",
            )


class SharedSwiftSourceTest(unittest.TestCase):
    """The two targets compile one file; a second copy would drift."""

    def test_the_helper_exists_and_reads_the_info_plist(self):
        source = (REPO / "ios/Shared/LazerAppGroup.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('forInfoDictionaryKey: "LazerAppGroupIdentifier"', source)
        self.assertIn(f"fallbackIdentifier = \"group.", source)

    def test_neither_target_hardcodes_the_group(self):
        for relative in ("ios/Runner/AppDelegate.swift", "ios/Widget/PlayCountWidget.swift"):
            source = (REPO / relative).read_text(encoding="utf-8")
            code = "\n".join(
                line for line in source.splitlines()
                if not line.lstrip().startswith(("//", "*", "/*"))
            )
            self.assertNotRegex(
                code,
                r"=\s*\"group\.[a-z]",
                f"{relative} still assigns a literal App Group",
            )
            self.assertIn("LazerAppGroup.identifier", code)

    def test_both_targets_compile_the_helper(self):
        project = (REPO / "ios/Runner.xcodeproj/project.pbxproj").read_text(
            encoding="utf-8"
        )
        # One file reference, one build file per target, both in a Sources phase.
        self.assertEqual(project.count("path = LazerAppGroup.swift"), 1)
        self.assertEqual(
            project.count("LazerAppGroup.swift in Sources */ = {isa = PBXBuildFile"),
            2,
        )
        sources = re.findall(
            r"isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);",
            project,
            re.DOTALL,
        )
        holders = [block for block in sources if "LazerAppGroup.swift" in block]
        self.assertEqual(
            len(holders), 2, "both the app and the widget must compile it"
        )


class ResignScriptTest(unittest.TestCase):
    def setUp(self):
        self.script = (REPO / "ci/resign-ios-ipa.sh").read_text(encoding="utf-8")

    def test_it_refuses_a_group_it_cannot_use(self):
        self.assertIn("must start with 'group.'", self.script)

    def test_it_checks_the_profile_carries_the_group(self):
        # Signing with a group the profile does not allow is dropped silently by
        # codesign and shows up later as an empty widget.
        self.assertIn("is not in the profile", self.script)

    def test_it_keeps_the_original_entitlements(self):
        self.assertIn("--entitlements :-", self.script)
        # Only the group (and the team-derived keys) may change.
        self.assertIn('Delete :com.apple.security.application-groups', self.script)

    def test_it_embeds_the_profile(self):
        self.assertIn("embedded.mobileprovision", self.script)

    def test_it_verifies_the_result(self):
        self.assertIn("signed without", self.script)
        self.assertIn("--verify --deep --strict", self.script)

    def test_it_warns_a_free_profile_cannot_work(self):
        self.assertIn("free Apple ID", self.script)


if __name__ == "__main__":
    unittest.main()
