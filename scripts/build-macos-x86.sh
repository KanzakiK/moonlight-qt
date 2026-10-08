#!/bin/bash
#
# build-macos-x86.sh — 在 Intel Mac (x86_64) 上编译 Moonlight (moonlight-qt)
#
# 精简版：跳过 USB 转发 helper (moonlight-usbd) 与 File Provider 扩展，
#         只产出 Moonlight.app，不做代码签名。
#         因此不需要 cmake，也不用官方的 scripts/generate-dmg.sh。
#
# 用法：  bash scripts/build-macos-x86.sh [release|debug]
# 前置：  1) Qt 6.11.2 macOS 通用包已装到 ~/Qt/6.11.2/macos（见 docs/macos-x86-build.md）
#         2) 已跑过 python3 setup-deps.py 下载 libs/mac
#
set -euo pipefail

# 脚本位于 <repo>/scripts/，据此推断仓库根目录
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$SRC/build/build-x86_64"
CONFIG="${1:-release}"
ARCH=x86_64

fail() { echo "[build] 错误: $1" 1>&2; exit 1; }

# ---- 1. 定位 Qt ----
# aqtinstall 装出来的目录名可能是 macos 或 clang_64，取决于版本，两个都找一遍。
# 也可以直接用 QT_ROOT 环境变量覆盖。
if [ -z "${QT_ROOT:-}" ]; then
  for cand in "$HOME/Qt/6.11.2/macos" "$HOME/Qt/6.11.2/clang_64" "$HOME/Qt/6.11.2"; do
    [ -x "$cand/bin/qmake" ] && QT_ROOT="$cand" && break
  done
fi
[ -n "${QT_ROOT:-}" ] || fail "找不到 Qt 6.11.2 的 qmake。先跑: aqt install-qt mac desktop 6.11.2 clang_64 -m qtmultimedia qtimageformats -O \$HOME/Qt"
echo "[build] Qt: $QT_ROOT ($("$QT_ROOT/bin/qmake" -query QT_VERSION))"

export PATH="$QT_ROOT/bin:$PATH"

# ---- 2. 依赖检查 ----
[ -d "$SRC/libs/mac" ] || fail "缺少预编译依赖，先跑: cd '$SRC' && python3 setup-deps.py"

# ---- 3. qmake + 编译 ----
# 复用同一个构建目录做增量编译（不删目录，避免误删与全量重编）。
mkdir -p "$BUILD"
pushd "$BUILD" > /dev/null

echo "[build] ==> qmake ($ARCH)"
qmake "$SRC/moonlight-qt.pro" QMAKE_APPLE_DEVICE_ARCHS="$ARCH" || fail "qmake 失败"

# 关键：必须递归刷新各子目录的 Makefile。
# 顶层 qmake 不会覆盖已存在的子 Makefile；如果首次 qmake 时子模块还没落地，
# 那份 Makefile 会漏掉 moc 规则，最终链接时报一堆 "vtable for ..." 未定义。
echo "[build] ==> make qmake_all"
make qmake_all || fail "qmake_all 失败"

echo "[build] ==> make $CONFIG"
make -j"$(sysctl -n hw.logicalcpu)" "$CONFIG" || fail "编译失败"
popd > /dev/null

APP="$BUILD/app/Moonlight.app"
[ -d "$APP" ] || fail "没找到 $APP"

# ---- 4. 把剪贴板 helper 塞进包里 ----
HELPER=""
for c in "$BUILD/clipboard-helper/moonlight-clipboard-helper" \
         "$BUILD/clipboard-helper/$CONFIG/moonlight-clipboard-helper"; do
  [ -f "$c" ] && HELPER="$c" && break
done
[ -n "$HELPER" ] || fail "没找到 moonlight-clipboard-helper"
cp "$HELPER" "$APP/Contents/MacOS/"

# ---- 5. 打包 Qt 运行时 ----
# -executable 必须显式带上 helper，否则它会保留构建机的 Qt 绝对路径，启动时直接崩。
echo "[build] ==> macdeployqt"
macdeployqt "$APP" -qmldir="$SRC/app/gui" \
  -executable="$APP/Contents/MacOS/moonlight-clipboard-helper" || fail "macdeployqt 失败"

find "$APP" -name '*.dSYM' -prune -exec rm -rf {} + 2>/dev/null || true

# ---- 6. ad-hoc 签名（关键，别省）----
# macOS 15 的「本地网络」隐私权限只会授予**已签名**的代码。完全未签名的 app
# 不会弹权限框，而是被静默拒绝：现象是首页 mDNS 一直转圈、手动加 IP 也连不上，
# 日志里报 "serverinfo" request failed with error: QNetworkReply::UnknownNetworkError
# 且请求与报错在同一秒（不是超时，是系统直接拒）。
# ad-hoc 签名（"-"）不需要证书，但足以让 TCC 记录并弹出授权框。
echo "[build] ==> ad-hoc 签名"
codesign --force --deep --sign - "$APP" || fail "签名失败"

# ---- 7. 去掉隔离属性，本机首次打开不会被 Gatekeeper 拦 ----
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo
echo "[build] ==> 产物: $APP"
file "$APP/Contents/MacOS/Moonlight"
echo "[build] 完成。直接 open \"$APP\" 即可运行。"
