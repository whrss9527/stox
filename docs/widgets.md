# Quote widgets

On macOS 14 or later, add **Stox → Watchlist quotes** from Edit Widgets on the desktop or in Notification Center. The small widget shows one stock; the medium widget shows up to six. Edit the widget to select watchlist entries in the order you want. Click a stock to open its row in Stox.

Stox writes a local quote snapshot when its watchlist or quotes change. WidgetKit controls when the widget refreshes; this is not a live trading display. The widget shows quote timestamps and marks cached data. Open Stox to obtain new quotes after it has been closed. A missing or unreadable snapshot displays an instruction to open the app. Holdings, trades, notes and alerts are not exported to the widget.

The app still supports macOS 13; the embedded widget requires macOS 14.

## Build and signing

The XcodeGen schemes embed their respective WidgetKit extension. `build-app.sh` signs the extension before the host and verifies the complete bundle. The shared App Group is `group.io.github.whrss9527.stox.widgets`. The GitHub extension ID is `io.github.whrss9527.stox.widgets`; the App Store extension ID is `io.github.whrss9527.stox.widgets.store`.

Register the group and enable it for the host and the extension using the same Apple team. For an App Store distribution build, update the host provisioning profile and supply the extension distribution profile through `WIDGET_PROVISIONING_PROFILE`. The build rejects a mismatched ID, missing group or development profile. The profile is separate from the host's iCloud profile; the widget does not use iCloud.

Ad-hoc CI verifies compilation, embedding, entitlements and pluginkit discovery. It does **not** prove App Group access for a Developer ID or App Store installation. Before publishing, install a signed build, keep Stox open until quotes load, add both widget sizes, verify that their data updates, click a stock, quit Stox, and confirm that cached data is marked. Also check that an app update retains the widget. If the group is unavailable, record the signing/registration blocker and leave the feature PR unmerged.

## Tests

`make test` covers snapshot encoding, private-data exclusion, configured order, deleted stocks, age, corruption and unknown schema versions. `scripts/check-widget-bundle.py <app> --register` verifies the embedded bundle and temporary pluginkit registration on macOS. `STOX_WIDGET_DIR` redirects the host publisher to an isolated test directory; it does not override the widget's production group container. Never point tests at a user's actual container.
