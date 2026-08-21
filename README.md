# QuickBar

macOS 上的快捷条。⌥ + 双击屏幕任意位置唤出，跳转文件夹、启动应用；在上传或保存窗里按 ⌘G 直达 Finder 当前目录——Finder 里选中了哪个文件就落在那个文件上。面板和 Finder 新窗口的尺寸都替你记住。

开机自启、静默常驻，没有 Dock 图标，只在菜单栏留一个可关的入口。

## 功能

| | |
|---|---|
| **唤出** | ⌥ + 双击任意位置。也可以选「双击桌面空白处」「裸双击」「连按两下 ⌘」 |
| **跳转文件夹** | 复用当前 Finder 窗口，不新开——所以窗口尺寸不会被重置 |
| **启动应用** | 已在运行就切到前台，没运行才启动 |
| **⌘G 直达** | 在任何上传 / 保存窗里按 ⌘G，直接跳到 Finder 最前窗口所在的目录；那里选中了单个文件就直接落在这个文件上 |
| **记住面板尺寸** | 文件面板不再每次都是那个小方块 |
| **Finder 新窗口尺寸** | 新建的目录、网络卷上的目录，Finder 一律开成 960×492；替你改成惯用尺寸 |
| **静默更新** | 后台检查 GitHub Release，验签通过后换版本重启，全程无感 |
| **素材批次** | 接上「AI 电商内容助手」后，最近派的素材下载批次直接出现在快捷条上，下完还会通知 |

## 安装

从 [Releases](https://github.com/JayYuuuuu/quickbar-mac/releases) 下载 `QuickBar.zip`，解压后把 `QuickBar.app` 拖进「应用程序」，打开即可。

首次打开会引导你完成三项授权：

| 授权 | 没有它会怎样 |
|---|---|
| 辅助功能 | 判断不了当前是不是文件面板，也调不了面板尺寸 |
| 输入监控 | 收不到唤出快捷条的双击和 ⌘G |
| 自动化 · Finder | 读不到 Finder 当前文件夹，⌘G 会退回上次记住的路径 |

三项都是本地能力，QuickBar 不上传任何东西。出站请求只有两个：查 GitHub 有没有新版本；开了「素材批次」的话，按你填的地址去读一份批次目录清单。

> 应用是自签名的，不是 Apple Developer ID。首次打开如果被 Gatekeeper 拦下，在「系统设置 → 隐私与安全性」里点一下「仍要打开」。

## 素材批次（可选，团队内部用）

「AI 电商内容助手」派的素材下载单，落盘的形状是 `<采集根>/<品牌>/<20260820-1305_补素材>/`
—— **每派一单就是一个新的时间戳目录**。所以这批目录手工加书签没有意义，今天加的明天就不指向任何东西。
QuickBar 从服务端把它们取回来，当成会自己更新的条目：

- 上传窗里 ⌥双击 → 输品牌名 → 回车，面板直接落到那个批次目录，不用一层层点。
- 批次下完了弹一条通知，点一下就在 Finder 里打开它。
- 菜单栏常驻一个「打开最新批次」，不弹快捷条也能进去。

在「设置 → 素材批次」里打开开关、填一个密码就行，默认是关的（服务器地址内置，不用填）。
那个密码在服务端只能读 `/api/listing-source/history`（批次落在哪个目录、下完没有），
派单、重下、回写一律够不着 —— 快捷条上按错一下不该能动到线上数据。

> 密码和其它偏好一样存在 `~/Library/Application Support/QuickBar/settings.json`，没有再加一层加密。

## 它是怎么做到的

几条不那么显然、但决定实现方式的事实（都在 macOS 26 上实测过）：

**文件面板的判定**。不管宿主应用是否沙盒（沙盒应用的面板其实由 `com.apple.appkit.xpc.openAndSavePanelService` 绘制），面板都会以 `AXIdentifier = open-panel / save-panel` 出现在「当前聚焦应用的 `AXFocusedWindow`」上。三次属性读取就能判定，实测 0.5ms 量级。

反过来两件事千万别做：别去数 `openAndSavePanelService` 进程——它有多个实例常驻，面板关了进程也不退；别在事件 tap 回调里遍历 AX 子树——一次几千个节点会被系统直接判超时，把整个 tap 禁掉（表现是快捷键毫无征兆全部失灵）。

**面板尺寸**。普通窗口型面板可以用 AX 直接改（要按 size → position → size 的顺序，中间那次改位置是为了避开 macOS 把窗口夹回屏幕的逻辑）。Chrome 这类把面板做成 `AXSheet` 的，AX 改不动——`isAttributeSettable` 会返回 true，然后静默失败。这种只能写宿主应用的 `NSNavPanelExpandedSizeForOpenMode` 偏好，下次打开生效。

**「前往文件夹」吃文件路径**。⌘⇧G 的输入框里给一个完整的**文件**路径，面板会落到它的父目录并且把这个文件选中，再回车就是打开它。前提是用 AX 直接写 `AXValue`——用合成按键逐字符敲会被自动补全接管，回车被吃掉，什么也不会发生。

**Finder 窗口尺寸**。不是全局设置，是**按文件夹逐个记**的，记在**父目录的 `.DS_Store`** 里（`bwsp` 记录，一段 binary plist，含 `WindowBounds`），而且**关窗那一刻才写盘**。没有记录的文件夹一律开成 960×492，跟「上一个窗口多大」无关——一个 1520×1020 的窗口开着时新开一个没记录的文件夹，仍然是 960×492，只是位置错开。macOS 没有「默认窗口尺寸」这个偏好可以改。于是两种情况每次都是小窗口：每次新建的目录（素材批次那种时间戳目录）天生没有记录；`DSDontWriteNetworkStores = 1` 时 Finder 根本不往网络卷写 `.DS_Store`（在 SMB 共享上把窗口拉大再关掉，`.DS_Store` 的 mtime 纹丝不动），尺寸只活在 Finder 进程内存里，Finder 一重启全丢。所以只能在窗口出现的那一刻自己改，而且只动尺寸恰好等于 960×492 的——别的尺寸是那个文件夹自己记着的，覆盖了就是帮倒忙。

**签名与自动更新**。macOS 的 TCC 授权是按签名主体记的。如果用 ad-hoc 签名，每次构建 cdhash 都变，静默更新完权限就掉了——所以必须用固定证书签，"静默"才成立。更新包下载后用**当前运行版本自己的 designated requirement** 去校验，签名主体或 bundle id 对不上直接丢弃。

## 界面设计稿

动工前画的六块界面草图在 [`design/`](design/)，深浅色都有。注意那是**动工前**的稿子，后来在真机上撞出来的问题改变了几个决定，`design/README.md` 里列了差异。

## 从源码构建

需要 macOS 13+ 和 Swift 6 工具链（Xcode 或 Command Line Tools）。

```bash
git clone https://github.com/JayYuuuuu/quickbar-mac.git
cd quickbar-mac
./build.sh                 # 出 dist/QuickBar.app
./build.sh 1.0.0           # 指定版本，同时出 dist/QuickBar.zip
```

默认找名为 `LocalShot Internal Code Signing` 的证书；用 `QUICKBAR_SIGN_ID` 换成你自己的：

```bash
QUICKBAR_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh 1.0.0
```

找不到证书会退回 ad-hoc 签名，能跑，但每次重新构建都要重新授权，只适合本地临时试。

## 已知限制

- Electron / Qt / JetBrains 自绘的文件选择器不是 `NSOpenPanel`，⌘G 对它们无效。浏览器上传是标准面板，没问题。
- 保存窗的 ⌘G 只跳目录，不跟选中的文件——文件路径会被填进名字栏，等于默认覆盖同名文件。
- sheet 型面板（Chrome）的尺寸记忆是**下次打开生效**，不是当场变。
- 沙盒应用的面板尺寸偏好写在它自己的容器里，QuickBar 改不到，只能靠 AX 当场调整。
- 非沙盒应用，上不了 App Store。

## 许可

MIT
