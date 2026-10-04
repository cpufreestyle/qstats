# Handoff — Stats 项目

**迁移时间**：2026-09-26
**源目录**：`/Users/a1-6/CodeBuddy/20260823202752/stats`（仍保留，未删除）
**目标目录**：`/Users/a1-6/AI Shared/repo/stats`

---

## 仓库状态

| 项 | 值 |
|---|---|
| 当前分支 | `feat/ram-memory-optimizer` |
| 最新 commit | `c05db810` — feat(RAM): add memory optimizer with auto-purge and manual reclaim |
| 基线 | `b4b5b1c9` (lang: improved Turkish localization #3559) — origin/master |
| 远程 | `origin → https://github.com/exelban/stats.git` |
| 领先 master | 1 个 commit（未推送） |

## 复制内容

- **82 MB / 349 个文件**：`.git` 历史 60 MB + 源码约 22 MB
- **排除**：`build/`（806 MB Xcode 构建产物）、`.qoder/`（工具缓存）

## 待办事项

### 1. 推送 `feat/ram-memory-optimizer` 并创建 PR（阻塞中）

上次会话尝试推送时 **GitHub 网络不可达**（HTTPS `SSL_ERROR_SYSCALL` / SSH `Connection closed` / GitHub MCP 也返回 `fetch failed`）。恢复网络后：

```bash
cd "/Users/a1-6/AI Shared/repo/stats"
git push -u origin feat/ram-memory-optimizer
gh pr create --base master --head feat/ram-memory-optimizer \
  --title "feat(RAM): add memory optimizer with auto-purge and manual reclaim"
```

CI 会自动触发 [build.yaml](.github/workflows/build.yaml) 和 [linter.yaml](.github/workflows/linter.yaml)（两者都配置了 `pull_request: master`）。

### 2. 工作树里有 4 处未提交改动，与 RAM 功能无关

`git status` 显示：

```
 M Stats/Supporting Files/Info.plist
 M Stats/Supporting Files/Stats/en.xcloc/Source Contents/Stats/Supporting Files/en.lproj/InfoPlist.strings
 M Stats/Views/AppSettings.swift
 M Stats/Views/Update.swift
?? AGENTS.md
```

四处 diff 都是一致的字符串替换 **`Stats` → `qstats`**（应用重命名 WIP，与本次内存优化器功能无关）。请按你自己的节奏决定：
- 独立分支重做（推荐，语义清晰）
- 或 stash 丢弃

`AGENTS.md` 是本仓库文档，未被 `.gitignore` 排除；是否提交由你定。

## RAM 功能提交内容

commit `c05db810` 涉及 6 个文件：

| 文件 | 类型 | 作用 |
|---|---|---|
| `Modules/RAM/AutoPurgeManager.swift` | 新增 | 后台调度：按阈值/间隔触发回收；`runOnce` 供 popup 用 |
| `Modules/RAM/MemoryPurge.swift` | 新增 | 无 root 内存回收：分配-释放大块内存；可选 `sudo purge` 分支 |
| `Modules/RAM/main.swift` | 修改 | 启动时读取 `RAM_autoPurge*` 配置自动 `start()` |
| `Modules/RAM/popup.swift` | 修改 | 新增 "Optimize now" 按钮 + 状态标签 |
| `Modules/RAM/settings.swift` | 修改 | 新增内存优化器设置分区：开关、阈值滑条、间隔下拉、系统 purge 开关 |
| `Stats.xcodeproj/project.pbxproj` | 修改 | 注册两个新 Swift 文件到 RAM target Sources |

## 本地验证命令

参考项目 [AGENTS.md](AGENTS.md)：

```bash
cd "/Users/a1-6/AI Shared/repo/stats"
swiftlint                                                              # 无新增告警
python3 Kit/scripts/i18n.py                                            # 若改了 .strings
xcodebuild -scheme Stats -destination 'platform=macOS' \
  -configuration Release archive CODE_SIGNING_ALLOWED=NO               # 编译通过
```

`build/` 已排除，首次编译需要完整时间。

## 已知环境陷阱

- **Shell `ls`/`grep` 被 zsh 函数遮蔽**（`_lc` not found）：用 `/bin/ls`、`/usr/bin/grep`、`/usr/bin/git`、`/usr/bin/rsync` 等绝对路径。
- **git commit -m 中 `$(…)` 或内层引号会触发同样问题**：改用 `git commit -F <file>`。
