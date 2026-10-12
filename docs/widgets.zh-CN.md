# 行情小组件

macOS 14 起，在桌面或通知中心的“编辑小组件”里选择 **Stox → 自选行情**。小尺寸显示一只证券，中尺寸最多显示六只。编辑组件可按顺序选择自选证券，点击证券会打开 Stox 中的对应行。

Stox 在自选或行情变化时写入本机快照，刷新时机由 WidgetKit 调度，不是实时交易终端。组件显示行情时间，并标注缓存数据；退出 Stox 后，需要重新打开主程序才能获取新行情。快照缺失或无法读取时显示打开 App 的提示。组件不会读取持仓、交易、备注或提醒设置。

主程序继续支持 macOS 13，嵌入的小组件需要 macOS 14。

## 构建与签名

XcodeGen 的两个 scheme 分别嵌入对应的 WidgetKit 扩展。`build-app.sh` 先签扩展，再签主程序，并校验整个包。共享 App Group 是 `group.io.github.whrss9527.stox.widgets`；GitHub 扩展 ID 是 `io.github.whrss9527.stox.widgets`，App Store 扩展 ID 是 `io.github.whrss9527.stox.widgets.store`。

使用同一 Apple 团队注册共享组，并为主程序和扩展启用。App Store 正式构建需要更新主程序描述文件，并通过 `WIDGET_PROVISIONING_PROFILE` 提供扩展的发行描述文件；构建会拒绝 ID 不匹配、缺少共享组或开发用途的描述文件。它与主程序的 iCloud 描述文件不同，组件本身不用 iCloud。

ad-hoc CI 只验证编译、嵌入、entitlement 和 pluginkit 发现，**不能证明正式安装后的共享组可用**。发版前安装正式签名包，等待主程序取得行情，添加两种尺寸，检查数据更新、点击证券、退出后的缓存状态，以及 App 升级后组件仍可用。共享组不可用时记录签名/注册阻碍，保留未合并 PR。

## 测试

`make test` 覆盖快照编码、私有数据不导出、配置顺序、证券删除、时效、损坏及未知版本。macOS 上运行 `scripts/check-widget-bundle.py <app> --register` 可检查嵌入包和临时 pluginkit 注册。`STOX_WIDGET_DIR` 只把主程序发布快照重定向到隔离测试目录，不覆盖扩展的正式共享容器；测试不得使用用户真实目录。
