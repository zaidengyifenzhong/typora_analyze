#!/bin/bash
#
# activate.sh — 一键激活 Typora (macOS)
#
#   ./activate.sh              # 激活 /Applications/Typora.app
#   ./activate.sh --dry-run    # 只检查补丁点，不动文件
#
# 默认同时处理前端字节特征和原生模块，并配置应用自己的加载路径。
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
WITH_DYLIB=1
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
python3 "$SELF/src/patcher.py" --verify "$APP/$BIN_REL" || fail "补丁点检查失败（版本不匹配）"

if [ "$MODE" = "dry" ]; then
    green "\n✓ dry-run 结束，未修改任何文件"
    exit 0
fi

# Compile and export entitlements before modifying the installed application.
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
ENT="$TMPD/ent.plist"
codesign -d --entitlements :- "$APP" 2>/dev/null | sed -n '/<?xml/,$p' > "$ENT"
[ -s "$ENT" ] || fail "无法读取应用 entitlements，未修改应用"
plutil -lint "$ENT" >/dev/null || fail "entitlements 无效"
clang -dynamiclib -fobjc-arc -framework Foundation -framework AppKit \
      -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
      -o "$TMPD/bypass.dylib" "$SELF/src/bypass.m" || fail "编译失败，未修改应用"
# Preserve existing per-app environment keys; don't overwrite another injected library.
LIBPATH="@executable_path/../Frameworks/bypass.dylib"
EXISTING=$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment:DYLD_INSERT_LIBRARIES' "$APP/Contents/Info.plist" 2>/dev/null || true)
[ -z "$EXISTING" ] || [ "$EXISTING" = "$LIBPATH" ] || fail "应用已有其他 DYLD 注入配置，停止覆盖"

# Save documents and quit the running application before applying.
if pgrep -f '/MacOS/Typora$' >/dev/null; then
    fail "请保存文档并完全退出 Typora 后重新运行"
fi
blue "[2/3] 写入补丁和原生模块"
python3 "$SELF/src/patcher.py" "$APP/$BIN_REL" || fail "补丁写入失败"
cp "$TMPD/bypass.dylib" "$APP/$DYLIB_REL"
/usr/libexec/PlistBuddy -c 'Print :LSEnvironment' "$APP/Contents/Info.plist" >/dev/null 2>&1 || \
    /usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' "$APP/Contents/Info.plist"
if [ -n "$EXISTING" ]; then
    /usr/libexec/PlistBuddy -c "Set :LSEnvironment:DYLD_INSERT_LIBRARIES $LIBPATH" "$APP/Contents/Info.plist"
else
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $LIBPATH" "$APP/Contents/Info.plist"
fi
# Preserve the existing entitlements and enable the declared per-app DYLD environment.
/usr/libexec/PlistBuddy -c 'Set :com.apple.security.cs.allow-dyld-environment-variables true' "$ENT" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.allow-dyld-environment-variables bool true' "$ENT"
blue "[3/3] 重签名"

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

green "\n✓ 补丁安装完成，请重启后核实许可证界面"
echo
echo "  启动: open -a Typora"
echo "  验证: 右下角无「未激活」；偏好设置 → 通用 显示已注册"

