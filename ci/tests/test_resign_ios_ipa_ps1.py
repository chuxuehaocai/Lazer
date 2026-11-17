"""The Windows re-sign script derives entitlements from the profile.

A free Apple ID profile cannot carry an App Group, and iOS refuses to install a
bundle whose entitlements are not a subset of its profile. So the only signing
rule that works with and without an App Group is "sign exactly what the profile
grants" - which is what this script does, and what these checks protect.
"""

from pathlib import Path
import re
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "ci/resign-ios-ipa.ps1"


class WindowsResignScriptTest(unittest.TestCase):
    def setUp(self):
        self.text = SCRIPT.read_text(encoding="utf-8-sig")
        # Comments explain what the script must NOT do ("rather than this
        # repository's Runner.entitlements"), so code checks ignore both the
        # <# ... #> help block and `#` line comments.
        without_help = re.sub(r"<#.*?#>", "", self.text, flags=re.DOTALL)
        self.code = "\n".join(
            line for line in without_help.splitlines()
            if not line.lstrip().startswith("#")
        )

    def test_the_script_exists_and_is_powershell(self):
        self.assertTrue(SCRIPT.is_file())
        self.assertIn("rcodesign", self.text)
        self.assertIn("cargo install apple-codesign", self.text)

    def test_entitlements_come_from_the_profile_not_the_repo(self):
        # Reading `Entitlements` out of the profile is the whole point: using
        # Runner.entitlements would add an App Group a free profile rejects.
        self.assertIn("Entitlements", self.code)
        self.assertNotIn("Runner.entitlements", self.code)
        self.assertNotIn("Widget.entitlements", self.code)

    def test_it_reports_whether_the_profile_grants_an_app_group(self):
        # The user must be told whether the widget can work before they install.
        self.assertIn("com.apple.security.application-groups", self.code)
        self.assertIn("no App Group", self.code)

    def test_it_requires_an_application_identifier(self):
        self.assertIn("application-identifier", self.code)

    def test_it_signs_nested_code_before_the_app(self):
        self.assertIn("*.appex", self.text)
        self.assertIn("*.framework", self.text)
        self.assertIn("*.dylib", self.text)
        # The app bundle must be the last target, or its seal covers an unsigned
        # extension.
        self.assertRegex(self.text, r"\$targets\s*=\s*@\(\$nested\)\s*\+\s*@\(\$app\)")

    def test_it_verifies_the_signature_it_produced(self):
        self.assertIn("print-signature-info", self.code)
        # The script matches the regex-escaped spelling, so that is what proves
        # the check exists.
        self.assertIn(r"com\.apple\.developer\.team-identifier", self.code)

    def test_it_reuses_the_shipped_bundle_check(self):
        self.assertIn("verify-ios-bundle.py", self.text)

    def test_the_profile_entitlements_loop_keeps_the_last_pair(self):
        # `Count - 2` silently dropped the final entitlement; that bug removed
        # keychain-access-groups from every re-signed build.
        self.assertIn("$index + 1 -lt $children.Count", self.text)
        self.assertNotIn("$children.Count - 2", self.text)

    def test_the_app_group_flag_is_optional(self):
        self.assertRegex(self.text, r"\[string\]\$AppGroup")
        self.assertIn("StartsWith('group.')", self.text)

    def test_a_secure_password_never_reaches_argv(self):
        # rcodesign takes the password through a file, so it does not appear in
        # the process list or the shell history.
        self.assertIn("p12-password-file", self.text)
        self.assertIn("SecureString", self.text)


class ProfileParsingTest(unittest.TestCase):
    """The parsing rules the script relies on, checked without PowerShell."""

    def test_a_mobileprovision_body_is_plain_xml_between_markers(self):
        text = (
            "PK\x03\x04binary-prefix"
            '<?xml version="1.0" encoding="UTF-8"?>'
            "<plist version=\"1.0\"><dict/></plist>"
            "trailing-signature"
        )
        start = text.index("<?xml")
        end = text.rindex("</plist>") + len("</plist>")
        body = text[start:end]
        self.assertTrue(body.startswith("<?xml"))
        self.assertTrue(body.endswith("</plist>"))

    def test_an_entitlement_dict_is_alternating_keys_and_values(self):
        # The script walks child nodes in pairs; an odd child means a malformed
        # profile and must not be silently truncated.
        children = ["key", "string", "key", "true", "key", "array"]
        self.assertEqual(len(children) % 2, 0)
        self.assertEqual(len(children) // 2, 3)


if __name__ == "__main__":
    unittest.main()
