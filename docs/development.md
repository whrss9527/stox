# Developing Stox

[← Back to the README](../README.md) · [简体中文](guide.zh-CN.md)

## Development

```
Sources/
  StoxCore/   UI-independent logic: symbol parsing, Tencent quote and search parsing, trading hours, alerts,
              formatting, sync file format and merge rules, release info and install location (builds and tests on Linux)
  Stox/       The menu bar app: NSStatusItem + glass panel (NSPanel) + SwiftUI, Settings window, iCloud sync, updates
  StoxCLI/    The stox-cli debugging tool
Resources/             Info.plist, and the English (en.lproj) and Simplified Chinese (zh-Hans.lproj) interface strings
Tests/StoxCoreTests/   Unit tests, using real API responses as samples
scripts/
  build-app.sh           Build, assemble and sign Stox.app (the App Store edition with STOX_FLAVOR=appstore)
  build-app-store.sh     App Store edition: sign with the sandbox and provisioning profile, package Stox-AppStore.pkg for upload
  app-store-connect.py   Fill in the App Store listing from docs/app-store/listing, pick the build, submit for review (App Store Connect API)
  make-icon.swift        Generate the app icon
  check-datasources.sh   Print raw quote API responses to spot format changes
  check-localization.py  Check that the English and Simplified Chinese strings are complete and consistent
  ci-e2e.sh              CI end-to-end tests: launch, screenshots, iCloud sync, one-click update, the App Store edition in the sandbox
```

### Interface languages

User-visible text is written in Chinese as `L("中文原文", arguments…)` (see `Sources/StoxCore/AppLanguage.swift`). The Chinese source is the key in `Resources/en.lproj/Localizable.strings` and `Resources/zh-Hans.lproj/Localizable.strings`, which `scripts/build-app.sh` copies into the app. Arguments use `%@` placeholders, and translations can reorder them with `%1$@`, `%2$@`. When you add or change text, update both tables and run `python3 scripts/check-localization.py` (`make test` runs it too); CI runs it on every push. To try the English interface without changing your system language:

```bash
dist/Stox.app/Contents/MacOS/Stox --show-panel -AppleLanguages '(en)'
```

Check the data sources from the command line:

```bash
swift run stox-cli quote sh600519 700 AAPL us.IXIC
swift run stox-cli search 茅台
swift run stox-cli raw hk00700
swift run stox-cli kline usAAPL week      # the latest candles (day, week, month)
swift run stox-cli book sh600519          # A-share order book and buy/sell volume
swift run stox-cli rank gainers 10        # A-share movers (gainers, losers, turnover, industries)
swift run stox-cli sina sh600519 700 AAPL # the fallback Sina quotes
swift run stox-cli latest-release 0.1.0   # the latest GitHub release and whether it can be installed in one click
```

When working on the UI, you can have the app open the panel or Settings window right after launch and print the menu bar text and window positions in the terminal:

```bash
dist/Stox.app/Contents/MacOS/Stox --show-panel                    # the watchlist
dist/Stox.app/Contents/MacOS/Stox --show-panel --expand sh600519  # expand the details of a symbol
dist/Stox.app/Contents/MacOS/Stox --show-panel --search 腾讯       # prefill the search field
dist/Stox.app/Contents/MacOS/Stox --show-settings display         # Settings: general, display, sync, about
dist/Stox.app/Contents/MacOS/Stox --check-update --show-panel     # check for updates first
```

To test sync and updates, environment variables replace the real iCloud Drive and GitHub:

| Environment variable | Effect |
|---|---|
| `STOX_SYNC_DIR=/tmp/fake-icloud` | Put the sync file in this folder instead of iCloud Drive/Stox |
| `STOX_UPDATE_URL=http://127.0.0.1:8765/latest.json` | Read the "latest release" from here, in the format of GitHub's releases API |
| `STOX_TEST_TRANSLOCATED=1` | Act as if running from a read-only temporary location, so updates install into Applications |

CI launches the packaged app on macOS: it opens the panel, details, search and Settings window and takes screenshots (in Chinese, then a few in English); tests sync with a fake iCloud Drive folder; and really updates the app to 9.9.9 from a local fake release and confirms it relaunches.

### Releasing a new version

Releases are driven by `CHANGELOG.md`, using the shared release workflow in [Frit](https://github.com/whrss9527/frit):

1. Add a section for the new version at the top of `CHANGELOG.md`, such as `## 0.46.0`. It goes into the release notes, and the About & Updates page in the app shows this section too.
2. Push to main (or merge into main). After the build passes, the final release job sees that there is no `v0.46.0` tag yet, packages a universal `Stox.zip`, generates the `SHA256SUMS.txt` checksum file, tags and publishes it. Installed copies of Stox offer the update at their next check.

When the repository secrets hold a Developer ID certificate and notarization credentials, the release is signed with the certificate and notarized by Apple, so users can open it with a double-click; otherwise it's ad-hoc signed as before. See Frit's [docs/release.md](https://github.com/whrss9527/frit/blob/main/docs/release.md) for the setup.

You can also run the release workflow by hand on the Actions page: leave the tag empty to release the version at the top of `CHANGELOG.md`, or check overwrite to rebuild from the existing tag and replace the assets.

The App Store edition is not released automatically. After a GitHub release, add the English What's New (`docs/app-store/listing/en-US/whats_new/<version>.txt`) and run the app-store workflow by hand on the Actions page: it builds, signs and uploads the app, fills in the listing on App Store Connect from `docs/app-store/listing/`, picks the build and, when asked, submits it for review; see [docs/app-store.md](app-store.md) (in Chinese).

See [docs/DESIGN.md](DESIGN.md) (in Chinese) for the design decisions.
