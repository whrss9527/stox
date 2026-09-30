# 上架 Mac App Store

Stox 用同一份代码构建两个版本：

| | GitHub 版 | App Store 版 |
|---|---|---|
| 下载 | GitHub Releases 的 `Stox.zip` | Mac App Store |
| 构建 | `scripts/build-app.sh` | `scripts/build-app-store.sh`（`STOX_FLAVOR=appstore`，编译时 `-D APP_STORE`） |
| 签名 | Developer ID，公证 | Apple Distribution + 描述文件，打成 `.pkg` 用 Mac Installer Distribution 签名 |
| 沙盒 | 不开 | 开（`Resources/Stox-AppStore.entitlements`） |
| 更新 | 自带一键更新：检查 GitHub 发布、下载、校验、替换 | 交给 App Store；没有 Updater、更新条、“检查更新”和“自动检查更新”，也不去 GitHub 取更新内容 |
| iCloud 同步 | iCloud 云盘/Stox/sync.json | App 自己的 iCloud 容器 `iCloud.io.github.whrss9527.stox`（Documents/sync.json） |
| 其他功能 | — | 一样：菜单栏、面板、全局快捷键（Carbon `RegisterEventHotKey`，沙盒里可用）、登录时启动（`SMAppService`）、通知、备份到文件 |

App Store 版的 entitlement 只有：

- `com.apple.security.app-sandbox`：App Store 要求。
- `com.apple.security.network.client`：取行情。
- `com.apple.security.files.user-selected.read-write`：“iCloud 同步”页的“备份到文件”要弹出存储、打开面板，只读写用户选的那个文件。不开这项沙盒里弹不出面板。
- iCloud：`com.apple.developer.icloud-container-identifiers`、`ubiquity-container-identifiers`（都是 `iCloud.io.github.whrss9527.stox`）、`icloud-services = CloudDocuments`、`icloud-container-environment = Production`，以及签名必需的 `com.apple.application-identifier`、`com.apple.developer.team-identifier`（团队 ID 由脚本从描述文件里读出来填进去）。

## Bundle ID 和设置迁移

两个版本都用 `io.github.whrss9527.stox`。这是 App 在苹果那边的身份，上架后不能改，选它的理由：

- 不用再起一个名字；通知权限、登录时启动、全局快捷键都跟着同一个 ID，两个版本在系统看来是同一个 App。
- iCloud 容器的名字和 ID 对得上。

代价：

- **App Store 版第一次打开是全新的设置**。沙盒里的 App 读写的是 `~/Library/Containers/io.github.whrss9527.stox/Data/Library/Preferences/` 里的设置，读不到 GitHub 版放在 `~/Library/Preferences/io.github.whrss9527.stox.plist` 的设置。苹果提供的 `container-migration.plist` 只能“移动”旧文件，移走以后 GitHub 版就丢了设置，所以没有用它。迁移自选的办法（在 App Store 的说明里也写上）：
  1. 在 GitHub 版的设置 → iCloud 同步 → 备份到文件 → 导出；
  2. 在 App Store 版的同一页导入，选“替换本机的自选和设置”。
- **同一台 Mac 上最好只装一个版本**。两个版本 ID 一样，App Store 可能把已经装着的 GitHub 版当成“已安装”，也可能在安装时替换掉 `/Applications/Stox.app`。换成 App Store 版时先导出备份、退出并删除 GitHub 版，再从 App Store 安装。

如果以后想让两个版本在一台 Mac 上并存，要给 App Store 版换一个 ID（比如 `io.github.whrss9527.stox.mas`），同时改 `Resources/Info.plist`（构建时替换）、entitlement、iCloud 容器和本文里的 ID。上架以后就不能再换了，所以要在第一次提交前决定。

## iCloud 同步：两个版本之间

同步文件的格式两边完全一样（`SyncDocument`），位置由 `SyncLocation`（StoxCore）决定：

1. 调试用的 `STOX_SYNC_DIR`；
2. App 签名里有 iCloud 容器的 entitlement 时（App Store 版），用 `FileManager.url(forUbiquityContainerIdentifier:)` 要到的容器里的 `Documents/sync.json`。第一次要容器可能要几秒，在后台线程上做；读写都经过 `NSFileCoordinator`；
3. 签名里没有这个 entitlement 时是 iCloud 云盘/Stox/sync.json（GitHub 版，和以前一样）。有 entitlement 的 App 只用容器，容器还没要到、或者没登录 iCloud 时算作“iCloud 不可用”，不会退回 iCloud 云盘文件夹，免得两处各有一份。

所以：

- **App Store 版之间**：都用容器，正常同步。
- **GitHub 版之间**：都用 iCloud 云盘文件夹，和以前一样。
- **一台 GitHub 版、一台 App Store 版**：一个在 iCloud 云盘文件夹、一个在容器，**互相看不到**。沙盒里读不到 iCloud 云盘的其他文件夹，GitHub 版没有容器的 entitlement。用“备份到文件”搬一次，或者两台都换成同一个版本。
- 以后如果给 GitHub 版也配上这个 iCloud 容器（要用带 iCloud 能力的 Developer ID 描述文件，放进 `Stox.app/Contents/embedded.provisionprofile` 再带同样的 iCloud entitlement 签名；做之前先确认 Developer ID 描述文件支持 iCloud Documents），代码不用改，它会自动改用容器，就能和 App Store 版互相同步了；这时原来 iCloud 云盘里的文件不再更新，第一次开启同步时用“合并”把两边合在一起即可。

ad-hoc 签名（CI 的 App Store 版测试）带不了 iCloud 的 entitlement（没有描述文件的话系统不让启动），同步文件夹只能用 `STOX_SYNC_DIR` 指到容器里测试；真正的 iCloud 容器要在 TestFlight 或上架后的构建里验证，见下面的“先用 TestFlight 试一下”。

## 要你亲自做的事

下面按顺序做。前提是已经加入 Apple Developer Program（个人账号即可），并在 App Store Connect 的“协议、税务和银行业务”里签了免费 App 协议（Free Apps Agreement，默认就有；以后收费才需要付费 App 协议）。

### 1. 注册 iCloud 容器和 App ID

在 [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)：

1. Identifiers → “+” → **iCloud Containers** → 描述填 `Stox`，标识填 `iCloud.io.github.whrss9527.stox` → 注册。
2. Identifiers → “+” → **App IDs** → App → 平台选 macOS，Bundle ID 选 Explicit，填 `io.github.whrss9527.stox`，描述填 `Stox`。如果已经有这个 App ID（比如以前为 Developer ID 建过），直接编辑它。
3. Capabilities 里勾上 **iCloud**，点 Configure（或 Edit），勾选 `iCloud.io.github.whrss9527.stox`，保存。其他能力都不用勾（通知、登录时启动、快捷键不需要能力）。

### 2. 证书

在 Certificates → “+”，各建一个，都需要一个 CSR（钥匙串访问 → 证书助理 → 从证书颁发机构请求证书 → 存储到磁盘）：

1. **Apple Distribution**（给 App 签名）。
2. **Mac Installer Distribution**（给 `.pkg` 签名；装进钥匙串以后名字叫 “3rd Party Mac Developer Installer: 你的名字 (TEAMID)”）。

下载后双击装进钥匙串，然后在钥匙串访问的“我的证书”里分别右键导出成 `.p12`（带私钥），各设一个密码。

### 3. 描述文件

Profiles → “+” → Distribution 下选 **Mac App Store Connect** → App ID 选 `io.github.whrss9527.stox` → 证书选刚才的 Apple Distribution → 名字填 `Stox Mac App Store` → 下载 `.provisionprofile`。

描述文件一年后随证书过期，到时重新生成、更新 Secret。以后改了 App ID 的能力也要重新生成。

### 4. 在 App Store Connect 建 App

[App Store Connect](https://appstoreconnect.apple.com/apps) → “+” → 新建 App：

- 平台：macOS
- 名称：在整个 App Store 里必须唯一，最长 30 个字符。`Stox` 很可能已被占用，候选见 [app-store/metadata.md](app-store/metadata.md)，比如 “Stox – Menu Bar Stocks”。以后可以改，但要在提交新版本时改。
- 主要语言：English (U.S.)。之后可以再加简体中文的本地化（名称、描述、截图），英文界面合进来以后加最合适。
- 套装 ID：选 `io.github.whrss9527.stox`（第 1 步注册后才会出现）。
- SKU：`stox-macos`（只给自己看，不能改）。
- 用户访问权限：完全访问。

建好以后在 App 信息里：

- **类别**：主要类别“财务”（Finance），次要类别可以选“效率”（Productivity）。
- **内容版权**：选“是，包含第三方内容”，并确认你有权使用（行情来自腾讯财经、新浪财经的公开接口，见文末的“风险”）。
- **年龄分级**：问卷里全部选“无”，结果是 4+。
- **隐私政策网址**：`https://whrss.com/privacy/stox/`。
- 在版本页填 **支持网址** `https://whrss.com/support/`，营销网址可以填 `https://github.com/whrss9527/stox`。

### 5. 价格与销售范围

- 价格：免费（价格表选 0）。
- 销售范围：选“所有国家或地区”，然后**去掉中国大陆**。中国大陆的 App Store 要求 App 提供工业和信息化部的 ICP 备案号（2023 年起的 App 备案），没有备案号的 App 不能在中国大陆上架；另外提供证券行情的 App 在中国大陆可能还有额外的资质要求。先在其他地区上架，以后办了备案再加上中国大陆（在销售范围里勾上，并在 App 信息里填备案号）。香港、澳门、台湾不受这条限制。

### 6. 欧盟《数字服务法》（DSA）商家身份

App Store Connect → 商务（Business）→ 协议 → 数字服务法合规，声明你是不是“商家”（trader）：

- 以个人身份免费分发、不以此营利的开源项目，一般可以声明**不是商家**，App 照样在欧盟上架，不公开联系方式。
- 声明是商家的话，要提供并验证地址、电话和邮箱，这些会显示在欧盟地区的 App Store 页面上。
- 不声明的话，App 不会在欧盟 27 国上架。

这是法律判断，按你自己的情况选。

### 7. App 隐私

App 隐私 → 数据收集 → 选 **“不，我们不从此 App 中收集数据”**。理由（审核问起时可以这样答）：

- 没有账号、统计、广告、崩溃上报，不用任何第三方 SDK。
- 联网只为取行情：把自选里的证券代码（比如 `sh600519`）发给腾讯财经、新浪财经的公开行情接口，实时取回价格，不带任何能识别用户的信息。苹果对“收集”的定义不包括只为实时响应请求而发送、之后不保留的数据。
- 自选、持仓、设置都存在这台 Mac 上；开了 iCloud 同步时存在用户自己的 iCloud 里，开发者看不到。
- 日志只写在本机（沙盒容器里的 `Library/Application Support/Stox/stox.log`），不上传。

### 8. 出口合规

App Store 版的 Info.plist 里有 `ITSAppUsesNonExemptEncryption = NO`（`scripts/build-app.sh` 在 App Store 版里加上）：只用系统自带的 HTTPS，属于豁免范围，上传后不用再回答加密问题，也不用上传出口合规文件。如果以后加了自己的加密算法，要改成 YES 并按要求处理。

### 9. App Store Connect API 密钥

用户和访问 → 集成 → App Store Connect API → 团队密钥 → “+” → 名字填 `Stox GitHub Actions`，权限选 **App 管理**（App Manager）→ 生成 → 下载 `AuthKey_XXXXXXXXXX.p8`（只能下载一次）。记下 Key ID 和页面上方的 Issuer ID。

### 10. 添加 Secrets

仓库 → Settings → Secrets and variables → Actions → New repository secret，添加下面 8 个。base64 在 Mac 上用 `base64 -i 文件 | pbcopy` 复制：

| 名字 | 内容 |
|---|---|
| `APPSTORE_CERTIFICATE_P12` | Apple Distribution 的 `.p12`，base64 |
| `APPSTORE_CERTIFICATE_PASSWORD` | 它的密码 |
| `APPSTORE_INSTALLER_P12` | Mac Installer Distribution 的 `.p12`，base64 |
| `APPSTORE_INSTALLER_PASSWORD` | 它的密码 |
| `APPSTORE_PROVISIONING_PROFILE` | 第 3 步的 `.provisionprofile`，base64 |
| `ASC_KEY_ID` | API 密钥的 Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | `AuthKey_XXXXXXXXXX.p8` 的内容（直接粘贴原文，或者 base64） |

缺哪个，工作流第一步就会报出名字。

### 11. 运行上传工作流

`app-store` 工作流要先合并进 main 才能手动运行。Actions → app-store → Run workflow：

- `upload`：勾上就在校验通过后上传；不勾只构建和校验（第一次可以先不勾，看看签名和校验有没有问题）。
- `version`：留空时用最近的标签（比如 `v0.46.0` → `0.46.0`）。App Store 的每个新版本号都要比上一个上架的大。

工作流会：检查 Secrets → 跑单元测试 → 把证书导入临时钥匙串 → `scripts/build-app-store.sh`（检查描述文件的 App ID 和 iCloud 容器、编译通用版、放进描述文件、带沙盒签名、`productbuild` 打成 `dist/Stox-AppStore.pkg` 并签名）→ `xcrun altool --validate-app` → `xcrun altool --upload-app`。构建号是“提交数.运行次数”（比如 `612.3`），每次上传都会变大。`.pkg` 也作为构建产物留在这次运行里；runner 上的 Xcode 哪天没有 altool 了，工作流会直接报错，这时下载 `.pkg` 用 [Transporter](https://apps.apple.com/app/transporter/id1450874784) 上传。

在自己的 Mac 上也可以打包（证书在钥匙串里）：

```bash
APPSTORE_PROFILE=~/Downloads/Stox_Mac_App_Store.provisionprofile \
APP_SIGN_IDENTITY="Apple Distribution: 你的名字 (TEAMID)" \
INSTALLER_SIGN_IDENTITY="3rd Party Mac Developer Installer: 你的名字 (TEAMID)" \
scripts/build-app-store.sh
```

### 12. 先用 TestFlight 试一下（建议）

上传的构建处理完（通常 10～30 分钟，会收到邮件）后，在 TestFlight 里把自己加为内部测试员，用 Mac 上的 TestFlight App 安装，确认：

- 设置 → iCloud 同步能打开，另一台装了 TestFlight 版的 Mac 能收到改动（这是真正的 iCloud 容器，CI 测不到）；
- 全局快捷键、登录时启动、价格提醒的通知都正常；
- 备份到文件的导出、导入能弹出面板。

### 13. 提交审核

在 App Store Connect 的 macOS App 版本页（新建的 App 默认是 “1.0 准备提交”）：

1. 版本号：改成和上传的构建一样（比如 `0.46.0`，也就是 GitHub 版的版本号），不然选不到这个构建。两个版本的版本号保持一致最省事；如果想让 App Store 从 1.0 开始，运行工作流时在 `version` 里填 `1.0.0`，以后每次都要自己填，而且要比上一次的大。
2. 截图：至少一张 16:10 的截图（1280×800、1440×900、2560×1600 或 2880×1800），见 [app-store/screenshots.md](app-store/screenshots.md)。
3. 推广文本、描述、关键词、支持网址：从 [app-store/metadata.md](app-store/metadata.md) 复制。
4. 构建版本：点“+”选刚上传的构建。
5. App 审核信息：不需要登录，“需要登录”不勾；备注从 [app-store/review-notes.md](app-store/review-notes.md) 复制；填联系人的姓名、电话、邮箱。
6. 版本发布：选“手动发布此版本”或“自动发布”。
7. 点“添加以供审核” → “提交至 App 审核”。

审核一般一两天。被拒时在“App 审核”里看原因，回复或修改后重新提交。

### 以后发新版本

GitHub 版照常由 `CHANGELOG.md` 驱动自动发布。App Store 版在 GitHub 版发布（打了新标签）以后，手动运行一次 `app-store` 工作流，然后在 App Store Connect 里新建版本（版本号和标签一样）、填“此版本的新增内容”（可以用 CHANGELOG 里这一节的英文）、选构建、提交审核。

## CI 怎么检查 App Store 版

`build` 工作流里的 “App Store edition (sandbox)” 任务不需要证书：

- `ADHOC=1 scripts/build-app-store.sh`：ad-hoc 签名，只带沙盒、联网、用户选择的文件这三项 entitlement，打一个不签名的 `.pkg`，确认打包流程走得通；
- `scripts/ci-e2e.sh appstore`：
  - 程序里没有 `Updater`、`UpdateInstaller`、更新条、`Translocation`、`Shell` 这些类型（`nm` 检查），也没有“自动检查更新”的界面文字；
  - 启动后打印 `flavor=appstore sandboxed=true`，系统建了沙盒容器；
  - 面板打开、取到了行情（只靠 `network.client`），全局快捷键注册成功，没有检查更新；
  - 展开详情、打开设置窗口；
  - 把同步文件夹指到容器里，确认同步文件在沙盒里写得出来；
- 把面板的截图放到 1440×900 的画布上，作为 App Store 截图的样子（`app-store-screenshots` 产物）。

## 风险和待定

- **行情数据的授权**：行情来自腾讯财经、新浪财经没有公开授权条款的网页接口。App 审核指南 5.2.2 要求使用第三方服务的 App 获得授权，审核员有可能问起。审核备注里如实说明数据来源、延时和“仅供参考”；被问到时可以说明这些是公开的免费网页行情接口、不需要账号和 API Key、App 免费开源不收费。长期看，可以考虑换成有明确授权的行情源。
- **名称**：`Stox` 大概率被占用，需要选一个带副标题的名字。
- **“关于与更新”页的标题**：App Store 版里这一页只剩“关于”的内容，但标题还叫“关于与更新”。英文界面合进来以后再按版本改标题，免得和翻译的改动冲突。
- **中国大陆**：见第 5 步，需要 ICP 备案。
