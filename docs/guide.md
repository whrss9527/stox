# Stox guide

[← Back to the README](../README.md) · [简体中文](guide.zh-CN.md)

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

See [docs/app-store.md](app-store.md) (in Chinese) for how to build and submit it.

## Features

### Panel and menu bar

- **Open and close in one click**: left-click the menu bar icon to open or close the panel; clicking outside it or pressing Esc closes it too. A global shortcut, ⌃⌥S by default and changeable in Settings, toggles it from any app.
- **Hide in one click**: right-click the menu bar icon to switch between quotes and icon only, whenever you don't want others to see your quotes.
- **Hover for pinned quotes**: hover over the menu bar item to see every pinned symbol's full name, code, price and percentage change in watchlist order, including while rotating or automatically showing only the icon after markets close. Missing quotes show `--`; manually hiding quotes keeps the hover text private too.
- **Pin as a floating window**: click the pin at the top right and the panel stays open even when you click elsewhere; drag it anywhere and it reopens there next time.
- **Menu bar quotes**: show any number of symbols in the menu bar with monospaced digits that don't jump around, on one line or on two (name on the left, price above % change in a smaller font, so more fit in the same space). Rotate through several, handy with a notch, or show just the icon while markets are closed.
- **Price colors**: red up and green down, green up and red down, or "No Red or Green", which uses the system text color everywhere for a low-key look. The panel can be set to light or dark on its own.
- **Glass design**: the panel and Settings window let the desktop show through, matching [Proxi](https://github.com/whrss9527/proxi); built with Xcode 26 and running on macOS 26, it uses the system's Liquid Glass.
- **Keyboard control**: ↑ ↓ move through search results or the watchlist, Return adds or expands, and ← → switch charts when expanded. With the global shortcut you never need the mouse.

### Quotes and charts

- **Three markets**: Shanghai, Shenzhen and Beijing A-shares, Hong Kong and US stocks, indices such as the SSE Composite, Hang Seng and Nasdaq, and ETFs. US stocks show pre-market and after-hours prices outside regular hours (you can turn this off). Add mutual funds to see each day's NAV and change and track holdings. Add international futures and precious metals such as London gold and NYMEX crude, plus FX pairs such as USD/CNY and the US Dollar Index: search "gold", "oil" or "usd" (or 黄金, 原油, 美元). They quote around the clock on weekdays and futures have today's intraday chart (FX has no chart, and neither can hold positions). Global indices such as the Nikkei 225, FTSE 100, DAX, KOSPI and Sensex come from Sina: search "nikkei" or "dax" (or 日经); they have no chart. Futures, FX and global indices share the Global filter above the list. With the English interface, names are in English where a source has them: indices (SSE Composite, S&P 500), US stocks (Apple, with the ticker AAPL in the menu bar), Hong Kong stocks (TENCENT), futures and FX (Spot Gold, EUR/USD); A-shares and mutual funds keep their Chinese names. A first launch in English starts with the S&P 500 in the menu bar and a few US indices and stocks, gold and EUR/USD.
- **Search and add**: type a code, a Chinese name or its pinyin initials (`600519`, `腾讯`, `gzmt`, `aapl`); results show the price and % change right away, and Return adds the first one. Paste several codes at once (`600519 00700 AAPL`) to add them in a batch. The sort menu at the bottom copies all your codes, which you can paste into the search field on another Mac to add them all back, and it copies your holdings table, trades and P&L history for pasting into Numbers or Excel.
- **Watchlist**: drag to reorder (also while a group is filtered), or sort by gain or loss. Put symbols into groups (right-click, Group), and filter the list by a group, A-shares, Hong Kong, US, Global or holdings. Each row draws today's sparkline next to the price (you can turn it off); switch to a compact list with one line per symbol for long watchlists. Click the colored pill on the right to switch between % change, change and market cap; prices flash briefly when they change. Click a row to expand the details: open, high, low, turnover, turnover rate, P/E, market cap and 52-week high and low, plus limit up and down prices, P/B and volume ratio for A-shares. Right-click to pin to the menu bar, set holdings and alerts, view on Xueqiu or delete.
- **Intraday and candlestick charts**: expanded, switch between 1D, 5D, daily, weekly and monthly. Candlesticks show the latest 60 forward-adjusted bars with 5, 10 and 20-period moving averages and volume; stock intraday and 5-day charts show the average price line and volume, with times or dates along the bottom. Hover to read the price, average and volume of that minute, or the open, high, low, close, volume and moving averages of that bar. A-share stocks can also switch to the order book (five bid and ask levels, bid ratio, bid−ask difference and buy and sell volume) and to fund flow (the cumulative net inflow of main funds today, minute by minute, and the net inflow of extra large, large, medium and small orders). With holdings, a cost line is drawn on the chart and recorded buys and sells are marked B and S on the candlesticks.
- **A-share movers**: "A-Share Movers…" in the sort menu lists the top 20 gainers, losers and turnover among all Shanghai, Shenzhen and Beijing A-shares, plus the SW level 1 industries with their leaders. It refreshes every 30 seconds while open and can hide new listings; click one to add it to your watchlist.
- **Automatic failover**: when Tencent's quote API is unavailable, Stox switches to Sina Finance quotes and switches back when Tencent recovers; the bottom of the panel shows "Sina quotes" meanwhile.

### Holdings and alerts

- **Trading fees**: before recording a buy, sell, or dividend, optionally enter the total commission and taxes in "Fee for this record", as an amount in the trading currency. Blank means zero. Buy fees add to cost; sell and dividend fees reduce realized profit, and fees recorded today reduce today's P&L. Trade exports include a separate Fees column.
- **Holdings and P&L**: enter the shares and cost price of each holding. The list shows the total P&L %, the details show total and today's P&L, and the top of the list totals CNY, HKD and USD separately (only for the selected group or market when filtered); with several currencies, one more row converts everything to CNY at current rates. Expand it to see each holding's share of the total value and the P&L of recent trading days (with this week and this month), open the P&L calendar to see each day by month or each month by year, or show today's or total P&L in the menu bar. After you trade, use "Record" on the edit page: buys recalculate the cost as a weighted average, sells record the profit of that trade, and dividends and bonus shares can be recorded too (diluting the cost). The total card shows this year's realized P&L, and today's trades count toward today's P&L. With "close summary" on, you get a notification with today's P&L when a market you hold closes. When sharing your screen, click the eye next to "Value" in the total to turn amounts and share counts into **** and keep only percentages, in the menu bar and notifications too.
- **Table import**: choose “Import holdings table…” from the sort menu and paste a tab-separated holdings or trade table with headers. Preview every valid row and error, then choose Merge or Replace and Import. Errors must be corrected before import; identical rows are deduplicated. Holdings imports update current quantities and costs; trade imports restore logs without replaying trades or changing holdings. Replace clears all existing holdings or known trade logs respectively, retaining the watchlist, alerts and notes. Confirmed imports save locally and sync when enabled; Cancel and Esc save nothing. Exported symbols now carry market prefixes, including funds and A shares. Start with [holdings](import-holdings.tsv) or [trades](import-trades.tsv) templates. Missing sell profit stays unknown; dividend profit defaults to net cash. More than 100 trades per symbol requires reducing records or choosing Replace.
- **Calendar estimates**: opening the P&L calendar fills missing days from the latest 60 completed trading days of daily candlesticks. Lighter cells and tooltips mark estimates, which count toward weekly, monthly and yearly totals. Existing records are kept. Trade and dividend days are skipped, and a currency total is filled only when all positions held that day have prices. Recorded trades restore historical share counts, including positions sold out later; manually entered holdings without trades are assumed held throughout the window. Exports mark estimates and leave historical value and total P&L blank, because those cannot be reliably reconstructed.
- **Notes**: write a note for each symbol, such as why you're watching it; it shows in the details and syncs through iCloud.
- **Price alerts**: get a notification when the price goes above or below a target or the % change reaches a threshold; with holdings, set take-profit and stop-loss levels on your total P&L %. You can also turn on alerts for A-shares hitting limit up or down, new 52-week highs and lows, and sudden 5-minute moves. Each condition alerts at most once per trading day, clicking the notification expands that symbol, and missed alerts are kept in "Recent Alerts". If notifications for Stox are turned off in System Settings, Settings, the edit page and the bottom of the panel say so, with one click to open System Settings. Alert prices show on the intraday and candlestick charts as brown dashed lines, with take-profit and stop-loss prices worked out from your cost and % change alerts from the previous close (intraday only).

### Sync, updates and more

- **iCloud sync and backup**: your watchlist, each symbol's alerts and short name, and settings such as refresh and colors sync between Macs through iCloud Drive; without iCloud you can export them to a file and import it on another Mac.
- **Update checks and one-click updates**: when a new version is out, an "Update" button appears at the bottom of the panel; one click downloads, verifies, replaces and relaunches. If you skipped a few versions, it lists what changed in each of them.
- **Power saving**: refreshes only once a minute while markets are closed or at lunch, recognizes holidays from the quotes, and stops requesting while the Mac sleeps.
- **More**: launch at login; Settings has its own window, opened with the gear at the bottom of the panel; the interface supports English, Simplified Chinese and Traditional Chinese, following your system language unless you choose one under Settings → General → Language (Stox relaunches to switch).
- **Traditional Chinese**: choose 繁體中文 under Settings → General → Language and relaunch, or follow a Taiwan or Hong Kong system language. Quotes, watchlist, search results and rankings display converted names such as 恆生指數 and 騰訊控股; source names and security codes remain unchanged in saved watchlists and sync.

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

The data is stored in `Stox/sync.json` in iCloud Drive (the App Store edition stores it in the app’s own iCloud container, and the two editions don’t share it). When another Mac turns on sync for the first time and iCloud already has a watchlist, you can use iCloud's, use this Mac's, or merge both. After that, changes on any Mac show up on the others within seconds. Concurrent edits to different symbols or setting fields are merged; simultaneous edits to the same symbol or field use the later document, including deletions. Update all participating Macs to 0.50.1 or later for this behavior; quitting right after a change is fine, because the next launch writes the local changes first. When syncing holdings across Macs, update all of them to 0.3.0 or later, and to 0.19.0 or later for groups; older versions drop these when they write. From 0.50.2, unrecognized security and trade types are retained in sync and backups without being shown or used in calculations; adding future types no longer requires all Macs to upgrade together.

### Updates

<img src="images/update.jpg" width="300" alt="The update bar at the bottom of the panel" align="right">

See the [changelog](../CHANGELOG.md) (in Chinese) for what changed in each version. Stox checks [GitHub Releases](https://github.com/whrss9527/stox/releases) at launch and every 6 hours after; when a new version is out, it sends a notification and an "Update" button appears at the bottom of the panel. One click downloads `Stox.zip`, verifies it against the SHA-256 published with the release, confirms it's the same app with an intact signature, replaces the app and relaunches, keeping your watchlist and settings. If you run it straight from Downloads, the new version is installed into Applications and the old copy goes to the Trash. You can turn off automatic checks on the About & Updates page.

<br clear="right">
