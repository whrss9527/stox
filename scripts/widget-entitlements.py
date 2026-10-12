#!/usr/bin/env python3
"""Validate the widget profile and prepare extension entitlements for signing."""
import argparse
import plistlib
import subprocess
from pathlib import Path

GROUP = "group.io.github.whrss9527.stox.widgets"
IDENTIFIER = "io.github.whrss9527.stox.widgets.store"


def entitlements(profile=None):
    result = {"com.apple.security.app-sandbox": True, "com.apple.security.application-groups": [GROUP]}
    if profile is not None:
        values = profile.get("Entitlements", {})
        identifier = values.get("com.apple.application-identifier", "")
        team = values.get("com.apple.developer.team-identifier", "")
        if not team or identifier != f"{team}.{IDENTIFIER}":
            raise ValueError("widget profile must match the widget App ID")
        if GROUP not in values.get("com.apple.security.application-groups", []):
            raise ValueError("widget profile is missing the shared App Group")
        if profile.get("ProvisionedDevices") or values.get("get-task-allow"):
            raise ValueError("widget profile must be an App Store distribution profile")
        result["com.apple.application-identifier"] = identifier
        result["com.apple.developer.team-identifier"] = team
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--profile", default="")
    parser.add_argument("--flavor", choices=["github", "appstore"], required=True)
    parser.add_argument("--identity", required=True)
    args = parser.parse_args()
    if args.flavor == "appstore" and args.identity != "-" and not args.profile:
        parser.error("App Store widget signing needs WIDGET_PROVISIONING_PROFILE")
    try:
        profile = None
        if args.profile:
            decoded = subprocess.run(["security", "cms", "-D", "-i", args.profile], check=True, capture_output=True).stdout
            profile = plistlib.loads(decoded)
        args.output.write_bytes(plistlib.dumps(entitlements(profile)))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
