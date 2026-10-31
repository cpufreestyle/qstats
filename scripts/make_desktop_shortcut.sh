#!/usr/bin/env bash
# ============================================================
# make_desktop_shortcut.sh — 生成/刷新桌面快捷方式 qstats
#
# 产物：
#   1) ~/Desktop/qstats.app   可双击启动的 .app 包裹器（统一紫底白 "q" 图标）
#   2) ~/Desktop/qstats       Finder 替身（别名）指向仓库（使用同一自定义图标）
#      macOS 不允许给符号链接写自定义图标（setxattr 返回 EPERM），故用替身
#   3) 可选同步：--sync-appiconset 更新仓库内的 AppIcon.appiconset (10 个规格 PNG)
#   4) 可选应用：--apply-app 自动调用 scripts/apply_app_icon.sh 注入已安装 Stats
#
# 幂等：旧的同名项先归档到 /tmp/qstats-desktop-archive/<时间戳>/ 再覆盖
#
# 用法：
#   bash scripts/make_desktop_shortcut.sh [--sync-appiconset] [--apply-app]
# ============================================================
set -eo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME=qstats
DESKTOP="$HOME/Desktop"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/qstats-shortcut.XXXXXX)"
ARCHIVE="/tmp/qstats-desktop-archive/$STAMP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PY_BIN="$(command -v python3 || true)"

SYNC_APPICONSET=0
APPLY_APP=0
for arg in "$@"; do
  case "$arg" in
    --sync-appiconset) SYNC_APPICONSET=1 ;;
    --apply-app) APPLY_APP=1 ;;
    --all) SYNC_APPICONSET=1; APPLY_APP=1 ;;
  esac
done

if [ -z "$PY_BIN" ] || ! "$PY_BIN" -c "import PIL" >/dev/null 2>&1; then
  echo "错误：需要带 Pillow 的 python3 来绘制图标" >&2
  exit 1
fi

cleanup() {
  if [ -n "$PY_BIN" ]; then
    "$PY_BIN" -c "import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$WORK"
  fi
}
trap cleanup EXIT
mkdir -p "$ARCHIVE"

# 已安装应用优先，与 Dock 保持同一份；可用 QSTATS_APP 覆盖
TARGET="$QSTATS_APP"
if [ -z "$TARGET" ]; then
  for cand in "/Applications/Stats.app" "$DIR/build/Debug/Stats.app" "$DIR/build/Release/Stats.app"; do
    if [ -d "$cand" ]; then TARGET="$cand"; break; fi
  done
fi
[ -n "$TARGET" ] || TARGET="$DIR/build/Debug/Stats.app"

# ---------------------------------------------------------------- 图标绘制
# 默认风格为 "q"（紫底白 q，与 App / Dock 统一），支持 ICON_STYLE=text 切换
ICON_STYLE="${ICON_STYLE:-q}"

draw_icon() {
  "$PY_BIN" - "$1" "$ICON_STYLE" <<'PY'
import sys, os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = sys.argv[1]
STYLE = sys.argv[2] if len(sys.argv) > 2 else "q"
S = 2048

if STYLE == "text":
    TOP, BOTTOM = (94, 78, 172), (26, 20, 58)
else:
    TOP, BOTTOM = (86, 72, 158), (26, 20, 58)

grad = Image.new("RGB", (S, S))
px = grad.load()
for y in range(S):
    t = y / (S - 1)
    row = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    for x in range(S):
        px[x, y] = row

radius = int(S * 0.235)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=radius, fill=255)
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
img.paste(grad, (0, 0), mask)

glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).rounded_rectangle(
    [0, 0, S - 1, S - 1], radius=radius,
    outline=(255, 255, 255, 42), width=max(2, int(S * 0.012)))
img = Image.alpha_composite(img, glow)

if STYLE == "text":
    LATIN = ["/System/Library/Fonts/Helvetica.ttc",
             "/System/Library/Fonts/Supplemental/Arial Bold.ttf"]
    CJK = ["/System/Library/Fonts/Supplemental/Songti.ttc",
           "/System/Library/Fonts/PingFang.ttc",
           "/System/Library/Fonts/STHeiti Medium.ttc",
           "/System/Library/Fonts/Hiragino Sans GB.ttc"]

    def first_usable(candidates, sample):
        for p in candidates:
            try:
                f = ImageFont.truetype(p, 40)
                f.getbbox(sample)
                return p
            except Exception:
                continue
        return None

    latin_path = first_usable(LATIN, "m")
    cjk_path = first_usable(CJK, "出品")
    if latin_path is None or cjk_path is None:
        raise SystemExit("no usable font: latin=%r cjk=%r" % (latin_path, cjk_path))

    def width_of(font, s):
        b = font.getbbox(s)
        return b[2] - b[0]

    def cap_of(font, s):
        b = font.getbbox(s)
        return b[3] - b[1]

    SAFE = S * 0.74
    LINE1 = ("michael qiu", latin_path)
    LINE2 = ("出品", cjk_path)
    GAP = int(S * 0.055)

    def fit(text, path, target_h):
        size = 20
        font = ImageFont.truetype(path, size)
        for _ in range(200):
            w = width_of(font, text)
            if w >= SAFE or cap_of(font, text) >= target_h:
                break
            size = max(size + 4, int(size * 1.06))
            font = ImageFont.truetype(path, size)
        while (width_of(font, text) > SAFE or cap_of(font, text) > target_h) and size > 8:
            size = int(size * 0.97)
            font = ImageFont.truetype(path, size)
        return font

    f1 = fit(LINE1[0], LINE1[1], int(S * 0.105))
    f2 = fit(LINE2[0], LINE2[1], int(S * 0.075))

    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    td = ImageDraw.Draw(layer)
    white = (255, 255, 255, 255)

    def draw_centered(draw, s, font, cy):
        b = font.getbbox(s)
        w, h = b[2] - b[0], b[3] - b[1]
        x = (S - w) // 2 - b[0]
        y = cy - h // 2 - b[1]
        draw.text((x, y), s, font=font, fill=white)

    h1, h2 = cap_of(f1, LINE1[0]), cap_of(f2, LINE2[0])
    block_h = h1 + GAP + h2
    top = (S - block_h) // 2
    draw_centered(td, LINE1[0], f1, top + h1 // 2)
    draw_centered(td, LINE2[0], f2, top + h1 + GAP + h2 // 2)

    rule_y = top + h1 + GAP // 2
    rule_w = int(S * 0.30)
    td.rounded_rectangle(
        [(S - rule_w) // 2, rule_y, (S + rule_w) // 2, rule_y + max(3, int(S * 0.006))],
        radius=max(2, int(S * 0.003)), fill=(255, 255, 255, 150))

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((8, 6, 20, 130), (int(S * 0.014), int(S * 0.022)), layer.split()[3])
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.016))
    img = Image.alpha_composite(img, shadow)
    img = Image.alpha_composite(img, layer)
else:
    # 统一官方 "q" 风格
    font_cands = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Geneva.ttf"
    ]
    font_path = next((p for p in font_cands if os.path.exists(p)), None)
    if not font_path:
        raise RuntimeError("未找到可用字体")

    font_size = int(S * 0.597)
    font = ImageFont.truetype(font_path, font_size)
    b = font.getbbox("q")
    gw, gh = b[2] - b[0], b[3] - b[1]
    gx = (S - gw) // 2 - b[0]
    gy = (S - gh) // 2 - b[1]

    s_offset = max(1, int(S * 0.012))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).text((gx + s_offset, gy + s_offset), "q", font=font, fill=(0, 0, 0, 110))
    img.paste(shadow, (0, 0), shadow)

    glyph = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glyph).text((gx, gy), "q", font=font, fill=(255, 255, 255, 255))
    img.paste(glyph, (0, 0), glyph)

img = img.resize((1024, 1024), Image.LANCZOS)
img.save(OUT)
PY
}

echo "==> 绘制统一图标 (风格: $ICON_STYLE)..."
draw_icon "$WORK/icon_1024.png"

# 可选：同步更新仓库内 Assets.xcassets/AppIcon.appiconset 的 10 个规格 PNG
if [ "$SYNC_APPICONSET" = "1" ]; then
  APPICONSET="$DIR/Stats/Supporting Files/Assets.xcassets/AppIcon.appiconset"
  if [ -d "$APPICONSET" ]; then
    echo "==> 同步更新 $APPICONSET 规格图片..."
    "$PY_BIN" - "$WORK/icon_1024.png" "$APPICONSET" <<'PY'
import sys, os
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
master = Image.open(src).convert("RGBA")

specs = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_256x256.png", 256),
    ("icon_256x256 1.png", 256),
    ("icon_512x512.png", 512),
    ("icon_512x512 1.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for name, sz in specs:
    out_p = os.path.join(dst, name)
    resized = master.resize((sz, sz), Image.LANCZOS)
    resized.save(out_p)
print("    已更新 10 份规格 PNG 文件")
PY
  fi
fi

ICONSET="$WORK/qstats.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$WORK/icon_1024.png" --out "$ICONSET/icon_$s"x"$s.png" >/dev/null
  dbl=$((s * 2))
  sips -z "$dbl" "$dbl" "$WORK/icon_1024.png" --out "$ICONSET/icon_$s"x"$s@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$WORK/qstats.icns"

# ---------------------------------------------------------------- 写自定义图标
set_custom_icon() {
  local target="$1"
  local icns="$WORK/qstats.icns"
  if command -v swift >/dev/null 2>&1; then
    swift - "$icns" "$target" "$DIR" <<'SWIFT'
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { exit(1) }
let icnsPath = args[1]
let targetFile = args[2]
let repoDir = args.count >= 4 ? args[3] : ""

guard let img = NSImage(contentsOfFile: icnsPath) else {
    exit(1)
}

let ws = NSWorkspace.shared
if !repoDir.isEmpty && FileManager.default.fileExists(atPath: repoDir) {
    _ = ws.setIcon(img, forFile: repoDir, options: [])
}
let ok = ws.setIcon(img, forFile: targetFile, options: [])
if ok {
    print("    自定义图标已成功写入 -> \(targetFile)")
}
SWIFT
  else
    "$PY_BIN" - "$target" "$icns" <<'PY'
import ctypes, os, subprocess, sys
target, icns = sys.argv[1], sys.argv[2]
libc = ctypes.CDLL(None, use_errno=True)
libc.getxattr.restype = ctypes.c_ssize_t
libc.setxattr.restype = ctypes.c_int

def getx(p, n):
    size = libc.getxattr(p.encode(), n.encode(), None, 0, 0, 0)
    if size < 0:
        return None
    buf = ctypes.create_string_buffer(size)
    got = libc.getxattr(p.encode(), n.encode(), buf, size, 0, 0)
    return buf.raw[:got] if got >= 0 else None

def setx(p, n, d):
    return libc.setxattr(p.encode(), n.encode(), d, len(d), 0, 0)

tmp = os.path.join("/tmp", "_qstats_icon_src.png")
subprocess.run(["sips", "-s", "format", "png", icns, "--out", tmp], capture_output=True)
subprocess.run(["sips", "-i", tmp], capture_output=True)
res = getx(tmp, "com.apple.ResourceFork")
if res:
    setx(target, "com.apple.ResourceFork", res)

info = bytearray(getx(target, "com.apple.FinderInfo") or bytes(32))
flags = int.from_bytes(info[8:10], "big") | 0x0400
info[8:10] = flags.to_bytes(2, "big")
setx(target, "com.apple.FinderInfo", bytes(info))
try:
    os.remove(tmp)
except OSError:
    pass
print("    自定义图标已写入 ->", target)
PY
  fi
}

# ---------------------------------------------------------------- .app 包裹器
APP="$WORK/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/qstats.icns" "$APP/Contents/Resources/qstats.icns"

cat > "$APP/Contents/MacOS/$APP_NAME.tmpl" <<'EOS'
#!/usr/bin/env bash
TARGET="__TARGET__"
if [ -d "$TARGET" ]; then
  /usr/bin/open "$TARGET"
  /usr/bin/osascript -e 'display notification "qstats 已启动（菜单栏）" with title "qstats"' >/dev/null 2>&1 || true
else
  /usr/bin/osascript -e 'display notification "找不到已构建的应用，请先在仓库构建 Stats" with title "qstats"' >/dev/null 2>&1 || true
fi
EOS
sed "s|__TARGET__|$TARGET|g" "$APP/Contents/MacOS/$APP_NAME.tmpl" > "$APP/Contents/MacOS/$APP_NAME"
if [ -n "$PY_BIN" ]; then
  "$PY_BIN" -c "import os, sys; os.remove(sys.argv[1]) if os.path.exists(sys.argv[1]) else None" "$APP/Contents/MacOS/$APP_NAME.tmpl"
fi
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<'EOS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>qstats</string>
  <key>CFBundleDisplayName</key><string>qstats</string>
  <key>CFBundleIdentifier</key><string>com.user.qstats.desktop</string>
  <key>CFBundleExecutable</key><string>qstats</string>
  <key>CFBundleIconFile</key><string>qstats.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOS

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 落桌：.app
DEST="$DESKTOP/$APP_NAME.app"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  mv "$DEST" "$ARCHIVE/" 2>/dev/null || true
  echo "==> 旧 .app 已归档 -> $ARCHIVE/"
fi
mv "$APP" "$DEST"

# ---------------------------------------------------------------- 落桌：仓库替身
LINK="$DESKTOP/$APP_NAME"
if [ -L "$LINK" ]; then
  mv "$LINK" "$ARCHIVE/qstats.symlink" 2>/dev/null || true
  echo "==> 旧符号链接已归档 -> $ARCHIVE/qstats.symlink"
fi
if [ ! -e "$LINK" ]; then
  osascript -e "tell application \"Finder\" to make new alias file at (POSIX file \"$DESKTOP\" as alias) to (POSIX file \"$DIR\" as alias) with properties {name:\"$APP_NAME\"}" >/dev/null 2>&1 || true
fi
if [ -e "$LINK" ]; then
  set_custom_icon "$LINK" || echo "警告：未能为 $LINK 设置图标" >&2
  touch "$LINK"
fi

touch "$DEST"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f -R -trusted "$DEST" >/dev/null 2>&1 || true
  "$LSREGISTER" -f -R -trusted "$LINK" >/dev/null 2>&1 || true
fi

echo "==> 桌面快捷方式已就绪："
echo "    $DEST  （应用包裹器，双击启动 -> $TARGET）"
echo "    $LINK  （仓库替身，同一图标）"

# 4. 可选：应用到主 App
if [ "$APPLY_APP" = "1" ] && [ -f "$DIR/scripts/apply_app_icon.sh" ]; then
  echo "==> 自动应用到主应用..."
  bash "$DIR/scripts/apply_app_icon.sh" "$TARGET"
fi
