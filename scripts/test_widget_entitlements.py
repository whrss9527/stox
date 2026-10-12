import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("widget_entitlements", Path(__file__).with_name("widget-entitlements.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WidgetEntitlementTests(unittest.TestCase):
    def profile(self):
        return {"Entitlements": {"com.apple.application-identifier": "TEAM." + module.IDENTIFIER,
                                 "com.apple.developer.team-identifier": "TEAM",
                                 "com.apple.security.application-groups": [module.GROUP]}}

    def test_adhoc_and_distribution_entitlements(self):
        self.assertNotIn("com.apple.application-identifier", module.entitlements())
        self.assertEqual(module.entitlements(self.profile())["com.apple.application-identifier"], "TEAM." + module.IDENTIFIER)

    def test_wrong_app_group_identity_and_development_profile_are_rejected(self):
        for mutation in [lambda p: p["Entitlements"].update({"com.apple.application-identifier": "TEAM.other"}),
                         lambda p: p["Entitlements"].update({"com.apple.security.application-groups": []}),
                         lambda p: p.update({"ProvisionedDevices": ["device"]}),
                         lambda p: p["Entitlements"].update({"get-task-allow": True})]:
            profile = self.profile()
            mutation(profile)
            with self.assertRaises(ValueError):
                module.entitlements(profile)
