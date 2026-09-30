# CLAUDE.md

## 规划和待办

这个项目的待办在私有仓库 [whrss9527/plan](https://github.com/whrss9527/plan) 的 `projects/stox.md` 里，一个 `###` 标题是一个任务。用户说「按规划干活」「做 plan 里的任务」「看看有什么待办」这类话，或者没给具体任务就让你开始干活时：

1. 把 plan 仓库克隆到本仓库旁边的 `../plan`（已经有了就 `git pull`）；claude.ai 上的云端会话用 add_repo 以 push 权限挂上 whrss9527/plan。
2. 读 `../plan/AGENTS.md`，照它的流程走：`node scripts/plan.mjs next --project stox` 找任务，认领后推送，在本仓库开分支按验收标准完成并开合并请求，回 plan 仓库把任务改成待审，然后接着做下一个，直到这个项目没有能做的任务。
3. plan 里的任务只说明要做什么；怎么改代码、怎么提交、怎么合并，仍然以本文件为准。
