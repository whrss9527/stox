<div align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Stox icon">
  <h1>Stox</h1>
  <p><strong>Quotes at a glance, gone in a click</strong></p>
  <p>Stock quotes that live in the macOS menu bar. Native Swift, glass design, free and open source.</p>
  <p>
    <a href="https://github.com/whrss9527/stox/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/whrss9527/stox?include_prereleases&label=release&color=FA4D45"></a>
    <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-111827?logo=apple&logoColor=white">
    <img alt="Liquid Glass" src="https://img.shields.io/badge/UI-Liquid%20Glass-7C6CFF">
    <a href="LICENSE"><img alt="GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-2563EB"></a>
  </p>
  <p>
    <a href="https://github.com/whrss9527/stox/releases/latest"><b>Download</b></a> ·
    <a href="CHANGELOG.md">Changelog</a> ·
    <a href="docs/DESIGN.md">Design notes</a> ·
    <a href="README.zh-CN.md">简体中文</a>
  </p>
</div>

### **Stox** /stɒks/

Say it out loud and it's **stocks**.

Six letters squeezed into four, and it still sounds the same.

The quotes get the same treatment: squeezed into one small spot in the menu bar. Glance up and you know what happened; when you don't want to be disturbed, one right-click leaves just a quiet icon.

**Stox** is stock quotes compressed to the minimum, but always within reach.

<p align="center">
  <img src="docs/images/detail.jpg" width="32%" alt="Expanded detail: intraday chart and average price line">
  <img src="docs/images/kline.jpg" width="32%" alt="Daily candlesticks with moving averages">
  <img src="docs/images/holdings.jpg" width="32%" alt="Holdings and P&L">
</p>

<details>
<summary><b>More screenshots</b></summary>

<p>
  <img src="docs/images/panel.jpg" width="300" alt="Watchlist with intraday sparklines">
  <img src="docs/images/orderbook.jpg" width="300" alt="Order book">
</p>
<p>
  <img src="docs/images/fundflow.jpg" width="300" alt="Fund flow">
  <img src="docs/images/editor.jpg" width="300" alt="Holdings, trades and dividends">
</p>
<p>
  <img src="docs/images/calendar.jpg" width="300" alt="P&L calendar">
  <img src="docs/images/rank.jpg" width="300" alt="A-share movers">
</p>
<p>
  <img src="docs/images/search.jpg" width="300" alt="Search and add">
  <img src="docs/images/neutral.jpg" width="300" alt="No red or green">
</p>
<p>
  <img src="docs/images/settings.jpg" width="604" alt="Settings window">
</p>

The three at the top show the expanded detail (intraday chart and average price line), daily candlesticks with moving averages, and holdings with P&L. Here, in order: the watchlist (each row with today's sparkline), an A-share order book, A-share fund flow, holdings and trades on the edit page, the P&L calendar, the A-share movers, search and add, the "No Red or Green" colors and the Settings window. The screenshots are taken automatically by CI, which launches the packaged app on macOS 15 with live quotes from 2026-09-28 and 29. They show the Chinese interface; Stox switches to English when your system language is English.

</details>

## Highlights

- **Quotes at a glance**: click the menu bar icon and the glass panel appears; click again, click elsewhere or press Esc and it's gone.
- **Gone in a click**: right-click and only the icon is left in the menu bar, so nobody looking over your shoulder sees your stocks.
- **Three markets**: China A-shares, Hong Kong and US stocks, plus indices, ETFs, mutual funds, international futures and FX; intraday and candlestick charts, order book and fund flow.
- **Holdings and P&L**: enter your holdings and today's and total P&L are worked out for you, with a P&L calendar.
- **Alerts when they matter**: price targets, % change, take profit and stop loss, limit up and down, new highs and lows, all as notifications.
- **Light**: about 3.6 MB zipped and about 30 MB of memory; no sign-up and no API key.
- **English or Chinese**: the interface follows your system language.

## Install

Requires macOS 13 Ventura or later, on Apple silicon or Intel.

### Option 1: download the app

1. Download the latest `Stox.zip` from [Releases](https://github.com/whrss9527/stox/releases). To try the latest unreleased code, download `Stox-app` from the most recent successful build on the [Actions](https://github.com/whrss9527/stox/actions/workflows/build.yml) page.
2. Unzip it and drag `Stox.app` into Applications.
3. Versions whose release notes say they are signed with a Developer ID and notarized by Apple open with a double-click. Earlier versions are ad-hoc signed and blocked on first launch; allow them either way:
   - run `xattr -dr com.apple.quarantine /Applications/Stox.app` in Terminal, then open it normally;
   - or double-click it once, then click "Open Anyway" in System Settings → Privacy & Security.
4. No need to download new versions by hand: Stox checks every 6 hours, and when there's a new version you click "Update" at the bottom of the panel. You can also check manually under About & Updates in Settings.

Upgrading from 0.1.0 to 0.2.0 takes one manual download; one-click updates work from 0.2.0 on.

### Option 2: build from source

Requires Xcode 16 or later.

```bash
git clone https://github.com/whrss9527/stox.git
cd stox
make install      # build, package Stox.app, copy it to Applications and launch it
```

Other commands:

```bash
make run          # only package to dist/Stox.app and run it
make test         # run the unit tests
UNIVERSAL=1 make app   # package a universal build for Apple silicon and Intel
```

An app you build yourself is not blocked by Gatekeeper.

### GitHub edition and App Store edition

The same code builds two editions with the same features. They differ in how they are distributed and updated:

- **GitHub edition** (the two options above): signed with Developer ID and notarized, with one-click updates. iCloud sync keeps its file in the `Stox` folder in iCloud Drive.
- **App Store edition** (coming soon): runs in the sandbox and is updated by the App Store, so it has no one-click update or “Check for Updates”. iCloud sync keeps its file in the app’s own iCloud container. It starts with fresh settings; to move over from the GitHub edition, use “Back Up to a File” on the iCloud Sync page of Settings, then “Import Backup” in the App Store edition. The two editions don’t see each other’s iCloud sync, so install only one of them on a Mac.

See [docs/app-store.md](docs/app-store.md) (in Chinese) for how to build and submit it.

## Features

### Panel and menu bar

- **Open and close in one click**: left-click the menu bar icon to open or close the panel; clicking outside it or pressing Esc closes it too. A global shortcut, ⌃⌥S by default and changeable in Settings, toggles it from any app.
- **Hide in one click**: right-click the menu bar icon to switch between quotes and icon only, whenever you don't want others to see your quotes.
- **Pin as a floating window**: click the pin at the top right and the panel stays open even when you click elsewhere; drag it anywhere and it reopens there next time.
- **Menu bar quotes**: show any number of symbols in the menu bar with monospaced digits that don't jump around, on one line or on two (name on the left, price above % change in a smaller font, so more fit in the same space). Rotate through several, handy with a notch, or show just the icon while markets are closed.
- **Price colors**: red up and green down, green up and red down, or "No Red or Green", which uses the system text color everywhere for a low-key look. The panel can be set to light or dark on its own.
- **Glass design**: the panel and Settings window let the desktop show through, matching [Proxi](https://github.com/whrss9527/proxi); built with Xcode 26 and running on macOS 26, it uses the system's Liquid Glass.
- **Keyboard control**: ↑ ↓ move through search results or the watchlist, Return adds or expands, and ← → switch charts when expanded. With the global shortcut you never need the mouse.

### Quotes and charts

- **Three markets**: Shanghai, Shenzhen and Beijing A-shares, Hong Kong and US stocks, indices such as the SSE Composite, Hang Seng and Nasdaq, and ETFs. US stocks show pre-market and after-hours prices outside regular hours (you can turn this off). Add mutual funds to see each day's NAV and change and track holdings. Add international futures and precious metals such as London gold and NYMEX crude, plus FX pairs such as USD/CNY and the US Dollar Index: search "gold", "oil" or "usd" (or 黄金, 原油, 美元). They quote around the clock on weekdays and futures have today's intraday chart (FX has no chart, and neither can hold positions).
- **Search and add**: type a code, a Chinese name or its pinyin initials (`600519`, `腾讯`, `gzmt`, `aapl`); results show the price and % change right away, and Return adds the first one. Paste several codes at once (`600519 00700 AAPL`) to add them in a batch. The sort menu at the bottom copies all your codes, which you can paste into the search field on another Mac to add them all back, and it copies your holdings table, trades and P&L history for pasting into Numbers or Excel.
- **Watchlist**: drag to reorder (also while a group is filtered), or sort by gain or loss. Put symbols into groups (right-click, Group), and filter the list by a group, A-shares, Hong Kong, US or holdings. Each row draws today's sparkline next to the price (you can turn it off); switch to a compact list with one line per symbol for long watchlists. Click the colored pill on the right to switch between % change, change and market cap; prices flash briefly when they change. Click a row to expand the details: open, high, low, turnover, turnover rate, P/E, market cap and 52-week high and low, plus limit up and down prices, P/B and volume ratio for A-shares. Right-click to pin to the menu bar, set holdings and alerts, view on Xueqiu or delete.
- **Intraday and candlestick charts**: expanded, switch between 1D, 5D, daily, weekly and monthly. Candlesticks show the latest 60 forward-adjusted bars with 5, 10 and 20-period moving averages and volume; stock intraday and 5-day charts show the average price line and volume, with times or dates along the bottom. Hover to read the price, average and volume of that minute, or the open, high, low, close, volume and moving averages of that bar. A-share stocks can also switch to the order book (five bid and ask levels, bid ratio, bid−ask difference and buy and sell volume) and to fund flow (the cumulative net inflow of main funds today, minute by minute, and the net inflow of extra large, large, medium and small orders). With holdings, a cost line is drawn on the chart and recorded buys and sells are marked B and S on the candlesticks.
- **A-share movers**: "A-Share Movers…" in the sort menu lists the top 20 gainers, losers and turnover among all Shanghai, Shenzhen and Beijing A-shares, plus the SW level 1 industries with their leaders. It refreshes every 30 seconds while open and can hide new listings; click one to add it to your watchlist.
- **Automatic failover**: when Tencent's quote API is unavailable, Stox switches to Sina Finance quotes and switches back when Tencent recovers; the bottom of the panel shows "Sina quotes" meanwhile.

### Holdings and alerts

- **Holdings and P&L**: enter the shares and cost price of each holding. The list shows the total P&L %, the details show total and today's P&L, and the top of the list totals CNY, HKD and USD separately (only for the selected group or market when filtered); with several currencies, one more row converts everything to CNY at current rates. Expand it to see each holding's share of the total value and the P&L of recent trading days (with this week and this month), open the P&L calendar to see each day by month or each month by year, or show today's or total P&L in the menu bar. After you trade, use "Record" on the edit page: buys recalculate the cost as a weighted average, sells record the profit of that trade, and dividends and bonus shares can be recorded too (diluting the cost). The total card shows this year's realized P&L, and today's trades count toward today's P&L. With "close summary" on, you get a notification with today's P&L when a market you hold closes. When sharing your screen, click the eye next to "Value" in the total to turn amounts and share counts into **** and keep only percentages, in the menu bar and notifications too.
- **Notes**: write a note for each symbol, such as why you're watching it; it shows in the details and syncs through iCloud.
- **Price alerts**: get a notification when the price goes above or below a target or the % change reaches a threshold; with holdings, set take-profit and stop-loss levels on your total P&L %. You can also turn on alerts for A-shares hitting limit up or down, new 52-week highs and lows, and sudden 5-minute moves. Each condition alerts at most once per trading day, clicking the notification expands that symbol, and missed alerts are kept in "Recent Alerts".

### Sync, updates and more

- **iCloud sync and backup**: your watchlist, each symbol's alerts and short name, and settings such as refresh and colors sync between Macs through iCloud Drive; without iCloud you can export them to a file and import it on another Mac.
- **Update checks and one-click updates**: when a new version is out, an "Update" button appears at the bottom of the panel; one click downloads, verifies, replaces and relaunches. If you skipped a few versions, it lists what changed in each of them.
- **Power saving**: refreshes only once a minute while markets are closed or at lunch, recognizes holidays from the quotes, and stops requesting while the Mac sleeps.
- **More**: launch at login; Settings has its own window, opened with the gear at the bottom of the panel; the interface is in English or Simplified Chinese, following your system language.

Quotes come from Tencent Finance's public API (Sina Finance as a fallback): free, with no sign-up or API key. Hong Kong quotes are delayed by about 15 minutes. The data is for reference only and is not investment advice. Stock names come from the quote API and are shown in Chinese; the changelog and release notes are written in Chinese.

## Usage

| Action | Result |
|---|---|
| Left-click the menu bar icon | Open / close the panel |
| Right-click the menu bar icon (or Control-click) | Switch the menu bar between quotes and icon only |
| ⌃⌥S (changeable in Settings) | Open / close the panel from any app |
| Esc | Clear the search → back to the list → close the panel |
| Gear / power button at the bottom of the panel | Open Settings / quit Stox |
| Click a row | Expand / collapse details and charts |
| ↑ ↓ | Select a search result while searching, otherwise a row in the watchlist |
| Return | Add the selected search result (the first one if none is selected); expand / collapse the selected row |
| ← → | When expanded, switch between 1D, 5D, daily, weekly and monthly (plus order book and fund flow for A-shares) |
| Drag a row | Reorder |
| Right-click a row | Show in menu bar, holdings, alerts and short name, view on Xueqiu, copy symbol, delete |
| Click the pill on the right of a row | Switch between % change, change and market cap |
| Sort button at the bottom of the panel | Custom order, top gainers, top losers or highest total P&L first; what the pill shows; copy symbols, holdings table, trades and P&L history; new group; recent alerts; P&L calendar; A-share movers |
| ⌘R / ⌘, / ⌘Q | While the panel is open: refresh / Settings / quit |

The search field also takes codes directly. Separate several codes with spaces, commas or new lines and they're listed; press Return to check their quotes once and add all that exist to your watchlist:

| Input | Recognized as |
|---|---|
| `600519`, `sh600519`, `600519.SS` | Shanghai: Kweichow Moutai |
| `000001`, `000001.SZ` | Shenzhen: Ping An Bank (for the SSE Composite, enter `sh000001`) |
| `920819`, `bj920819` | Beijing Stock Exchange |
| `700`, `00700`, `0700.HK` | Hong Kong: Tencent |
| `hkHSI` | Hang Seng Index |
| `AAPL`, `brk.b` | US stocks |
| `us.IXIC`, `us.DJI`, `us.INX` | Nasdaq, Dow Jones, S&P 500 |

### iCloud sync

Turn on the switch on the iCloud Sync page of Settings; iCloud Drive must be on for this Mac. What syncs: the watchlist (order, menu bar pins, short names, holdings, price alerts, groups) and the refresh interval, menu bar content, price colors and alert switches. Settings that only concern this Mac, such as icon only, panel appearance, keyboard shortcut and launch at login, don't sync.

The data is stored in `Stox/sync.json` in iCloud Drive (the App Store edition stores it in the app’s own iCloud container, and the two editions don’t share it). When another Mac turns on sync for the first time and iCloud already has a watchlist, you can use iCloud's, use this Mac's, or merge both. After that, changes on any Mac show up on the others within seconds; quitting right after a change is fine, because the next launch writes the local changes first. When syncing holdings across Macs, update all of them to 0.3.0 or later, and to 0.19.0 or later for groups; older versions drop these when they write.

### Updates

<img src="docs/images/update.jpg" width="300" alt="The update bar at the bottom of the panel" align="right">

See the [changelog](CHANGELOG.md) (in Chinese) for what changed in each version. Stox checks [GitHub Releases](https://github.com/whrss9527/stox/releases) at launch and every 6 hours after; when a new version is out, it sends a notification and an "Update" button appears at the bottom of the panel. One click downloads `Stox.zip`, verifies it against the SHA-256 published with the release, confirms it's the same app with an intact signature, replaces the app and relaunches, keeping your watchlist and settings. If you run it straight from Downloads, the new version is installed into Applications and the old copy goes to the Trash. You can turn off automatic checks on the About & Updates page.

<br clear="right">

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

The App Store edition is not released automatically. After a GitHub release, run the app-store workflow by hand on the Actions page to build, sign and upload it to App Store Connect, then submit it for review there; see [docs/app-store.md](docs/app-store.md) (in Chinese).

See [docs/DESIGN.md](docs/DESIGN.md) (in Chinese) for the design decisions.

## License

Copyright © 2026 whrss9527

Stox is free software, released under the [GNU General Public License v3.0 (GPL-3.0)](LICENSE): you may use, study, modify and share it freely; if you distribute Stox or a modified version, you must provide the source code under the same license.

The name "Stox" and the Stox icon are not licensed under the GPL (GPL-3.0 section 7(e)). You may use them to talk about Stox and to share unmodified copies; if you distribute a modified version, please use your own name and icon.

Contributions are subject to the contributor agreement in [CONTRIBUTING.md](CONTRIBUTING.md).

---

<div align="center">
  <p><b>Also living in the menu bar</b></p>
  <a href="https://github.com/whrss9527/pop"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/pop.svg" width="30%" alt="Pop: long-press right-click, one swipe away"></a>
  <a href="https://github.com/whrss9527/meno"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/meno.svg" width="30%" alt="Meno: a calm menu bar, made with glass"></a>
  <a href="https://github.com/whrss9527/proxi"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/proxi.svg" width="30%" alt="Proxi: one switch for all your proxies"></a>
</div>
