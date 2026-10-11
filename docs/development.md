# Developing Stox

[← Back to the README](../README.md) · [简体中文](development.zh-CN.md)

## Development

```
Sources/
  StoxCore/   UI-independent logic: symbol parsing, Tencent quote and search parsing, trading hours, alerts,
              formatting, sync file format and merge rules, release info and install location (builds and tests on Linux)
  Stox/       The menu bar app: NSStatusItem + glass panel (NSPanel) + SwiftUI, Settings window, iCloud sync, updates
  StoxCLI/    The stox-cli debugging tool
Resources/             Info.plist, and the English (en.lproj) and Simplified Chinese (zh-Hans.lproj) interface strings
Tests/StoxCoreTests/   Unit tests, using real API responses as samples
Tests/StoxTests/       macOS app tests with fake providers, a controlled clock and isolated settings/sync files
scripts/
  build-app.sh           Build, assemble and sign Stox.app (the App Store edition with STOX_FLAVOR=appstore)
  build-app-store.sh     App Store edition: sign with the sandbox and provisioning profile, package Stox-AppStore.pkg for upload
  app-store-connect.py   Fill in the App Store listing from docs/app-store/listing, pick the build, submit for review (App Store Connect API)
  make-icon.swift        Generate the app icon
  check-datasources.sh   Print raw quote API responses to spot format changes
  check-localization.py  Check that the English and Simplified Chinese strings are complete and consistent
  ci-e2e.sh              CI end-to-end tests: launch, screenshots, iCloud sync, one-click update, the App Store edition in the sandbox
```

### CI validation tiers

Every branch runs all Linux core tests, localization and offline listing checks, and all native macOS unit tests. The macOS job builds the runner architecture and runs `ci-e2e.sh quick` (eight English/Chinese panel, detail, search and settings cases) plus the complete fake-iCloud sync tests. It has a 20-minute execution limit. SwiftPM build outputs are cached by compiler version, runner architecture and manifest. Main retains the universal build, full smoke suite, update tests, live-data probes, App Store sandbox and store screenshots. Branches save diagnostic logs; screenshots are optional with `[screenshots]` in the commit message. `run_case` waits up to 20 seconds for `STOX_DIAG late ready=true`, emitted after all late panel diagnostics or settings diagnostics, and fails on timeout or early exit. The same readiness check replaces the fixed sync-panel wait. `scripts/test_ci_readiness.py` exercises this contract offline; actual macOS job duration must be checked in Actions.

### P&L calendar backfill

`ProfitHistory.backfill` consumes daily, forward-adjusted candlesticks and fills only absent market/day records. It uses the preceding trading close and share counts reversed from retained trades, skips all trade/dividend days and incomplete market totals, and limits the result to 60 completed trading days. Truncated or unknown trade logs are treated conservatively. Estimates carry `estimated`, enter normal totals, and omit historical value and cost-based P&L. Old records decode with `estimated = false`; actual closing snapshots replace estimates. `QuoteStore.backfillProfitHistory` runs once per calendar opening, requests 62 bars (including the reference close and a possible live bar), cancels writes when the panel closes, and discards results if holdings changed while awaiting data. It does not run during quote polling. Prices are forward-adjusted, so these results are estimates rather than reconstructed brokerage statements.

### Application unit tests

`make test` runs `StoxCoreTests` on every platform and `StoxTests` on macOS. The app tests use fake quote providers, `QuoteStoreClock`, dedicated UserDefaults suites and temporary sync folders; they never use live quote endpoints or the user's iCloud files. `SyncManager` accepts a test location and can disable file watching while exercising the same apply/push paths. Stop panel/polling tasks and disable sync before removing fixtures.

The core's `FailoverPolicy` and `TickerVisibility` keep time and visibility decisions independent of AppKit. For resources outside the main app, set `AppLanguage.bundle` before starting work; tests restore it after checking their isolated translation bundle. Localization follows the selected bundle.

### Trade fees and compatibility

`Trade.fee` is an optional nonnegative amount in the trading currency. Missing fees mean zero. Initial and additional purchases capitalize fees in cost; dividend cost uses net cash, and sell/dividend records store realized profit after fees. Daily P&L subtracts the fees for the quote's local trading date exactly once, including sold-out positions; dividend cash itself keeps the existing ex-dividend calculation.

Fee-bearing records encode `side` as `buy-fee-v1`, `sell-fee-v1`, or `dividend-fee-v1`, alongside `fee`; records without a fee keep the original labels. This is a new trade type within sync format 1. Clients with #74's preservation support (0.50.2 onward) retain fee-bearing records as opaque JSON through edits, backup and sync, so they cannot silently drop the fee field. Those clients do not display or calculate the opaque trades until upgraded. `TradeFeeSyncTests` exercise an actual legacy field/type schema and the original preservation mechanism.

### Quote invariant checks

`swift run stox-cli check` checks the reviewed A-share, Hong Kong and US sample symbols against the field counts in `Sources/StoxCore/DatasourceSnapshots`, as well as price range, previous close, A-share turnover/volume, timestamp and 52-week high. Use `--source sina` for the backup source. `--save-raw response.bin` preserves original bytes even for HTTP errors; `--raw response.bin --at 2026-10-07T10:00:00Z` replays a response without networking. Exit status is 0 for success, 1 for response differences and 2 for invalid arguments. Symbols without a reviewed schema fail explicitly.

StoxCore has no holiday calendar. The default timestamp window is ten calendar days for A shares, five for Hong Kong/US, and five minutes into the future. An unusually long exchange closure requires an explicit `--max-age-days` override (`STOX_QUOTE_MAX_AGE_DAYS` for the script). The invariant check reports these bounds; it does not claim to know the exact last holiday trading date. Review field meanings before changing snapshots.

The Linux `datasources` workflow builds the CLI, runs replay tests and both live source checks, preserves raw responses, and appends invariant differences to the existing failure issue report. `ONLY` still selects source/market probes.

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

`scripts/check-quote-recovery.sh` uses a local HTTP server to fail both quote sources and then restore the primary. It checks backoff, the panel retry state, and the normal cadence after recovery. Run it only in isolated CI: it launches the app and temporarily changes refresh settings.

CI launches the packaged app on macOS: it opens the panel, details, search and Settings window and takes screenshots (in Chinese, then a few in English); tests sync with a fake iCloud Drive folder; and really updates the app to 9.9.9 from a local fake release and confirms it relaunches.

The scheduled datasource probe returns a failure for request errors or missing required quote fields and retains endpoint/response excerpts. On main, failures create or comment on the fixed-title bug issue without assigning it to an agent. Build smoke failures remain non-blocking but emit a warning. Diagnostic candidate symbols may legitimately return empty records. Known-failed exploratory probes (the retired UsDay path and Sina without its required Referer) run only with `STOX_DATASOURCE_EXPERIMENTS=1`; production probes remain strict.

### Diagnostics and log rotation

About includes Copy diagnostics and a bug-report link that prefills the app and macOS versions. The copied report contains the release channel, sync state, current quote source and at most 200 recent log lines. It reads neither holdings nor trading data. Log message numbers, local paths, links and financial descriptions are redacted; timestamps and operational events remain. Reports stay on the clipboard until the user pastes them.

When `stox.log` exceeds 1 MB, the next write moves it to `stox.log.1`, retaining only the current and previous files. Diagnostics reads both in order so a recent rotation does not discard the useful context. Temporary-file tests cover the rotation boundary, retention and redaction.

### Releasing a new version

Releases are driven by `CHANGELOG.md`, using the shared release workflow in [Frit](https://github.com/whrss9527/frit):

1. Add a section for the new version at the top of `CHANGELOG.md`, such as `## 0.46.0`. It goes into the release notes, and the About & Updates page in the app shows this section too.
2. Push to main (or merge into main). After the build passes, the final release job sees that there is no `v0.46.0` tag yet, packages a universal `Stox.zip`, generates the `SHA256SUMS.txt` checksum file, tags and publishes it. Installed copies of Stox offer the update at their next check.

GitHub releases require a Developer ID certificate and Apple notarization credentials in the repository secrets. Both release workflows set `require-notarization: true` and fail if those credentials are unavailable. Local development builds can still use ad-hoc signing. See Frit's [docs/release.md](https://github.com/whrss9527/frit/blob/main/docs/release.md) for the setup.

You can also run the release workflow by hand on the Actions page: leave the tag empty to release the version at the top of `CHANGELOG.md`, or check overwrite to rebuild from the existing tag and replace the assets.

The App Store edition is not released automatically. After a GitHub release, add the English What's New (`docs/app-store/listing/en-US/whats_new/<version>.txt`) and run the app-store workflow by hand on the Actions page: it builds, signs and uploads the app, fills in the listing on App Store Connect from `docs/app-store/listing/`, picks the build and, when asked, submits it for review; see [docs/app-store.md](app-store.md) (in Chinese).

See [docs/DESIGN.md](DESIGN.md) (in Chinese) for the design decisions.
