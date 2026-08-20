#!/bin/bash
# 构建 QuickBar.app（universal，Intel + Apple Silicon 通吃）并签名打包。
#
#   ./build.sh              以 0.0.0-dev 构建，只出 .app
#   ./build.sh 1.0.0        指定版本号，同时出 QuickBar.zip 供发布
#
# 签名身份可以用环境变量覆盖：QUICKBAR_SIGN_ID="Developer ID Application: ..."
#
# 为什么一定要用固定证书签：macOS 的 TCC（辅助功能/输入监控授权）是按签名主体
# 记住的。用 ad-hoc 签名的话每次重新构建 cdhash 都变，静默更新完权限就掉了，
# 用户得重新授权一遍——那"静默"就没意义了。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.0.0-dev}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
SIGN_ID="${QUICKBAR_SIGN_ID:-LocalShot Internal Code Signing}"
APP="dist/QuickBar.app"

echo "==> 编译 universal 二进制"
swift build -c release --arch arm64 --arch x86_64
BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/QuickBar"

echo "==> 组装 .app"
rm -rf "$APP" dist/QuickBar.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/QuickBar"

sed -e "s/__VERSION__/${VERSION}/" -e "s/__BUILD__/${BUILD_NUMBER}/" \
    Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 生成图标"
rm -rf dist/icon && mkdir -p dist/icon
swift Packaging/MakeIcon.swift dist/icon >/dev/null
iconutil -c icns dist/icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> 签名（$SIGN_ID）"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  codesign --force --deep --options runtime --timestamp=none \
           --entitlements Packaging/QuickBar.entitlements \
           --identifier com.yujiev.quickbar \
           --sign "$SIGN_ID" "$APP"
else
  echo "!! 找不到证书「$SIGN_ID」，退回 ad-hoc 签名。"
  echo "!! 注意：ad-hoc 签名的构建每次都会丢失辅助功能授权，只适合本地临时试跑。"
  codesign --force --deep --sign - \
           --entitlements Packaging/QuickBar.entitlements "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "==> 架构与版本"
lipo -info "$APP/Contents/MacOS/QuickBar"
echo "版本 ${VERSION} (${BUILD_NUMBER})"

if [ "$VERSION" != "0.0.0-dev" ]; then
  echo "==> 打包 dist/QuickBar.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" dist/QuickBar.zip
fi

echo "==> 完成：$APP"
