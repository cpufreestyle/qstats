#!/usr/bin/env bash
# ============================================================
# apply_app_icon.sh — 将自定义紫底白 "q" 图标注入到已安装的 Stats.app
#
# 背景：
#   macOS 运行中 App 在 Dock 上的图标读取自 Assets.car (CFBundleIconName)，
#   仅替换 AppIcon.icns 对 Dock 无效。且 Stats 自身检查更新时会覆盖回官方波形图标。
#   本脚本一键编译/提取仓库中的紫底白 q 图标（Assets.car + AppIcon.icns），
#   写入目标 Stats.app，重新 ad-hoc 签名，清理 Dock 缓存并重启 Dock。
#
# 用法：
#   bash scripts/apply_app_icon.sh [/path/to/Stats.app]
#
# 环境变量：
#   QSTATS_APP: 目标 App 路径（默认 /Applications/Stats.app）
#   SKIP_DOCK_RESTART: 设为 1 则不重启 Dock
# ============================================================
set -eo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-${QSTATS_APP:-/Applications/Stats.app}}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PY_BIN="$(command -v python3 || true)"

if [ ! -d "$TARGET" ]; then
  echo "错误：未找到目标应用: $TARGET" >&2
  exit 1
fi

RESOURCES="$TARGET/Contents/Resources"
if [ ! -d "$RESOURCES" ]; then
  echo "错误：目标不是合法的 macOS App Bundle: $TARGET" >&2
  exit 1
fi

WORK="$(mktemp -d /tmp/qstats-apply-icon.XXXXXX)"
cleanup() {
  if [ -n "$PY_BIN" ]; then
    "$PY_BIN" -c "import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$WORK"
  fi
}
trap cleanup EXIT

echo "==> 目标应用: $TARGET"

# 1. 获取 Assets.car 与 AppIcon.icns
ASSETS_CAR=""
APPICON_ICNS=""

XCASSETS="$DIR/Stats/Supporting Files/Assets.xcassets"
if command -v xcrun >/dev/null 2>&1 && [ -d "$XCASSETS" ]; then
  echo "==> 使用 actool 编译仓库中的 Assets.xcassets..."
  mkdir -p "$WORK/actool_out"
  if xcrun actool --compile "$WORK/actool_out" "$XCASSETS"       --platform macosx --minimum-deployment-target 12.0       --app-icon AppIcon --output-partial-info-plist "$WORK/actool_out/partial.plist" >/dev/null 2>&1; then
    if [ -f "$WORK/actool_out/Assets.car" ] && [ -f "$WORK/actool_out/AppIcon.icns" ]; then
      ASSETS_CAR="$WORK/actool_out/Assets.car"
      APPICON_ICNS="$WORK/actool_out/AppIcon.icns"
    fi
  fi
fi

# 回退机制：若 actool 未能生成，尝试寻找既有构建产物
if [ -z "$ASSETS_CAR" ] || [ -z "$APPICON_ICNS" ]; then
  for cand in     "$DIR/build/Build/Products/Debug/Stats.app/Contents/Resources"     "$DIR/build/Debug/Stats.app/Contents/Resources"     "$DIR/build/Release/Stats.app/Contents/Resources"     "/tmp/qstats-newicon-dd/Build/Intermediates.noindex/ArchiveIntermediates/Stats/IntermediateBuildFilesPath/Stats.build/Release/Stats.build/assetcatalog_output/thinned"; do
    if [ -f "$cand/Assets.car" ] && [ -f "$cand/AppIcon.icns" ]; then
      ASSETS_CAR="$cand/Assets.car"
      APPICON_ICNS="$cand/AppIcon.icns"
      echo "==> 使用既有构建产物: $cand"
      break
    fi
  done
fi

if [ -z "$ASSETS_CAR" ] || [ -z "$APPICON_ICNS" ]; then
  echo "错误：未能获取 Assets.car 或 AppIcon.icns，请先构建或确保 Assets.xcassets 完整" >&2
  exit 1
fi

# 2. 备份原图标（仅当首次运行且存在时）
BACKUP_DIR="/tmp/qstats-icon-backup"
mkdir -p "$BACKUP_DIR"
if [ ! -f "$BACKUP_DIR/Assets.orig.car" ] && [ -f "$RESOURCES/Assets.car" ]; then
  cp "$RESOURCES/Assets.car" "$BACKUP_DIR/Assets.orig.car"
fi
if [ ! -f "$BACKUP_DIR/AppIcon.orig.icns" ] && [ -f "$RESOURCES/AppIcon.icns" ]; then
  cp "$RESOURCES/AppIcon.icns" "$BACKUP_DIR/AppIcon.orig.icns"
fi

# 3. 复制新图标资源
echo "==> 写入 Assets.car 与 AppIcon.icns..."
cp "$ASSETS_CAR" "$RESOURCES/Assets.car"
cp "$APPICON_ICNS" "$RESOURCES/AppIcon.icns"

# 4. Ad-hoc 重新签名
echo "==> 重新 ad-hoc 代码签名..."
codesign --force --deep --sign - "$TARGET" >/dev/null 2>&1 || {
  echo "警告：codesign 签名失败，可能需要提权或手动签名" >&2
}

touch "$TARGET"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f -R -trusted "$TARGET" >/dev/null 2>&1 || true
fi

# 5. 清理 Dock 缓存并重启 Dock
if [ "${SKIP_DOCK_RESTART:-0}" != "1" ]; then
  echo "==> 清理 Dock 图标缓存..."
  if [ -n "$PY_BIN" ]; then
    "$PY_BIN" -c "
import glob, os
for p in glob.glob('/private/var/folders/*/*/*/com.apple.dock.iconcache'):
    try:
        os.remove(p)
        print('    已清除:', p)
    except OSError:
        pass
"
  fi
  echo "==> 重启 Dock..."
  killall -9 Dock 2>/dev/null || true
fi

echo "==> 完成！已成功将统一紫底白 'q' 图标应用到: $TARGET"
