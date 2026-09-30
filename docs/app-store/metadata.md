# App Store metadata (draft, English)

Copy these into App Store Connect. Character limits are Apple's; the counts in brackets were checked with `wc -m`.
Everything here describes the App Store edition: no self-updater, sandboxed, iCloud sync through the app's own container.

## Name (max 30 characters)

The name must be unique across the whole App Store. "Stox" alone is very likely taken. Options, in order of preference:

1. `Stox – Menu Bar Stocks` [22]
2. `Stox: Menu Bar Stock Ticker` [27]
3. `Stox Ticker – Menu Bar Quotes` [29]
4. `Stox – Stocks in Your Menu Bar` [30]

The app's own display name (under the icon, in the menu bar tooltip) stays "Stox"; only the store listing uses the longer name.

## Subtitle (max 30 characters)

- `Quotes one click away` [21]
- Alternatives: `Glanceable stocks, one click` [28], `A shares, HK & US at a glance` [29]

## Promotional text (max 170 characters, can be changed any time without review)

> Your watchlist lives in the menu bar: A shares, Hong Kong and US stocks, futures and FX. Click to open, click again to hide. No account, no API key. [148]

## Description (max 4000 characters)

> Stox puts stock quotes in your Mac's menu bar, compressed to one small, glanceable spot. Look up, see what moved, get back to work. When you don't want quotes on screen, right-click the icon and only a quiet icon remains.
>
> ONE CLICK TO OPEN, ONE CLICK TO HIDE
> • Left-click the menu bar icon to open the glass panel; click again, click elsewhere or press Esc to close it.
> • Right-click to switch between showing quotes and showing only the icon.
> • A global hotkey (Control-Option-S by default, configurable) opens the panel from any app. No Accessibility permission needed.
> • Pin the panel to keep it floating anywhere on screen.
>
> QUOTES IN THE MENU BAR
> • Show any stocks right in the menu bar, on one line or stacked in two rows, with red-up/green-down, green-up/red-down or no colors at all.
> • Rotate through several symbols, or show your day's profit instead.
> • Optionally show only the icon while the market is closed.
>
> MARKETS AND CHARTS
> • Shanghai, Shenzhen and Beijing A shares, Hong Kong and US stocks, major indices and ETFs, mutual funds (net asset value), international futures, precious metals and FX.
> • Search by code, name or pinyin initials; paste several codes to add them all at once.
> • Intraday, five-day, daily, weekly and monthly charts with volume and moving averages; order book, fund flow and limit prices for A shares; pre-market and after-hours prices for US stocks.
> • A-share top gainers, losers and industry rankings.
>
> HOLDINGS AND ALERTS
> • Enter shares and cost to see your position's profit, today's profit and totals per currency, converted to one number when you hold several currencies.
> • Record buys, sells and dividends; see realized profit, a profit calendar and allocation.
> • Price, percentage, take-profit and stop-loss alerts as system notifications, plus limit-up/limit-down, 52-week high/low and rapid-move alerts.
> • Hide all amounts with one click when sharing your screen.
>
> SYNC AND PRIVACY
> • Sync your watchlist, groups, holdings, alerts and display settings across your Macs through your own iCloud.
> • Export and import a backup file any time.
> • No account, no sign-up, no API key, no analytics, no ads. Your data stays on your Mac and in your iCloud.
>
> LIGHT AND NATIVE
> • Written in Swift with AppKit and SwiftUI. Small, fast and low on memory; refreshes less often when markets are closed and stops while your Mac sleeps.
> • Uses Liquid Glass on macOS 26 and a glass material on earlier versions. Requires macOS 13 or later.
>
> Quotes come from the public web quote services of Tencent Finance and Sina Finance. Hong Kong quotes are delayed by about 15 minutes, and other quotes may be delayed as well. Data is for reference only and is not investment advice.
>
> Stox is open source under the GPL-3.0 license: github.com/whrss9527/stox

## Keywords (max 100 characters, comma-separated, no spaces needed)

```
stock,ticker,quotes,menu bar,watchlist,portfolio,market,A share,hong kong,nasdaq,finance,price,alert
```

[100] Don't repeat words that are already in the name or subtitle (Apple indexes those separately); if the chosen name contains "Menu Bar" or "Stocks", replace `menu bar` with `shanghai` (same length).

## URLs

- Support URL: https://whrss.com/support/
- Privacy Policy URL: https://whrss.com/privacy/stox/
- Marketing URL (optional): https://github.com/whrss9527/stox

## Other fields

- Primary category: Finance. Secondary: Productivity.
- Copyright: `2026 whrss9527`
- Age rating: 4+ (answer "None" to every question).
- Price: Free.
- Availability: all countries and regions except China mainland (needs an ICP filing number; see docs/app-store.md).
- Content rights: contains third-party content (market data from Tencent Finance and Sina Finance).
- App Privacy: Data Not Collected.
- Export compliance: answered by `ITSAppUsesNonExemptEncryption = NO` in the App Store build's Info.plist.

## What's New (for later versions)

Take the English version of the matching section in `CHANGELOG.md`. For the first App Store release:

> First release on the Mac App Store.
