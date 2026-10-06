# 工作约定

## 待办

- 开发任务是本仓库标了 `agent` 的 issue。找任务、认领（加 `doing` 标签并评论）、卡住时怎么办，见 whrss9527/plan 的 AGENTS.md 里「用 issue 管任务的项目」一节。
- 一个 issue 一个分支、一个 PR，PR 描述写 `Closes #编号`。不要自己关闭代码 issue；合并到 main 时自动关闭。

## 构建和测试

见 [docs/development.md](docs/development.md) 和[中文版](docs/development.zh-CN.md)：构建、测试、调试启动参数、签名和发版都在那里。提交前运行 `make test`；CI 还会构建通用版、检查 App Store 沙盒版本，并在隔离环境启动应用检查同步与一键更新。

## 本仓库的约定

- 发版由 `CHANGELOG.md` 顶部的版本驱动，CI 通过后调用共用发布流程；不要手动推 main 或打标签。用户能感觉到的改动要写简短更新说明，版本号遵循现有规则；纯文档、流程和测试改动无需新版本。
- 显示给用户的文字用 `L("中文原文", 参数…)`，中英文翻译表一起更新，运行本地化检查。英文 README 和 docs 有对应的中文版，改文档时保持一致。
- 调试和测试使用开发指南里的启动参数及隔离目录，例如 `STOX_SYNC_DIR`、`STOX_UPDATE_URL`；不要让测试改动用户的持仓、偏好或真实 iCloud 同步文件。
- App Store 版与普通版的权限、同步和更新路径不同；涉及平台功能时遵守开发指南里的版本差异，并保留沙盒检查。
