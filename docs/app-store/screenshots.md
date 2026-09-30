# Screenshots

The Mac App Store accepts 1 to 10 screenshots per language, all with a 16:10 aspect ratio and exactly one of these sizes:

- 1280 × 800
- 1440 × 900
- 2560 × 1600
- 2880 × 1800

PNG or JPEG, no transparency. The first three show up on the product page, so put the strongest first.

## From CI (1440 × 900)

The `App Store edition (sandbox)` job in the `build` workflow launches the sandboxed build, opens the panel, and turns the capture into 1440 × 900 images with `scripts/app-store-screenshot.swift` (the real panel, cropped from the menu bar down, placed on a gradient canvas). Download the `app-store-screenshots` artifact from the run; the images are in `shots/app-store/`.

The CI runner's screen is 1× and its system language is English, so the screenshots are in whatever language the UI shows on an English system. Until the English UI lands on `main` the panel is Chinese; after that, the same job produces English screenshots with no changes. To add a caption on the left:

```bash
swift scripts/app-store-screenshot.swift shots/appstore-panel-full.png out.png $frame 1440 900 "Your watchlist,\none click away"
```

(`$frame` is the last `capture_frame=` value in `shots/appstore-panel.log`.)

## Sharper, on your own Mac (2880 × 1800)

For Retina-quality images, take them on a Retina Mac with the English UI:

1. Set a clean desktop picture; a fresh macOS user account keeps other menu bar items out of the shot.
2. Build and run the App Store edition: `ADHOC=1 UNIVERSAL=0 scripts/build-app-store.sh && open dist/appstore/Stox.app` (or install the TestFlight build).
3. Open the panel, then capture it with the diagnostics so the frame is known:
   `dist/appstore/Stox.app/Contents/MacOS/Stox --show-panel --expand usAAPL` prints `STOX_DIAG capture_frame=x y w h`.
4. `screencapture -x full.png`, then
   `swift scripts/app-store-screenshot.swift full.png shot1.png x y w h 2880 1800 "Stocks in your menu bar"`.

The script scales by the canvas size (2880 is 2× of 1440), so a Retina capture stays sharp.

## Suggested set

1. Panel with the default watchlist and sparklines — "Your watchlist, one click away"
2. Expanded Apple or Moutai with the intraday chart — "Intraday, K-line and order book"
3. Holdings with totals and the profit calendar — "Track holdings and profit"
4. Menu bar with stacked tickers — "Quotes right in the menu bar"
5. Settings → iCloud Sync — "Syncs across your Macs with iCloud"

Scenes 2–4 can be set up with the same launch arguments the CI uses (see `scripts/ci-e2e.sh smoke`: `--expand`, `--chart day`, `--calendar`, and `defaults write … ticker.layout -string stacked`). For the sandboxed build, write settings into its container: `defaults write ~/Library/Containers/io.github.whrss9527.stox/Data/Library/Preferences/io.github.whrss9527.stox …`.

Use made-up holdings in screenshots, not real ones.
