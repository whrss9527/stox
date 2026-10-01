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

The three at the top show the expanded detail (intraday chart and average price line), daily candlesticks with moving averages, and holdings with P&L. Here, in order: the watchlist (each row with today's sparkline), an A-share order book, A-share fund flow, holdings and trades on the edit page, the P&L calendar, the A-share movers, search and add, the "No Red or Green" colors and the Settings window. The screenshots are taken automatically by CI, which launches the packaged app on macOS 15 with live quotes from 2026-09-28 and 29. They show the Chinese interface; Stox is in English when your system language isn't Chinese, and you can pick the language in Settings.

</details>

## Features

- **Quotes at a glance**: click the menu bar icon and the glass panel appears; click again, click elsewhere or press Esc and it's gone.
- **Gone in a click**: right-click and only the icon is left in the menu bar, so nobody looking over your shoulder sees your stocks.
- **Three markets**: China A-shares, Hong Kong and US stocks, plus indices, ETFs, mutual funds, international futures and FX; intraday and candlestick charts, order book and fund flow.
- **Holdings and P&L**: enter your holdings and today's and total P&L are worked out for you, with a P&L calendar.
- **Alerts when they matter**: price targets, % change, take profit and stop loss, limit up and down, new highs and lows, all as notifications.
- **Light**: about 3.6 MB zipped and about 30 MB of memory; no sign-up and no API key.
- **English or Chinese**: the interface follows your system language, or pick one in Settings → General.

## Install

Stox needs macOS 13 Ventura or later, on Apple silicon or Intel.

With [Homebrew](https://brew.sh):

```sh
brew install --cask whrss9527/tap/stox
```

Or by hand:

1. Download the latest `Stox.zip` from [Releases](https://github.com/whrss9527/stox/releases), unzip it and drag `Stox.app` into Applications.
2. Double-click to open it.
3. When there's a new version, click Update at the bottom of the panel.

How to open older ad-hoc signed versions, how to build from source and how the GitHub and App Store editions differ: see the [guide](docs/guide.md#install).

## Quick start

| Action | Result |
|---|---|
| Left-click the menu bar icon | Open / close the panel |
| Right-click the menu bar icon (or Control-click) | Switch the menu bar between quotes and icon only |
| ⌃⌥S (changeable in Settings) | Open / close the panel from any app |
| Click a row | Expand / collapse details and charts |
| ← → | When expanded, switch between 1D, 5D, daily, weekly and monthly (plus order book and fund flow for A-shares) |
| Type a symbol, a name or pinyin initials in the search box | `600519`, `腾讯`, `gzmt`, `aapl`; Return adds it |

## Docs

- [Guide](docs/guide.md): ways to install, every feature, every action and symbol format, iCloud sync, updates
- [Development](docs/development.md): project layout, command-line tools, interface languages, releases
- [Design notes](docs/DESIGN.md) (Chinese), [App Store edition](docs/app-store.md)
- [Changelog](CHANGELOG.md)

## Support

Stox is free and open source. If you like it, a ⭐ star means a lot, or you can buy me a coffee with WeChat.

<p align="center"><img src="docs/donate-wechat.png" width="240" alt="WeChat tip code: buy me a coffee"></p>

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
