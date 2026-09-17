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

# 🔴 不走 SwiftPM，用命令行工具的 swiftc 直接编，钉在保留的 SDK 26.5 上（2026-09-17 改）。
#    mac24g 自动升级到 macOS 27 / Xcode 27 之后，Xcode 许可要 sudo 重新同意 ——
#    没同意之前 `swift build`、`xcrun`、连 `lipo` 这类 /usr/bin 下的转发壳子一律报
#    "You have not agreed to the Xcode license"。换成命令行工具那套：它的 SwiftPM
#    连 Package.swift 都链接不过（PackageDescription 符号缺失），swiftc 本身是好的。
#    这跟 PortManager 在 mac48g 上撞到的是同一次升级，那边也是这么绕的。
#    Package.swift 留着给有完整 Xcode 的机器和编辑器用，这里不读它 —— 改编译参数两边都要改。
#    x86_64 那半会报一句 libswiftCompatibilityPacks.a 缺 x86_64 被忽略：部署目标 13 用不到它，链接照样过。
export DEVELOPER_DIR="${QUICKBAR_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${QUICKBAR_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
[ -d "$SDK" ] || { echo "找不到 SDK：$SDK（QUICKBAR_SDK 可以指定别的）" >&2; exit 1; }

echo "==> 编译 universal 二进制（$(basename "$SDK")）"
OUT=".build/direct"
mkdir -p "$OUT"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources/QuickBar -name '*.swift' | sort)
for ARCH in arm64 x86_64; do
  rm -f "$OUT/QuickBar-$ARCH"      # 编失败时别让上一次的产物冒充这一次的
  "$DEVELOPER_DIR/usr/bin/swiftc" -O -wmo -swift-version 5 -module-name QuickBar \
      -sdk "$SDK" -target "$ARCH-apple-macosx13.0" \
      -Xclang-linker -isysroot -Xclang-linker "$SDK" \
      "${SOURCES[@]}" -o "$OUT/QuickBar-$ARCH" 2>&1 | grep -v "libswiftCompatibilityPacks.a" || true
  [ -x "$OUT/QuickBar-$ARCH" ] || { echo "$ARCH 编译失败" >&2; exit 1; }
done
BINARY="$OUT/QuickBar"
lipo -create "$OUT/QuickBar-arm64" "$OUT/QuickBar-x86_64" -output "$BINARY"
# 🔴 链接器记下的「SDK 版本」必须是真用的那个。系统按它决定给不给这个程序新外观
#    （低于 26 会被当成老程序套兼容模式，毛玻璃、控件长相都可能变）。
#    swiftc 只把 --sysroot 传给链接器，链接器不认它，记下的是 13.0 或默认 SDK 的 27.0
#    （同一天实测两种都出现过），所以上面要补 -isysroot，这里再验一遍。
WANT_SDK="$(/usr/libexec/PlistBuddy -c 'Print :Version' "$SDK/SDKSettings.plist")"
if vtool -show-build "$BINARY" | awk '$1 == "sdk" {print $2}' | grep -vqx "$WANT_SDK"; then
  echo "链接进去的 SDK 版本不是 $WANT_SDK：" >&2
  vtool -show-build "$BINARY" >&2
  exit 1
fi

echo "==> 组装 .app"
rm -rf "$APP" dist/QuickBar.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/QuickBar"

sed -e "s/__VERSION__/${VERSION}/" -e "s/__BUILD__/${BUILD_NUMBER}/" \
    Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 素材批次那条只读通道的口令：构建时写进 Info.plist，**不进仓库**——仓库是公开的。
# 取值顺序：QUICKBAR_MATERIAL_KEY 环境变量 → ~/.quickbar-material-key。
# 都没有也能构建，只是那个包的素材批次要在设置里手填密码（设置页会自动露出那一栏）。
# 必须赶在签名之前写，改完 Info.plist 签名才算数。
MATERIAL_KEY="${QUICKBAR_MATERIAL_KEY:-}"
if [ -z "$MATERIAL_KEY" ] && [ -f "$HOME/.quickbar-material-key" ]; then
  MATERIAL_KEY="$(tr -d '[:space:]' < "$HOME/.quickbar-material-key")"
fi
if [ -n "$MATERIAL_KEY" ]; then
  /usr/libexec/PlistBuddy -c "Add :QuickBarMaterialKey string $MATERIAL_KEY" \
      "$APP/Contents/Info.plist" >/dev/null
  echo "==> 已内置素材批次口令（${#MATERIAL_KEY} 位）"
else
  echo "!! 没找到素材批次口令（QUICKBAR_MATERIAL_KEY 或 ~/.quickbar-material-key）"
  echo "!! 这个包装上后要在设置里手填密码"
fi

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
