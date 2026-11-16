"""Tests for iOS app and extension bundle metadata validation."""

import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from zipfile import ZipFile


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_ios_bundle", REPO / "ci/verify-ios-bundle.py"
)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


def bundle_info(
    *,
    identifier: str,
    package_type: str,
    executable: str | None,
    short_version: str = "2.0.200",
    build_version: str = "200",
    name: str | None = "Lazer",
) -> dict:
    info = {
        "CFBundleIdentifier": identifier,
        "CFBundlePackageType": package_type,
        "CFBundleShortVersionString": short_version,
        "CFBundleVersion": build_version,
    }
    if name is not None:
        info["CFBundleName"] = name
    if executable is not None:
        info["CFBundleExecutable"] = executable
    if package_type == "XPC!":
        # A real appex carries its extension point; the bundle check now requires
        # it, because an extension without the WidgetKit point installs but never
        # appears in the widget gallery.
        info["NSExtension"] = {
            "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"
        }
    return info


class SharedContainerContractTest(unittest.TestCase):
    def test_the_shipped_project_shares_one_application_group(self):
        group = VERIFY.verify_shared_container_contract(REPO)
        self.assertTrue(group.startswith("group."))

    def _project_with(
        self,
        runner_groups,
        widget_groups,
        *,
        configured: str | None = "group.dev.naominet.lazer",
    ) -> Path:
        root = Path(tempfile.mkdtemp())
        (root / "ios/Runner").mkdir(parents=True)
        (root / "ios/Widget").mkdir(parents=True)
        (root / "ios/Flutter").mkdir(parents=True)
        (root / "ios/Runner/Runner.entitlements").write_bytes(
            plistlib.dumps(
                {"com.apple.security.application-groups": runner_groups}
            )
        )
        (root / "ios/Widget/Widget.entitlements").write_bytes(
            plistlib.dumps(
                {"com.apple.security.application-groups": widget_groups}
            )
        )
        if configured is not None:
            (root / VERIFY.APP_GROUP_XCCONFIG).write_text(
                "# fixture\n"
                f"{VERIFY.XCCONFIG_SETTING} = {configured}\n",
                encoding="utf-8",
            )
        return root

    def test_a_widget_with_no_group_is_rejected(self):
        root = self._project_with(["group.dev.naominet.lazer"], [])
        with self.assertRaisesRegex(ValueError, "Widget.entitlements"):
            VERIFY.verify_shared_container_contract(root)

    def test_an_app_with_no_group_is_rejected(self):
        root = self._project_with([], ["group.dev.naominet.lazer"])
        with self.assertRaisesRegex(ValueError, "Runner.entitlements"):
            VERIFY.verify_shared_container_contract(root)

    def test_disjoint_groups_are_rejected(self):
        # The failure that empties a widget while every build check passes.
        root = self._project_with(
            ["group.dev.naominet.lazer"], ["group.dev.naominet.other"]
        )
        with self.assertRaisesRegex(ValueError, "different application groups?"):
            VERIFY.verify_shared_container_contract(root)

    def test_a_group_without_the_group_prefix_is_rejected(self):
        root = self._project_with(
            ["dev.naominet.lazer"], ["dev.naominet.lazer"]
        )
        with self.assertRaisesRegex(ValueError, "invalid application group"):
            VERIFY.verify_shared_container_contract(root)

    def test_a_build_setting_resolves_to_the_configured_group(self):
        root = self._project_with(
            ["$(LAZER_APP_GROUP_IDENTIFIER)"],
            ["$(LAZER_APP_GROUP_IDENTIFIER)"],
            configured="group.com.example.resigned",
        )
        self.assertEqual(
            VERIFY.verify_shared_container_contract(root),
            "group.com.example.resigned",
        )

    def test_a_variable_with_no_definition_is_rejected(self):
        root = self._project_with(
            ["$(LAZER_APP_GROUP_IDENTIFIER)"],
            ["$(LAZER_APP_GROUP_IDENTIFIER)"],
            configured=None,
        )
        with self.assertRaisesRegex(ValueError, "does not define"):
            VERIFY.verify_shared_container_contract(root)

    def test_a_variable_the_project_never_defines_is_rejected(self):
        root = self._project_with(
            ["$(SOME_OTHER_GROUP)"], ["$(SOME_OTHER_GROUP)"]
        )
        with self.assertRaisesRegex(ValueError, "not a build setting"):
            VERIFY.verify_shared_container_contract(root)

    def test_a_literal_on_one_side_and_a_variable_on_the_other_is_rejected(self):
        # Xcode substitutes one build setting into both files; a split means one
        # bundle joins a group the other never looks at.
        root = self._project_with(
            ["group.dev.naominet.lazer"], ["$(LAZER_APP_GROUP_IDENTIFIER)"]
        )
        with self.assertRaisesRegex(ValueError, "different application"):
            VERIFY.verify_shared_container_contract(root)

    def test_more_than_one_group_is_rejected(self):
        # The runtime reads exactly one identifier from Info.plist, so a second
        # entry would silently be ignored instead of shared.
        root = self._project_with(
            ["$(LAZER_APP_GROUP_IDENTIFIER)", "group.example.other"],
            ["$(LAZER_APP_GROUP_IDENTIFIER)", "group.example.other"],
        )
        with self.assertRaisesRegex(ValueError, "exactly one group"):
            VERIFY.verify_shared_container_contract(root)


class WidgetExtensionPointTest(unittest.TestCase):
    def test_the_shipped_widget_is_a_widgetkit_extension(self):
        info = plistlib.loads((REPO / "ios/Widget/Info.plist").read_bytes())
        VERIFY.verify_widget_extension_point(info, "ios/Widget/Info.plist")

    def test_a_plain_extension_is_rejected(self):
        # An extension without this point installs but never appears in the
        # widget gallery, which reads as "the widget is missing".
        info = {
            "NSExtension": {"NSExtensionPointIdentifier": "com.apple.share-services"}
        }
        with self.assertRaisesRegex(ValueError, "expected"):
            VERIFY.verify_widget_extension_point(info, "fixture")

    def test_a_missing_extension_dict_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "NSExtension"):
            VERIFY.verify_widget_extension_point({}, "fixture")


class IosBundleMetadataTest(unittest.TestCase):
    def make_app(self, root: Path, *, extension_executable: str | None = "Widget"):
        app = root / "Runner.app"
        extension = app / "PlugIns/PlayCount.appex"
        extension.mkdir(parents=True)
        (app / "Runner").write_bytes(b"app")
        if extension_executable is not None:
            (extension / extension_executable).write_bytes(b"widget")
        (app / "Info.plist").write_bytes(
            plistlib.dumps(
                bundle_info(
                    identifier="dev.naominet.lazer",
                    package_type="APPL",
                    executable="Runner",
                )
            )
        )
        (extension / "Info.plist").write_bytes(
            plistlib.dumps(
                bundle_info(
                    identifier="dev.naominet.lazer.PlayCountWidget",
                    package_type="XPC!",
                    executable=extension_executable,
                )
            )
        )
        return app

    def test_valid_app_and_extension_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            VERIFY.verify_app(self.make_app(Path(directory)))

    def test_blank_extension_name_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            info_path = app / "PlugIns/PlayCount.appex/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["CFBundleName"] = " "
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "CFBundleName"):
                VERIFY.verify_app(app)

    def test_missing_extension_executable_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory), extension_executable=None)
            with self.assertRaisesRegex(ValueError, "CFBundleExecutable"):
                VERIFY.verify_app(app)

    def test_missing_extension_executable_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            (app / "PlugIns/PlayCount.appex/Widget").unlink()
            with self.assertRaisesRegex(ValueError, "no executable named Widget"):
                VERIFY.verify_app(app)

    def test_extension_version_must_match_the_app(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            info_path = app / "PlugIns/PlayCount.appex/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["CFBundleVersion"] = "1"
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "does not match"):
                VERIFY.verify_app(app)

    def test_ipa_checks_extension_metadata_after_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "Lazer-iOS-aarch64.ipa"
            extension = "Payload/Runner.app/PlugIns/PlayCount.appex/"
            with ZipFile(ipa, "w") as package:
                package.writestr(
                    "Payload/Runner.app/Info.plist",
                    plistlib.dumps(
                        bundle_info(
                            identifier="dev.naominet.lazer",
                            package_type="APPL",
                            executable="Runner",
                        )
                    ),
                )
                package.writestr("Payload/Runner.app/Runner", b"app")
                package.writestr(
                    extension + "Info.plist",
                    plistlib.dumps(
                        bundle_info(
                            identifier="dev.naominet.lazer.PlayCountWidget",
                            package_type="XPC!",
                            executable="Widget",
                        )
                    ),
                )
                package.writestr(extension + "Widget", b"widget")
            VERIFY.verify_ipa(ipa)

    def test_ipa_rejects_missing_extension_executable_key(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "Lazer-iOS-aarch64.ipa"
            extension = "Payload/Runner.app/PlugIns/PlayCount.appex/"
            with ZipFile(ipa, "w") as package:
                package.writestr(
                    "Payload/Runner.app/Info.plist",
                    plistlib.dumps(
                        bundle_info(
                            identifier="dev.naominet.lazer",
                            package_type="APPL",
                            executable="Runner",
                        )
                    ),
                )
                package.writestr("Payload/Runner.app/Runner", b"app")
                package.writestr(
                    extension + "Info.plist",
                    plistlib.dumps(
                        bundle_info(
                            identifier="dev.naominet.lazer.PlayCountWidget",
                            package_type="XPC!",
                            executable=None,
                        )
                    ),
                )
                package.writestr(extension + "Widget", b"widget")
            with self.assertRaisesRegex(ValueError, "CFBundleExecutable"):
                VERIFY.verify_ipa(ipa)


if __name__ == "__main__":
    unittest.main()
