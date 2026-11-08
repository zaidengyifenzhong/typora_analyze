#!/bin/bash
#
# activate.sh — 一键激活 Typora (macOS)
#
#   ./activate.sh              # 激活 /Applications/Typora.app
#   ./activate.sh --dry-run    # 只检查补丁点，不动文件
#
# 原理（两层，第一层就够用）：
#
#   第 1 层 · 二进制等长补丁 ★必需
#     Typora 把授权状态和「未激活 ×」角标的注入脚本都写死在原生二进制里。
#     把这三处字符串等长替换掉，界面就不再显示未激活，授权判定也失效。
#
#   第 2 层 · bypass.dylib ★可选
#     真正 swizzle LicenseManager.hasLicense 返回 YES，用于那些
#     不读 UI 标志的深层授权检查（导出限制等）。需要注入，步骤更复杂，
#     用 --with-dylib 开启。
#
set -euo pipefail

APP="${APP:-/Applications/Typora.app}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_REL="Contents/MacOS/Typora"
FW_REL="Contents/Frameworks"
DYLIB_REL="$FW_REL/bypass.dylib"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\n\033[36m%s\033[0m\n' "$*"; }
fail()  { red "✗ $*"; exit 1; }

MODE="apply"
WITH_DYLIB=0
for arg in "$@"; do
    case "$arg" in
        --help|-h)      echo "用法: APP=/Applications/Typora.app $0 [--dry-run] [--with-dylib]"; exit 0 ;;
        --dry-run)      MODE="dry" ;;
        --with-dylib)   WITH_DYLIB=1 ;;
        *) fail "未知参数: $arg" ;;
    esac
done

# ---------------------------------------------------------------- 前置检查
[ "$(uname -s)" = Darwin ] || fail "仅支持 macOS"
command -v python3 >/dev/null || fail "需要 Python 3.9 或更高版本"
if [ "$WITH_DYLIB" = 1 ]; then
    command -v clang >/dev/null || fail "需要 Xcode Command Line Tools"
fi
[ -d "$APP" ] || fail "未找到 $APP"
[ -f "$APP/$BIN_REL" ] || fail "未找到主二进制"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')

blue "Typora $VERSION ($BUILD)"
echo "  路径: $APP"
echo "  签名: ${TEAM:-未知}"

# ---------------------------------------------------------------- 预检
blue "[1/3] 补丁点预检"
python3 "$SELF/src/patcher.py" --verify "$APP/$BIN_REL" || fail "补丁点检查失败（版本不匹配或已打过补丁）"

if [ "$MODE" = "dry" ]; then
    green "\n✓ dry-run 结束，未修改任何文件"
    exit 0
fi

# ---------------------------------------------------------------- 停进程
osascript -e 'tell application "Typora" to quit'
if pgrep -f "/MacOS/Typora$" >/dev/null; then
    fail "Typora 尚未退出，请保存文档并退出后重试"
fi

# ---------------------------------------------------------------- 二进制补丁
blue "[2/3] 二进制补丁"
python3 "$SELF/src/patcher.py" "$APP/$BIN_REL" || fail "补丁写入失败"

# ---------------------------------------------------------------- 可选 dylib
if [ "$WITH_DYLIB" = "1" ]; then
    blue "[可选] 编译并安装 bypass.dylib"
    command -v clang >/dev/null || fail "需要 Xcode Command Line Tools"
    TMPD="$(mktemp -d)"
    trap 'rm -rf "$TMPD"' EXIT
    clang -dynamiclib -fobjc-arc \
          -framework Foundation -framework AppKit \
          -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
          -o "$TMPD/bypass.dylib" "$SELF/src/bypass.m" || fail "编译失败"
    cp "$TMPD/bypass.dylib" "$APP/$DYLIB_REL"
    echo "  已安装 $(lipo -info "$APP/$DYLIB_REL" | sed 's/.*are: //')"
    echo "  注入方式：launchctl setenv DYLD_INSERT_LIBRARIES \"$APP/$DYLIB_REL\""
    echo "            open -a Typora"
fi

# ---------------------------------------------------------------- 签名
blue "[3/3] 重签名"
TMPD="${TMPD:-$(mktemp -d)}"
trap 'rm -rf "$TMPD"' EXIT
ENT="$TMPD/ent.plist"
codesign -d --entitlements :- "$APP" 2>/dev/null | sed -n '/<?xml/,$p' > "$ENT" || true
if [ ! -s "$ENT" ]; then
    cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
</dict></plist>
PLIST
fi

sign() { codesign --force --sign - --timestamp=none "$@" >/dev/null 2>&1; }

# 顺序：内层二进制 -> 版本目录 -> framework -> dylib -> bundle -> 主二进制
SPARKLE="$APP/$FW_REL/Sparkle.framework/Versions/A/Sparkle"
[ -f "$SPARKLE" ] && sign "$SPARKLE"
[ -d "$APP/$FW_REL/Sparkle.framework/Versions/A" ] && sign "$APP/$FW_REL/Sparkle.framework/Versions/A"
[ -d "$APP/$FW_REL/Sparkle.framework" ] && sign "$APP/$FW_REL/Sparkle.framework"
[ -f "$APP/$DYLIB_REL" ] && sign "$APP/$DYLIB_REL"
sign "$APP"

# 主二进制最后签，带 entitlements。
# 不要加 --options runtime：ad-hoc 签名 TeamID 为空，
# hardened runtime 的 library validation 会拒绝加载内嵌的 Sparkle。
codesign --force --sign - --timestamp=none \
         --entitlements "$ENT" "$APP/$BIN_REL" >/dev/null 2>&1

if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    green "  ✓ 签名校验通过"
else
    fail "签名校验未通过"
fi

green "\n✓ 激活完成"
echo
echo "  启动: open -a Typora"
echo "  验证: 右下角无「未激活」；偏好设置 → 通用 显示已注册"

