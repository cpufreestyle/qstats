#!/usr/bin/env bash
# ============================================================
# make_desktop_shortcut.sh — 生成/刷新桌面快捷方式 qstats
#
# 产物：
#   1) ~/Desktop/qstats.app   可双击启动的 .app 包裹器（紫色 squircle + 白色 q）
#   2) ~/Desktop/qstats       Finder 替身（别名）指向仓库，使用同一图标
#      macOS 不允许给符号链接写自定义图标（setxattr 返回 EPERM），故用替身
# 幂等：旧的同名项先归档到 /tmp/qstats-desktop-archive/<时间戳>/ 再覆盖
#
# 用法：bash scripts/make_desktop_shortcut.sh
# ============================================================
set -eo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME=qstats
DESKTOP="$HOME/Desktop"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
ARCHIVE="/tmp/qstats-desktop-archive/$STAMP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

trap 'rm -rf "$WORK"' EXIT
mkdir -p "$ARCHIVE"

# 已安装应用优先，与 Dock 保持同一份；可用 QSTATS_APP 覆盖
TARGET="$QSTATS_APP"
if [ -z "$TARGET" ]; then
  for cand in "/Applications/Stats.app" "$DIR/build/Debug/Stats.app" "$DIR/build/Release/Stats.app"; do
    if [ -d "$cand" ]; then TARGET="$cand"; break; fi
  done
fi
[ -n "$TARGET" ] || TARGET="$DIR/build/Debug/Stats.app"

PY_BIN="$(command -v python3 || true)"
if [ -z "$PY_BIN" ] || ! "$PY_BIN" -c "import PIL" >/dev/null 2>&1; then
  echo "错误：需要带 Pillow 的 python3 来绘制图标" >&2
  exit 1
fi

# ---------------------------------------------------------------- 图标
draw_icon() {
  "$PY_BIN" - "$1" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = sys.argv[1]
S = 2048
TOP, BOTTOM = (94, 78, 172), (26, 20, 58)

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

# HelveticaNeue covers the CJK glyphs; the rounded Latin-only faces do not,
# so pick a font per line instead of one font for all of them.
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
img = img.resize((1024, 1024), Image.LANCZOS)
img.save(OUT)
PY
}

ICONSET="$WORK/qstats.iconset"
mkdir -p "$ICONSET"
draw_icon "$WORK/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$WORK/icon_1024.png" --out "$ICONSET/icon_$s"x"$s.png" >/dev/null
  dbl=$((s * 2))
  sips -z "$dbl" "$dbl" "$WORK/icon_1024.png" --out "$ICONSET/icon_$s"x"$s@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$WORK/qstats.icns"

# ---------------------------------------------------------------- 写自定义图标
set_custom_icon() {
  "$PY_BIN" - "$1" "$WORK/qstats.icns" <<'PY'
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
if not res:
    raise SystemExit("未能从 icns 生成图标资源")
setx(target, "com.apple.ResourceFork", res)
# Flip only kHasCustomIcon (bit 0x0400 of the UInt16 flags at offset 8).
# Overwriting the whole FinderInfo with zeros wipes the fdrp/fapa magic and
# the kIsAlias flag, so Finder stops treating the alias as an alias and hands
# it to a text editor, which then fails on "text encoding UTF-8 not applicable".
info = bytearray(getx(target, "com.apple.FinderInfo") or bytes(32))
flags = int.from_bytes(info[8:10], "little") | 0x0400
info[8:10] = flags.to_bytes(2, "little")
setx(target, "com.apple.FinderInfo", bytes(info))
try:
    os.remove(tmp)
except OSError:
    pass
print("icon ->", target)
PY
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
rm -f "$APP/Contents/MacOS/$APP_NAME.tmpl"
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
  echo "旧 .app 已归档 -> $ARCHIVE/"
fi
mv "$APP" "$DEST"

# ---------------------------------------------------------------- 落桌：仓库替身
LINK="$DESKTOP/$APP_NAME"
if [ -L "$LINK" ]; then
  mv "$LINK" "$ARCHIVE/qstats.symlink" 2>/dev/null || true
  echo "旧符号链接已归档 -> $ARCHIVE/qstats.symlink"
fi
if [ ! -e "$LINK" ]; then
  osascript -e "tell application \"Finder\" to make new alias file at (POSIX file \"$DESKTOP\" as alias) to (POSIX file \"$DIR\" as alias) with properties {name:\"$APP_NAME\"}" >/dev/null 2>&1 || true
fi
if [ -e "$LINK" ]; then
  set_custom_icon "$LINK" || echo "警告：未能为 $LINK 设置图标" >&2
  touch "$LINK"
fi

touch "$DEST"
"$LSREGISTER" -f -R -trusted "$DEST" >/dev/null 2>&1 || true
"$LSREGISTER" -f -R -trusted "$LINK" >/dev/null 2>&1 || true

echo "桌面快捷方式已就绪："
echo "  $DEST  （应用包裹器，双击启动 -> $TARGET）"
echo "  $LINK  （仓库替身，同一图标）"
echo "  重新生成：bash $DIR/scripts/make_desktop_shortcut.sh"
