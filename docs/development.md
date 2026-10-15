# Developing Stox

The GitHub app uses FritUpdate from the exact public Frit 0.4.2 tag (`Package.resolved`). App-specific configuration keeps `Stox.zip`, the `STOX_` environment prefix, `update.` preference keys, six-hour checks, notifications and relaunch callbacks. The library owns checking, download/verification, replacement and the update views. `StoxReleaseFeed` retains only the read-only HTTP adapter needed by the Linux CLI and “What's New”; release parsing/version ordering/notes use FritCore. The old Stox updater/installer/shell and duplicate algorithms were removed; their library regressions remain in Frit, including all seven staged-replacement cases. An app integration test exercises the actual shared updater against isolated legacy skip/notification preferences.

Xcode and SwiftPM both pin the same SDK. Only the ordinary Xcode target links FritUpdate; the App Store target links FritCore only, guarded imports remain excluded and sandbox CI rejects FritUpdate symbols/resources. Packaging verifies the actual shared resource bundle contains English/Simplified/Traditional strings. The app sets Frit's language hook to its current language. Release-workflow pins remain independent at the already verified 0.4.1/2291523 commit until a separate workflow change is needed. Full update/relocation tests and the first public-version upgrade remain required; a user's real-device acceptance is not replaced by CI.

[← Back to the README](../README.md) · [简体中文](development.zh-CN.md)

## Development

```
Sources/
  StoxCore/   UI-independent logic: symbol parsing, Tencent quote and search parsing, trading hours, alerts,
              formatting, sync file format and merge rules, release info and install location (builds and tests on Linux)
  Stox/       The menu bar app: NSStatusItem + glass panel (NSPanel) + SwiftUI, Settings window, iCloud sync, updates
  StoxCLI/    The stox-cli debugging tool
Resources/             Info.plist, and English (en.lproj), Simplified Chinese (zh-Hans.lproj) and Traditional Chinese (zh-Hant.lproj) strings
Tests/StoxCoreTests/   Unit tests, using real API responses as samples
Tests/StoxTests/       macOS app tests with fake providers, a controlled clock and isolated settings/sync files
scripts/
  build-app.sh           Build, assemble and sign Stox.app (the App Store edition with STOX_FLAVOR=appstore)
  build-app-store.sh     App Store edition: sign with the sandbox and provisioning profile, package Stox-AppStore.pkg for upload
  app-store-connect.py   Fill in the App Store listing from docs/app-store/listing, pick the build, submit for review (App Store Connect API)
  make-icon.swift        Generate the app icon
  check-datasources.sh   Print raw quote API responses to spot format changes
  check-localization.py  Check that the English, Simplified Chinese and Traditional Chinese strings are complete and consistent
  ci-e2e.sh              CI end-to-end tests: launch, screenshots, iCloud sync, one-click update, the App Store edition in the sandbox
```

### Xcode project and tool version

The macOS app uses XcodeGen 2.44.1. `make project` downloads the pinned release and verifies its upstream SHA-256; tools live in `.build/tools/`, and the generated `Stox.xcodeproj` is ignored. A full Xcode installation and macOS 13 or later are required. Linux continues to test StoxCore and run stox-cli through SwiftPM without downloading XcodeGen.

`make test` runs the SwiftPM Core suite, then runs Xcode-hosted StoxTests through `scripts/test-app.sh` on macOS. The test host does not initialize real preferences, quotes, hotkeys or sync. The schemes are `Stox` and `StoxAppStore`; the latter defines `APP_STORE` and preserves the sandbox/update differences.

`make app` and `scripts/build-app-store.sh` build with Xcode before the existing icon, signing, provisioning and packaging steps. GitHub and App Store builds use separate `.build/xcode/github` and `.build/xcode/appstore` directories. Universal packages retain arm64 and x86_64. Existing environment arguments supply versions and signing credentials; the project contains no personal signing material. This migration adds no iOS, widget or Watch target.

### CI validation tiers

Every branch runs all Linux core tests, localization and offline listing checks, and all native macOS unit tests. The macOS job builds the runner architecture and runs `ci-e2e.sh quick` (eight English/Chinese panel, detail, search and settings cases) plus the complete fake-iCloud sync tests. It has a 20-minute execution limit. SwiftPM build outputs are cached by compiler version, runner architecture and manifest. Main retains the universal build, full smoke suite, update tests, live-data probes, App Store sandbox and store screenshots. Branches save diagnostic logs; screenshots are optional with `[screenshots]` in the commit message. `run_case` waits up to 20 seconds for `STOX_DIAG late ready=true`, emitted after all late panel diagnostics or settings diagnostics, and fails on timeout or early exit. The same readiness check replaces the fixed sync-panel wait. `scripts/test_ci_readiness.py` exercises this contract offline; actual macOS job duration must be checked in Actions.

### P&L calendar backfill

`ProfitHistory.backfill` consumes daily, forward-adjusted candlesticks and fills only absent market/day records. It uses the preceding trading close and share counts reversed from retained trades, skips all trade/dividend days and incomplete market totals, and limits the result to 60 completed trading days. Truncated or unknown trade logs are treated conservatively. Estimates carry `estimated`, enter normal totals, and omit historical value and cost-based P&L. Old records decode with `estimated = false`; actual closing snapshots replace estimates. `QuoteStore.backfillProfitHistory` runs once per calendar opening, requests 62 bars (including the reference close and a possible live bar), cancels writes when the panel closes, and discards results if holdings changed while awaiting data. It does not run during quote polling. Prices are forward-adjusted, so these results are estimates rather than reconstructed brokerage statements.

### Chart request lifecycle

Chart tracking uses an owner per symbol and role (including the K-line period). After each provider return, both success and error paths check cancellation, watchlist membership and current ownership. Removing a symbol invalidates its owners and clears its chart and loading caches; generations remain monotonic across remove/re-add. Reordering and filtering keep caches for current members. Native held-provider tests cover late returns, replacement, period isolation and cache admission. Providers may finish in-flight work; this does not add request deduplication, cache TTLs or a new refresh policy.

### Application unit tests

`make test` runs `StoxCoreTests` on every platform and `StoxTests` on macOS. The app tests use fake quote providers, `QuoteStoreClock`, dedicated UserDefaults suites and temporary sync folders; they never use live quote endpoints or the user's iCloud files. `SyncManager` accepts a test location and can disable file watching while exercising the same apply/push paths. Stop panel/polling tasks and disable sync before removing fixtures.

The core's `FailoverPolicy` and `TickerVisibility` keep time and visibility decisions independent of AppKit. For resources outside the main app, set `AppLanguage.bundle` before starting work; tests restore it after checking their isolated translation bundle. Localization follows the selected bundle.

### Sync session lifetime

Each sync start/enable owns a session generation. Stopping, canceling initial setup, or starting another session invalidates pending discovery, choices, debounce tasks and their results. Within a session, each file read/write also has an operation generation so older results cannot replace a newer checkpoint. Apply and error paths check ownership after awaiting IO; startup container availability can still be discovered while sync is off. `SyncFileAccess` keeps real coordinated IO as the default and lets native tests pause results after reading or committing an isolated file. Stopping does not undo a coordinated write that already began. Exit flushing and the sync document format retain their existing behavior.

Startup restoration owns a separate task from debounced pulls, so an immediate panel check cannot cancel watcher setup. Native tests use real isolated files and directory notifications to check the saved checkpoint, final sync state and subsequent external changes. App Store smoke checks wait up to the same 30 seconds for a complete default watchlist in `sync.json`; a missing write log alone does not show that the file was not committed.

### Trade fees and compatibility

`Trade.fee` is an optional nonnegative amount in the trading currency. Missing fees mean zero. Initial and additional purchases capitalize fees in cost; dividend cost uses net cash, and sell/dividend records store realized profit after fees. Daily P&L subtracts the fees for the quote's local trading date exactly once, including sold-out positions; dividend cash itself keeps the existing ex-dividend calculation.

Fee-bearing records encode `side` as `buy-fee-v1`, `sell-fee-v1`, or `dividend-fee-v1`, alongside `fee`; records without a fee keep the original labels. This is a new trade type within sync format 1. Clients with #74's preservation support (0.50.2 onward) retain fee-bearing records as opaque JSON through edits, backup and sync, so they cannot silently drop the fee field. Those clients do not display or calculate the opaque trades until upgraded. `TradeFeeSyncTests` exercise an actual legacy field/type schema and the original preservation mechanism.

### Quote invariant checks

`swift run stox-cli check` checks the reviewed A-share, Hong Kong and US sample symbols against the field counts in `Sources/StoxCore/DatasourceSnapshots`, as well as price range, previous close, A-share turnover/volume, timestamp and 52-week high. Use `--source sina` for the backup source. `--save-raw response.bin` preserves original bytes even for HTTP errors; `--raw response.bin --at 2026-10-07T10:00:00Z` replays a response without networking. Exit status is 0 for success, 1 for response differences and 2 for invalid arguments. Symbols without a reviewed schema fail explicitly.

StoxCore has no holiday calendar. The default timestamp window is ten calendar days for A shares, five for Hong Kong/US, and five minutes into the future. An unusually long exchange closure requires an explicit `--max-age-days` override (`STOX_QUOTE_MAX_AGE_DAYS` for the script). The invariant check reports these bounds; it does not claim to know the exact last holiday trading date. Review field meanings before changing snapshots.

The Linux `datasources` workflow builds the CLI, runs replay tests and both live source checks, preserves raw responses, and appends invariant differences to the existing failure issue report. `ONLY` still selects source/market probes.

### Interface languages

User-visible text is written in Chinese as `L("中文原文", arguments…)` (see `Sources/StoxCore/AppLanguage.swift`). The Chinese source is the key in the three `Resources/{en,zh-Hans,zh-Hant}.lproj/Localizable.strings` tables, which `scripts/build-app.sh` copies into the app. Arguments use `%@` placeholders, and translations can reorder them with `%1$@`, `%2$@`. When you add or change text, update all three tables and run `python3 scripts/check-localization.py` (`make test` runs it too); CI runs it on every push. To try the English interface without changing your system language:

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

`scripts/measure-footprint.sh` runs only in isolated macOS CI. It measures the packaged app with a stacked ticker, a pinned watchlist panel and sparklines, using 5-second quote polling. After confirming that quotes and sparklines are loaded, it settles for 30 seconds and samples CPU time, idle wakeups and RSS for 60 seconds. It restores the runner's previous Stox preferences on exit. Results and readiness logs are retained as `shots/footprint.*` and `shots/footprint-app.log`; network failures make the measurement unavailable rather than proving low CPU use. The result includes the whole app and live network activity, not just menu bar drawing. Never run this script on a personal account.

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

Traditional Chinese uses the same Simplified Chinese source keys, with reviewed interface terms such as 代號, 設定, 選單列, 貼上 and 匯入. `AppLanguage.securityName` uses Foundation’s Simplified–Traditional transform only at display boundaries; models and sync retain source names and codes. `Info.plist` registers zh-Hant, and InterfaceLanguage recognizes zh-Hant, Taiwan, Hong Kong and Macau choices. Linux tests verify conversion, resources and persistence; macOS native tests and the zh-TW/zh-HK launch cases verify Apple bundle selection, because Linux Foundation does not implement the same language matching. See the CI validation levels and launch-readiness contract below for the current branch launch scenarios.

### Shared release verification

Automatic releases wait for Core, the complete app launch/sync/update checks, and the App Store sandbox checks. Both release entry points pin Frit 0.4.1 to commit `2291523e16c91afae06868d7c4e188efc36cd70b`, including the `frit-ref` helper checkout. Notarization stays required. The manual release workflow's `dry_run` builds and verifies the current source without creating a tag or release. It verifies the final ZIP's full signatures, each root architecture's ticket hash and enabled Gatekeeper policy. Public archives stay unchanged; draft recovery uses the existing tag, and an incomplete public release requires a new patch version. Workflow-only changes keep the app version.

Launch readiness keeps its 20-second deadline. Batch input does not wait for single-search results that it never produces, and the nine-case branch quick suite includes the same batch query as the full suite. A failed launch saves a three-second main-thread sample before terminating and remains a failure; early/late diagnostic stages include monotonic elapsed time.

CI reads the first release heading in `CHANGELOG.md` with `scripts/candidate-version.py`, exports that marketing version to both the regular and Store builds, and checks each built Info.plist before launch tests. A malformed first heading or a mismatched bundle fails the job; the parser does not fall back to an older release heading or Git tag. This keeps version-dependent runtime checks on the candidate version.
