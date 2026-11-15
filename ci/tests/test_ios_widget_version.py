"""The widget extension inherits Flutter's version without app linker flags."""

from pathlib import Path
import unittest


REPO = Path(__file__).resolve().parents[2]
WIDGET_CONFIG_ID = "A10000000000000000000040"
WIDGET_BUILD_CONFIGS = (
    "A10000000000000000000020",
    "A10000000000000000000021",
    "A10000000000000000000022",
)


class IosWidgetVersionTest(unittest.TestCase):
    def test_widget_xcconfig_includes_flutter_version_only(self):
        config = (REPO / "ios/Flutter/Widget.xcconfig").read_text(encoding="utf-8")
        self.assertIn('#include "Generated.xcconfig"', config)
        self.assertNotIn("LazerAudio", config)
        self.assertNotIn("OTHER_LDFLAGS", config)

    def test_widget_configurations_use_the_version_xcconfig(self):
        project = (REPO / "ios/Runner.xcodeproj/project.pbxproj").read_text(
            encoding="utf-8"
        )
        for config_id in WIDGET_BUILD_CONFIGS:
            matches = [
                line
                for line in project.splitlines()
                if config_id in line and "isa = XCBuildConfiguration" in line
            ]
            self.assertEqual(len(matches), 1, config_id)
            self.assertIn(
                f"baseConfigurationReference = {WIDGET_CONFIG_ID} /* Widget.xcconfig */",
                matches[0],
            )
            self.assertNotIn("Debug.xcconfig", matches[0])
            self.assertNotIn("Release.xcconfig", matches[0])

    def test_widget_plist_reads_flutter_version_settings(self):
        plist = (REPO / "ios/Widget/Info.plist").read_text(encoding="utf-8")
        self.assertIn("<string>$(FLUTTER_BUILD_NAME)</string>", plist)
        self.assertIn("<key>CFBundleName</key>", plist)
        self.assertIn("<string>PlayCount</string>", plist)
        self.assertIn("<string>$(FLUTTER_BUILD_NUMBER)</string>", plist)
        self.assertNotIn("$(MARKETING_VERSION)", plist)
        self.assertNotIn("$(CURRENT_PROJECT_VERSION)", plist)


if __name__ == "__main__":
    unittest.main()
