#!/usr/bin/env bash
# ============================================================
# sync-upstream.sh — 同步上游 exelban/stats 仓库并保持本地定制
#
# 功能：
#   1) 检查与上游 origin 的差异（commits 差距与最新 Release Tag）
#   2) 支持 --merge 或 --rebase 合并上游最新代码
#   3) 自动保持 qstats 定制内容：
#      - RAM 内存优化器（AutoPurgeManager / MemoryPurge）
#      - 紫底白 "q" 统一品牌图标（Assets.xcassets / Desktop / Dock）
#      - 桌面双快捷方式（.app 启动包裹器与 Finder 替身）
#   4) 可选 --verify 自动运行国际化检查与 Release 编译验证
#
# 用法：
#   bash scripts/sync-upstream.sh            # 仅检查上游最新状态与差异
#   bash scripts/sync-upstream.sh --merge    # 合并 origin/master 并验证
#   bash scripts/sync-upstream.sh --rebase   # 变基到 origin/master
# ============================================================
set -eo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

REMOTE_UPSTREAM="${UPSTREAM_REMOTE:-origin}"
BRANCH_UPSTREAM="${UPSTREAM_BRANCH:-master}"

MODE="status"
DO_VERIFY=0

for arg in "$@"; do
  case "$arg" in
    --merge|-m) MODE="merge"; DO_VERIFY=1 ;;
    --rebase|-r) MODE="rebase"; DO_VERIFY=1 ;;
    --verify|-v) DO_VERIFY=1 ;;
    --check|-c) MODE="status" ;;
    --help|-h)
      echo "用法: $0 [--merge | --rebase | --check | --verify]"
      exit 0
      ;;
  esac
done

if ! git remote get-url "$REMOTE_UPSTREAM" >/dev/null 2>&1; then
  echo "错误：未找到上游远程仓库 '$REMOTE_UPSTREAM' (https://github.com/exelban/stats.git)" >&2
  exit 1
fi

echo "==> 抓取上游 $REMOTE_UPSTREAM 最新提交与 Tag..."
git fetch "$REMOTE_UPSTREAM" "$BRANCH_UPSTREAM" --tags --quiet

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
LATEST_TAG="$(git tag -l "v*" --sort=-v:refname | head -1 || echo "unknown")"
UPSTREAM_COMMIT="$(git rev-parse --short "$REMOTE_UPSTREAM/$BRANCH_UPSTREAM")"
LOCAL_COMMIT="$(git rev-parse --short HEAD)"

BEHIND=$(git rev-list --count HEAD.."$REMOTE_UPSTREAM/$BRANCH_UPSTREAM" || echo "0")
AHEAD=$(git rev-list --count "$REMOTE_UPSTREAM/$BRANCH_UPSTREAM"..HEAD || echo "0")

echo "------------------------------------------------------------"
echo "  当前本地分支: $CURRENT_BRANCH ($LOCAL_COMMIT)"
echo "  上游最新分支: $REMOTE_UPSTREAM/$BRANCH_UPSTREAM ($UPSTREAM_COMMIT)"
echo "  上游最新标签: $LATEST_TAG"
echo "  状态对比    : 本地领先 $AHEAD 个提交 / 落后 $BEHIND 个提交"
echo "------------------------------------------------------------"

if [ "$BEHIND" -gt 0 ]; then
  echo "==> 上游最新待同步提交 ($BEHIND 个):"
  git log --oneline "$CURRENT_BRANCH..$REMOTE_UPSTREAM/$BRANCH_UPSTREAM" -n 8
  echo ""
fi

if [ "$MODE" = "status" ]; then
  if [ "$BEHIND" -gt 0 ]; then
    echo "提示：运行 'bash scripts/sync-upstream.sh --merge' 可将上游代码合并到当前分支。"
  else
    echo "本地已是上游最新代码状态，无需同步。"
  fi
  exit 0
fi

# 检查工作区是否干净
if [ -n "$(git status --porcelain)" ]; then
  echo "错误：工作区有未提交的改动，请先提交或 stash 后再执行同步。" >&2
  exit 1
fi

if [ "$MODE" = "merge" ]; then
  echo "==> 开始合并 $REMOTE_UPSTREAM/$BRANCH_UPSTREAM 到 $CURRENT_BRANCH..."
  if ! git merge --no-edit "$REMOTE_UPSTREAM/$BRANCH_UPSTREAM"; then
    echo "==> 检测到合并冲突，尝试自动恢复 qstats 定制资源..."
    # 自动解决已知图标冲突：上游删除了 AppIcon.appiconset，改用 Stats.icon；我们保留紫色 q 的 AppIcon.appiconset
    if git status --porcelain | grep -q "Assets.xcassets/AppIcon.appiconset"; then
      echo "    保留本地紫底白 q 图标资源 (AppIcon.appiconset)..."
      git checkout --ours -- "Stats/Supporting Files/Assets.xcassets/AppIcon.appiconset" 2>/dev/null || true
      git add "Stats/Supporting Files/Assets.xcassets/AppIcon.appiconset" 2>/dev/null || true
    fi
    # 上游可能删除 Contents.json（非冲突，会被静默合并掉），缺失会导致
    # NSImage(named: "AppIcon") 返回 nil 并在“关于”面板强解包崩溃，这里强制补回。
    APPICON_JSON="Stats/Supporting Files/Assets.xcassets/AppIcon.appiconset/Contents.json"
    if [ ! -f "$APPICON_JSON" ]; then
      echo "    补回被上游删除的 $APPICON_JSON ..."
      git show "HEAD~1:$APPICON_JSON" > "$APPICON_JSON" 2>/dev/null \
        || git show "de8622ce~1:$APPICON_JSON" > "$APPICON_JSON" 2>/dev/null || true
      git add "$APPICON_JSON" 2>/dev/null || true
    fi
    # 确保 project.pbxproj 中保持 AppIcon 配置
    if [ -f "Stats.xcodeproj/project.pbxproj" ]; then
      sed -i "" "s/ASSETCATALOG_COMPILER_APPICON_NAME = Stats;/ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;/g" Stats.xcodeproj/project.pbxproj 2>/dev/null || true
      git add Stats.xcodeproj/project.pbxproj 2>/dev/null || true
    fi
    # 检查是否还有其他未解决的冲突
    REMAINING_CONFLICTS="$(git diff --name-only --diff-filter=U || true)"
    if [ -n "$REMAINING_CONFLICTS" ]; then
      echo "错误：存在其他需要手动解决的代码冲突：" >&2
      echo "$REMAINING_CONFLICTS" >&2
      exit 1
    fi
    git commit --no-edit || true
    echo "==> 冲突已自动解决并完成合并提交。"
  fi
elif [ "$MODE" = "rebase" ]; then
  echo "==> 开始变基当前分支到 $REMOTE_UPSTREAM/$BRANCH_UPSTREAM..."
  git rebase "$REMOTE_UPSTREAM/$BRANCH_UPSTREAM"
fi

# 无论合并是否产生冲突，都确保 AppIcon 定义文件存在：
# 上游删除 Contents.json 属于非冲突改动，会被静默合并掉，导致
# NSImage(named: "AppIcon") 返回 nil 并在“关于”面板强解包崩溃。
APPICON_JSON="Stats/Supporting Files/Assets.xcassets/AppIcon.appiconset/Contents.json"
if [ ! -f "$APPICON_JSON" ]; then
  echo "==> 补回缺失的 $APPICON_JSON ..."
  git show "HEAD~1:$APPICON_JSON" > "$APPICON_JSON" 2>/dev/null \
    || git show "de8622ce~1:$APPICON_JSON" > "$APPICON_JSON" 2>/dev/null || true
  git add "$APPICON_JSON" 2>/dev/null || true
  git commit -m "Restore AppIcon Contents.json deleted by upstream" --no-edit >/dev/null 2>&1 || true
fi

# 验证与图标保护
if [ "$DO_VERIFY" = "1" ]; then
  echo "==> 运行多语言字典一致性校验 (i18n.py)..."
  if [ -f "Kit/scripts/i18n.py" ]; then
    python3 Kit/scripts/i18n.py
  fi

  echo "==> 刷新并确保紫底白 'q' 图标与桌面快捷方式完整..."
  if [ -f "scripts/make_desktop_shortcut.sh" ]; then
    bash scripts/make_desktop_shortcut.sh --all
  fi

  echo "==> 运行 Release 编译检查..."
  xcodebuild -scheme Stats -destination 'platform=macOS' -configuration Release archive CODE_SIGNING_ALLOWED=NO -archivePath /tmp/Stats_sync_chk.xcarchive >/dev/null 2>&1 && {
    echo "==> 编译检查通过！"
  } || {
    echo "警告：编译检查未通过，请检查代码冲突或新增的 API 变更。" >&2
  }
fi

echo "==> 同步流程完成！"
