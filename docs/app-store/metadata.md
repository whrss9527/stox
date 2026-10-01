# App Store metadata

The listing itself lives in [listing/](listing/), and the `app-store` workflow fills it in on App Store Connect (`scripts/app-store-connect.py sync`; see [../app-store.md](../app-store.md), in Chinese). This page only explains the choices. Don't copy listing text here; edit the files.

Everything describes the App Store edition: no self-updater, sandboxed, iCloud sync through the app's own container. `python3 scripts/app-store-connect.py check` checks the character limits below.

| What | File | Limit |
|---|---|---|
| Name | `<locale>/name.txt` | 30 characters |
| Subtitle | `<locale>/subtitle.txt` | 30 |
| Promotional text | `<locale>/promotional_text.txt` | 170 |
| Description | `<locale>/description.txt` | 4000 |
| Keywords | `<locale>/keywords.txt` | 100, comma-separated |
| Support, marketing and privacy policy URLs | `<locale>/support_url.txt`, `marketing_url.txt`, `privacy_url.txt` | https |
| What's New | `<locale>/whats_new/<version>.txt` | 4000 |
| Categories, content rights, copyright, release, availability, price, age rating | `config.json` | |

Locales: `en-US` (primary) and `zh-Hans`. The Chinese text follows the voice of README.zh-CN.md and states the same facts and limits as the English.

## Name

The name must be unique across the whole App Store, and "Stox" alone is very likely taken. The current choice is in `en-US/name.txt`. Other options, in order of preference:

- `Stox: Menu Bar Stock Ticker` [27]
- `Stox Ticker – Menu Bar Quotes` [29]
- `Stox – Stocks in Your Menu Bar` [30]

If the name is taken, the workflow only warns and keeps the current name; pick another one and change the file.

The app's own display name (under the icon, in the menu bar tooltip) stays "Stox"; only the store listing uses the longer name.

## Subtitle

Alternatives to the current one: `Glanceable stocks, one click` [28], `A shares, HK & US at a glance` [29].

## Promotional text

It can be changed without review, but the workflow only updates it together with a version that is being prepared.

## Description

Keep the last two paragraphs in every language: where the quotes come from, that Hong Kong quotes are delayed by about 15 minutes and other quotes may be delayed, that data is for reference only and not investment advice, and the open-source license. App Review asks about third-party data (guideline 5.2.2), see the risks in [../app-store.md](../app-store.md).

## Keywords

Don't repeat words that are already in the name or subtitle: Apple indexes those separately. With the name "Stox – Menu Bar Stocks", `menu bar` was replaced with `shanghai` (same length). The Chinese keywords leave out 菜单栏, 股票, 行情 and 看盘 for the same reason. Separate keywords with ASCII commas only; no spaces are needed.

## What's New

Not sent for the app's first version on the App Store (App Store Connect rejects it). For every later version:

- `en-US/whats_new/<version>.txt` is required; write it from the matching section of `CHANGELOG.md`. The workflow stops before changing anything when it is missing.
- `zh-Hans/whats_new/<version>.txt` is optional; without it the workflow uses the `## <version>` section of `CHANGELOG.md`, as plain text.

## config.json

- Categories: Finance, then Productivity (`appCategories` IDs).
- Content rights: uses third-party content (market data from Tencent Finance and Sina Finance).
- Copyright: `{year}` becomes the current year.
- Release: `AFTER_APPROVAL` releases automatically once approved; `MANUAL` waits for you to release it.
- Availability: every country and region except `excludedTerritories` (China mainland, which needs an ICP filing number; see ../app-store.md), including new ones Apple adds later.
- Price: `free` (the only value supported).
- Age rating: `none` (the only value supported): every question is answered "None" or "No", which gives 4+.

Not in the files because the API can't set them:

- App Privacy: Data Not Collected (answered once on the web).
- Export compliance: answered by `ITSAppUsesNonExemptEncryption = NO` in the App Store build's Info.plist.
