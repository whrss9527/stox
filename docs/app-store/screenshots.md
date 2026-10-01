# Screenshots

The Mac App Store accepts 1 to 10 screenshots per language, all with a 16:10 aspect ratio and exactly one of these sizes:

- 1280 × 800
- 1440 × 900
- 2560 × 1600
- 2880 × 1800

PNG or JPEG, no transparency. The first three show up on the product page, so put the strongest first.

## How they get uploaded

The `app-store` workflow uploads the English screenshots (other languages fall back to them) and skips the upload when App Store Connect already has the same files (compared by MD5):

1. If `docs/app-store/listing/screenshots/en-US/` has PNG or JPEG files, it uses those, in file name order (`1-panel.png`, `2-detail.png`, …).
2. Otherwise it uses the numbered images (`1-menu-bar.png` … `5-calendar.png`, in file name order) from the latest successful `build` run on main (below).
3. If neither is there, it leaves the screenshots on App Store Connect as they are. This is also what happens when the screenshot step of that `build` run failed: it only publishes the images when all five came out, so a half-finished set is never uploaded.

`python3 scripts/app-store-connect.py check --screenshots <folder>` checks the format, sizes and count.

## From CI (1280 × 800)

The `App Store edition (sandbox)` job in the `build` workflow runs `scripts/ci-e2e.sh appstore-shots` after the sandbox checks. It launches the sandboxed build in English five times, each with its own made-up data, and turns every capture into a 1280 × 800 image with `scripts/app-store-screenshot.swift`:

| File | Headline | Scene |
|---|---|---|
| `1-menu-bar.png` | Stocks in your menu bar | the English starter watchlist with sparklines, S&P 500 in the menu bar |
| `2-charts.png` | Charts in a click | dark appearance, Apple expanded on the daily candlestick chart |
| `3-holdings.png` | Track your holdings | three made-up US positions (costs a little below the current price), Today's P&L in the menu bar |
| `4-global.png` | Markets around the world | S&P 500, Nikkei 225, Hang Seng, SSE Composite, FTSE 100, DAX, gold, EUR/USD |
| `5-calendar.png` | Your P&L, day by day | the profit calendar for last month, from made-up daily records |

Each image has the headline and a subtitle on the left and, on the right, the real menu bar end (Stox's ticker and the clock) with the real panel hanging under it at its native size, on a dark gradient. Before each capture the desktop picture is set to the same gradient, so the panel's glass shows the same colour. A scene is retaken (up to three times) until its quotes, sparklines and charts are in. The CI screen is only 768 points tall, so the Dock is set to hide.

Download the `app-store-screenshots` artifact from the run; the images are in `shots/app-store/`. When the commit message contains `[screenshots`, 560-pixel previews of all five are also published as annotations of the job (see `scripts/ci-annotate-image.sh`), for environments that can only reach the GitHub API.

To compose one by hand:

```bash
swift scripts/app-store-screenshot.swift full.png out.png x y w h --size 1280x800 --theme 1 \
  --title "Stocks in your menu bar" --subtitle "Click to open, click again to hide."
```

`x y w h` is the last `panel_frame=` value the app prints with `--show-panel` (the panel's position and size in points). `--theme 1…5` picks the background hue. `swift scripts/app-store-screenshot.swift --wallpaper --theme 1 wallpaper.png` sets the desktop picture to that background.

## Sharper, on your own Mac (2560 × 1600 or 2880 × 1800)

CI captures at 1×. For Retina-quality images, take them on a Retina Mac with the English UI:

1. A fresh macOS user account keeps other menu bar items out of the shot.
2. Build and run the App Store edition: `ADHOC=1 UNIVERSAL=0 scripts/build-app-store.sh && open dist/appstore/Stox.app` (or install the TestFlight build).
3. Set up the scene the way `appstore_shots` in `scripts/ci-e2e.sh` does. For the sandboxed build, settings live in its container: `defaults write ~/Library/Containers/io.github.whrss9527.stox/Data/Library/Preferences/io.github.whrss9527.stox …`.
4. Launch it with the diagnostics so the frame is known: `dist/appstore/Stox.app/Contents/MacOS/Stox --show-panel --expand usAAPL` prints `STOX_DIAG panel_frame=x y w h …`.
5. `screencapture -x full.png`, then compose with `--size 2560x1600`: 2560 and 2880 wide canvases are drawn at 2×.

Put the results in `docs/app-store/listing/screenshots/en-US/` (they take precedence over the CI ones).

Use made-up holdings in screenshots, not real ones.
