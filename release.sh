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

# 顺手把「AI 电商内容助手」桌面工具下载页上的版本号和体积更新一下。
# 页面上那个下载链接指的是 releases/latest/download，永远是最新版，所以这一步
# 只是让展示的版本号别停在旧值上——**失败不影响发版**，因此整段容错。
# 🔴 那个页面上四个软件共处一个 APPS 数组，唯一的写入口就是这个脚本
#    （它以生产那份为基准、只改指定 app 的行，自带校验）。别自己 sed 整个文件再上传，
#    那会把另外三个软件的版本号打回旧值。
SITE="${QUICKBAR_SITE_REPO:-/workspace/ai-ecommerce}"
PATCHER="$SITE/scripts/patch-desktop-tools.sh"
if [ -x "$PATCHER" ]; then
  BYTES="$(stat -c %s dist/QuickBar.zip 2>/dev/null || stat -f %z dist/QuickBar.zip)"
  echo "==> 更新下载页版本号（$VERSION / $BYTES 字节）"
  ( cd "$SITE" && ./scripts/patch-desktop-tools.sh quickbar \
      "[{\"os\":\"macOS\",\"version\":\"$VERSION\",\"bytes\":$BYTES}]" ) \
    || echo "!! 下载页没更新成（发版本身已经成功，稍后手动补：cd $SITE && ./scripts/patch-desktop-tools.sh quickbar …）"
else
  echo "!! 没找到 $PATCHER，跳过下载页更新"
fi
