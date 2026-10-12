#!/usr/bin/env python3
"""Inspect embedded WidgetKit extensions and optionally register them on macOS."""
import argparse
import plistlib
import subprocess
import time
from pathlib import Path

GROUP = "group.io.github.whrss9527.stox.widgets"


def signed_entitlements(bundle):
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)], capture_output=True, check=True)
    return plistlib.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--register", action="store_true")
    args = parser.parse_args()
    host_info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    host_groups = signed_entitlements(args.app).get("com.apple.security.application-groups", [])
    assert GROUP in host_groups, "host is missing the widget App Group"
    widgets = list((args.app / "Contents/PlugIns").glob("*.appex"))
    assert len(widgets) == 1, "expected exactly one embedded widget extension"
    widget = widgets[0]
    info = plistlib.loads((widget / "Contents/Info.plist").read_bytes())
    identifier = info["CFBundleIdentifier"]
    assert identifier.startswith(host_info["CFBundleIdentifier"] + "."), "widget ID must extend host ID"
    assert info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
    assert info["CFBundleShortVersionString"] == host_info["CFBundleShortVersionString"]
    assert info["CFBundleVersion"] == host_info["CFBundleVersion"]
    entitlements = signed_entitlements(widget)
    assert entitlements.get("com.apple.security.app-sandbox") is True
    assert GROUP in entitlements.get("com.apple.security.application-groups", [])
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(args.app)], check=True)
    if args.register:
        try:
            subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                            "-f", str(args.app.resolve())], check=True)
            subprocess.run(["pluginkit", "-a", str(widget.resolve())], check=True)
            for attempt in range(15):
                listing = subprocess.run(["pluginkit", "-m", "-A", "-D", "-v", "-i", identifier], capture_output=True, text=True, check=True)
                if identifier in listing.stdout:
                    break
                time.sleep(1)
            assert identifier in listing.stdout, "pluginkit could not discover widget"
        finally:
            subprocess.run(["pluginkit", "-r", str(widget.resolve())], check=False, capture_output=True)
    print(f"Widget bundle verified: {identifier}")


if __name__ == "__main__":
    main()
