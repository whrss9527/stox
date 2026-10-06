## 安装

1. 下载下方附件里的 `Stox.zip`，解压后把 `Stox.app` 拖进“应用程序”文件夹。
2. 这个版本使用临时签名（没有 Apple 开发者证书），第一次打开前在终端执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/Stox.app
   ```

   也可以先双击一次，再到“系统设置 → 隐私与安全性”里点“仍要打开”。
3. 打开后 Stox 只出现在菜单栏：左键单击打开 / 关闭行情面板，右键单击在“显示行情”和“只显示图标”之间切换，⌃⌥S 在任何 App 里开关面板。设置和退出在面板底部。

已经装了 0.2.0 或更新版本的话，不用手动下载：面板底部出现“更新”时点一下，或者在设置的“关于与更新”里检查更新。`SHA256SUMS.txt` 是一键更新用来校验压缩包的。

需要 macOS 13 或更新版本，同时支持 Apple 芯片和 Intel。行情来自腾讯财经公开接口（取不到时用新浪财经），港股延时约 15 分钟，数据仅供参考。


## Installation

1. Download `Stox.zip` below, unzip it and move `Stox.app` into Applications.
2. This build uses ad-hoc signing. Before opening it for the first time, run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Stox.app
   ```

   Alternatively, try opening it once, then choose Open Anyway in System Settings → Privacy & Security.
3. Stox lives in the menu bar. Click to toggle the quotes panel, right-click to switch between quotes and the icon, or press ⌃⌥S from any app. Settings and Quit are at the bottom of the panel.

If you already have Stox 0.2.0 or later, use Update in the panel or check for updates under Settings → About & Update. `SHA256SUMS.txt` verifies the downloaded archive.

Requires macOS 13 or later; supports Apple silicon and Intel. Quotes come from Tencent Finance, with Sina Finance as a fallback. Hong Kong quotes are delayed by about 15 minutes. Data is for reference only.
