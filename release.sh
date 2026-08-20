#!/bin/bash
# 发版：在 devbox 上跑一条命令，代码同步到 Mac 构建签名，产物取回来发 GitHub Release。
#
#   ./release.sh 1.0.0
#   ./release.sh 1.0.0 "修了 xxx"        # 附加发布说明
#
# 构建必须在 Mac 上做（要 Swift 工具链和钥匙串里的签名证书），
# 但 gh 在 devbox 上，所以产物走 scp 拿回来再发。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?用法: ./release.sh <版本号> [发布说明]}"
NOTES="${2:-}"
MAC="${QUICKBAR_BUILD_HOST:-mac24g}"
REMOTE_DIR="~/quickbar-mac"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "版本号要长这样：1.0.0" >&2
  exit 1
fi

echo "==> 同步代码到 $MAC"
rsync -az --delete --exclude .git --exclude .build --exclude dist -e ssh ./ "$MAC:$REMOTE_DIR/"

echo "==> 在 $MAC 上构建并签名 $VERSION"
ssh "$MAC" "cd $REMOTE_DIR && ./build.sh $VERSION"

echo "==> 取回产物"
rm -rf dist && mkdir -p dist
scp "$MAC:$REMOTE_DIR/dist/QuickBar.zip" dist/QuickBar.zip

echo "==> 校验取回来的包"
unzip -l dist/QuickBar.zip | grep -q "QuickBar.app/Contents/MacOS/QuickBar" || {
  echo "包里没有可执行文件，中止" >&2; exit 1
}

echo "==> 打 tag 并发布"
git tag -a "v$VERSION" -m "v$VERSION" 2>/dev/null || echo "tag v$VERSION 已存在，复用"
git push origin "v$VERSION"

BODY="${NOTES:-QuickBar $VERSION}

安装：下载 QuickBar.zip，解压后把 QuickBar.app 拖进「应用程序」。
已装旧版的不用管，后台会自动更新。"

gh release create "v$VERSION" dist/QuickBar.zip \
  --title "v$VERSION" \
  --notes "$BODY"

echo "==> 完成：https://github.com/JayYuuuuu/quickbar-mac/releases/tag/v$VERSION"
