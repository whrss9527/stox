# Stox 开发指南

[← 回到 README](../README.zh-CN.md) · [English](guide.md)

## 开发

```
Sources/
  StoxCore/   与界面无关的逻辑：代码解析、腾讯行情与搜索解析、交易时段、提醒、格式化、同步文件格式与合并规则、
              发布信息解析与安装位置判断（Linux 上也能编译测试）
  Stox/       菜单栏 App：NSStatusItem + 玻璃面板（NSPanel）+ SwiftUI，设置窗口、iCloud 同步、更新
  StoxCLI/    命令行调试工具 stox-cli
Resources/             Info.plist，以及界面文字的英文（en.lproj）和简体中文（zh-Hans.lproj）
Tests/StoxCoreTests/   单元测试，使用真实接口返回作为样本
scripts/
  build-app.sh         编译并组装、签名 Stox.app（STOX_FLAVOR=appstore 时是 App Store 版）
  build-app-store.sh   App Store 版：带沙盒和描述文件签名，打成上传用的 Stox-AppStore.pkg
  app-store-connect.py 把 docs/app-store/listing 里的资料填进 App Store Connect、选构建、提交审核（App Store Connect API）
  make-icon.swift      生成 App 图标
  check-datasources.sh 打印行情接口的原始返回，排查格式变化
  check-localization.py  检查英文和简体中文的翻译是否齐全、一致
  ci-e2e.sh            CI 端到端测试：启动、截图、iCloud 同步、一键更新、App Store 版在沙盒里运行
```

### 界面语言

显示给用户的文字在代码里写成 `L("中文原文", 参数…)`（见 `Sources/StoxCore/AppLanguage.swift`），中文原文就是 `Resources/en.lproj/Localizable.strings` 和 `Resources/zh-Hans.lproj/Localizable.strings` 里的键，`scripts/build-app.sh` 把它们复制进 App。参数用 `%@` 占位，译文里可以用 `%1$@`、`%2$@` 调换顺序。加文字或改文字时两种语言一起改，再跑一遍 `python3 scripts/check-localization.py`（`make test` 也会跑），CI 每次推送都会检查。不改系统语言也能看英文界面：

```bash
dist/Stox.app/Contents/MacOS/Stox --show-panel -AppleLanguages '(en)'
```

用命令行检查数据源：

```bash
swift run stox-cli quote sh600519 700 AAPL us.IXIC
swift run stox-cli search 茅台
swift run stox-cli raw hk00700
swift run stox-cli kline usAAPL week      # 最近几根 K 线（day、week、month）
swift run stox-cli book sh600519          # A 股的买卖五档和内外盘
swift run stox-cli rank gainers 10        # A 股涨跌榜（gainers、losers、turnover、industries）
swift run stox-cli sina sh600519 700 AAPL # 备用的新浪行情
swift run stox-cli latest-release 0.1.0   # GitHub 上的最新发布，以及能不能一键更新
```

调试界面时，可以让 App 启动后直接打开面板或设置窗口，并在终端打印菜单栏文字和窗口位置：

```bash
dist/Stox.app/Contents/MacOS/Stox --show-panel                    # 自选列表
dist/Stox.app/Contents/MacOS/Stox --show-panel --expand sh600519  # 展开某只证券的详情
dist/Stox.app/Contents/MacOS/Stox --show-panel --search 腾讯       # 预填搜索词
dist/Stox.app/Contents/MacOS/Stox --show-settings display         # 设置窗口：general、display、sync、about
dist/Stox.app/Contents/MacOS/Stox --check-update --show-panel     # 先检查一次更新
```

测试同步和更新时可以用环境变量换掉真实的 iCloud 云盘和 GitHub：

| 环境变量 | 作用 |
|---|---|
| `STOX_SYNC_DIR=/tmp/fake-icloud` | 同步文件放在这个文件夹，而不是 iCloud 云盘/Stox |
| `STOX_UPDATE_URL=http://127.0.0.1:8765/latest.json` | 从这里读取“最新发布”，格式同 GitHub 的 releases 接口 |
| `STOX_TEST_TRANSLOCATED=1` | 当作从只读的临时位置运行，更新会装进“应用程序” |

CI 会在 macOS 上启动打包好的 App：打开面板、详情、搜索和设置窗口并截图；用假的 iCloud 云盘文件夹测试同步；用本地的假发布把程序真正更新到 9.9.9 并确认重新启动。

### 发布新版本

发版由 `CHANGELOG.md` 驱动，用的是 [Frit](https://github.com/whrss9527/frit) 里共用的发布流程：

1. 在 `CHANGELOG.md` 最上面加一节新版本，比如 `## 0.46.0`，内容会放进发布说明，App 的“关于与更新”页显示的也是这一节；
2. 推到 main（或者合并进 main）。build 通过后，最后一步 release 发现这个版本还没有 `v0.46.0` 标签，就打包通用版 `Stox.zip`、生成校验文件 `SHA256SUMS.txt`，打上标签并发布。已安装的 Stox 下一次检查时就会提示更新。

仓库的 Secrets 里配了 Developer ID 证书和公证凭据时，发布的包会用证书签名并通过苹果公证，用户下载后双击就能打开；没配时照旧临时签名。配置方法见 Frit 的 [docs/release.md](https://github.com/whrss9527/frit/blob/main/docs/release.md)。

也可以在 Actions 页面手动运行 release：不填标签就发 `CHANGELOG.md` 最上面的版本；勾选 overwrite 可以用原标签的代码重新打包、替换附件。

App Store 版不自动发布：GitHub 版发布以后，写好英文的“此版本的新增内容”（`docs/app-store/listing/en-US/whats_new/<版本号>.txt`），在 Actions 页面手动运行 app-store：构建、签名并上传，按 `docs/app-store/listing/` 填好 App Store Connect 上的资料、选上构建，勾了 submit 时提交审核，见 [docs/app-store.md](app-store.md)。

设计取舍见 [docs/DESIGN.md](DESIGN.md)。
