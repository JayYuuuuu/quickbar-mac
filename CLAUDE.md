# QuickBar — 项目工作指南

macOS 快捷条。源码 devbox `/workspace/quickbar-mac`，公开仓库 `JayYuuuuu/quickbar-mac`。
面向用户的说明在 [`README.md`](README.md)，这里只放**开发时会踩的坑**。

## 机器拓扑

| 角色 | 机器 | 说明 |
|---|---|---|
| 源码 | devbox `/workspace/quickbar-mac` | 只编辑源码/文档/git。**Linux 出不了 `.app`，编译必须去 Mac** |
| 构建机 | `ssh mac24g` → `~/quickbar-mac` | macOS 26 / Swift 6.3 / 完整 Xcode，钥匙串里有签名证书 |
| 运行机 | 同一台 mac24g | ⚠️ 构建机和用户日常在用的机器是同一台，装调试版前先想清楚 |

```bash
./release.sh 1.5.0            # devbox 一条命令：同步→Mac 构建签名→取回→发 GitHub Release
# 只想编译验证（不发版）：
rsync -az --delete --exclude .git --exclude .build --exclude dist -e ssh ./ mac24g:~/quickbar-mac/
ssh mac24g 'cd ~/quickbar-mac && ./build.sh'
```

## 🔴 素材批次连不上服务器 = macOS「本地网络」权限，不是代码问题

**这个坑 FramePick 早就完整记录过，去看 [`/workspace/framepick/CLAUDE.md`](/workspace/framepick/CLAUDE.md)
「内网机器上检查更新失效」那节，别再从头查一遍**（2026-08-20 我就是没先看它，重新发现了一遍）。

一句话成因：公司局域网里路由器把 `ai.yujiev.com` DNS 反代到 NAS 内网 `192.168.1.28`
→ App 访问的是局域网设备 → macOS 15+/26 要求「本地网络」授权 → 没授权就**静默丢包**。

**症状**：`URLSession` 报 -1009「似乎已断开与互联网的连接」（零延迟返回）或超时；
设置页那行状态显示不出批次。

**唯一可靠的判据**（2026-08-20 实测数据）：

| 从 App 里打 | 结果 |
|---|---|
| 公网 `api.github.com` | 922ms **200** |
| 内网域名 `ai.yujiev.com:8444` | 30s **超时** |
| 内网直连 `192.168.1.28:8788` | 30s **超时** |
| **公网 IP** `221.227.19.32:8444` | **28ms**，TLS 错（证书是给域名的）→ **网络层通** |

🔴 **别拿终端 `curl` 或 `swift` 脚本去测** —— 终端进程有豁免，永远成功，测不出 GUI App 的遭遇。
要么在 App 里加探测，要么现编一个签名的最小 GUI App。

**修法**：在那台内网 Mac 上把域名钉到公网 IP（现成的自愈 daemon 在
`/workspace/framepick/scripts/mac-hosts-sync.sh`，一次 sudo 装好后每 10 分钟自动跟 IP 走）。
排查顺序永远是先 `grep yujiev /etc/hosts`。

家里 / 外网的机器解析到公网 IP，不碰这道坎，一切正常 —— 两台机器的差异全在这。

## 🔴 给 Settings 加字段：别指望 Swift 的默认值兜底

`struct Settings: Codable` 里写了默认值 **不代表**缺键能解出来。Swift 合成的
`Decodable` 碰到缺失的键直接抛 `keyNotFound`（2026-08-21 实测），而 `Store.load()`
外面是 `try?` —— 于是**每加一个设置项，所有老用户的 settings.json 就被整份清空一次**。
1.6.0 加了三个键，触发方式、素材批次口令、记住的面板尺寸当场全没，用户是看到
「怎么变成关了」才发现的。

现在 `Store.decodeSettings` 先把一份默认值编成 JSON，再把磁盘那份盖上去，缺什么补什么，
以后加键不用管。但 **`QuickItem` 还是裸的**：给它加字段只能加 Optional 的，
否则老 `items.json` 解不开会被换成一套默认条目。

## 素材批次那一行还带「传没传进图片空间」（v1.7.0）

`MaterialFeed` 除了 `/api/listing-source/history`，还顺手拉一次
`/api/tu-upload/quickbar-status`（同一把只读口令），按 `品牌 + 批次目录` 对上号，
渲染进条目右侧：正在传时整行让给 `上传中 12/40`，传完 `… · 已传`，差几张 `… · 差 1 张`。

- 🔴 **没派过上传任务的批次一个字都不加**，不写「未上传」——绝大多数批次本来就轮不到传，
  每行挂个否定词只会把真正要注意的那几行淹掉。
- 🔴 **那一发失败就当没有**，照常显示批次列表。它是附加信息，不能让它把快捷条最主要的用途打空。
- 🔴 **`MaterialBatch` 新增的字段全是 Optional**。老版本缓存的 `material-batches.json` 里没有这几个键，
  换成非 Optional 会让整份缓存解不开 → 升级后快捷条上批次**全部消失**，要等下一次网络拉取才回来。
  跟下面 Settings 那条是同一个坑的两个版本。
- 上传本身不归 QuickBar 管：网页上点「传到图片空间」→ 服务端推给 Mac 上常驻的 dmp-runner →
  它 `launchctl kickstart` 一个 launchd agent 去干活。**QuickBar 只负责显示**，
  因为这件事出问题的地方全在这台机器的本地状态（千牛浏览器开没开、登录过没过期），
  而人就坐在这台机器前面。细节在 AI 电商内容助手仓库的 `docs/rules/油猴脚本.md`。

## `quickbar://` 是给网页用的入口（v1.8.0）

「AI 电商内容助手」的品牌素材变动页上那个「在 Finder 打开」，落点是
`quickbar://reveal?path=…&dir=…&suffix=…` → `Sources/QuickBar/Core/URLScheme.swift`。

- 🔴 **URL 事件自己装处理器**，不能只靠 `application(_:open:)`：那条走的是 AppKit 装的默认
  GetURL 处理器，`LSUIElement` 的后台程序上不同系统版本表现不一致。AppDelegate 里两条都接着，
  `URLScheme.handle` 内有 2 秒去重，撞上也不会开两次访达。
- 🔴 **这是任何网页都能塞参数的入口**，所以只认 `reveal` 一个动作、只开访达；路径必须落在
  `/Volumes` 或家目录下（`standardizedFileURL` 折平 `..` 之后再判前缀）。要加动作先想清楚
  「一个恶意页面拿它能干什么」——别把执行/删除/上传挂上来。
- 🔴 **三个参数是有分工的**：`path` 首选目标、`dir` 兜底目录、`suffix`（`_<商品ID>`）让本机
  按后缀在 `dir` 里再找一次。服务端读到的目录名和访达呈现的可能对不上（SMB 的 Unicode
  归一化就够了），`suffix` 是唯一的自愈路径。
- 🔴 **绝不「点了没反应」**：目标没了就退到还在的上一层并说清原因；通知没授权就退回弹框
  （静悄悄地降级 = 人以为打开的是 A、其实是 B）。
- 服务端那半边：路径由 `api/material-folder.js` 从盘上**读**出来（容器 `/nas/<共享>` ↔
  Mac `/Volumes/<共享>`，只差一个前缀），不是拼的。改那边先读 AI 电商内容助手仓库的
  `docs/rules/采集-店铺与详情浏览.md` 与 `api/material-folder.js` 的文件头。

## 主图丢进 PS / `~/最近素材批次`（v1.9.0，浮窗 v1.10.0）

- `MainImages.swift` 是**挑图口径的唯一一处**：单张图 / `主图` 目录 / 商品文件夹 / 批次目录都认。
  🔴 **只往下看一层，不递归** —— 给的要是品牌目录，递归下去就是几千张图，人只会看到 PS 卡死，
  根本猜不到自己点了什么。
  🔴 `SUB_DIRS = ["主图", "主图1比1"]`（v1.12.0 起）：这是两套**不同的**图（3 比 4 / 1 比 1），
  不是同一张的裁剪版，**两边都要去水印**（用户 2026-08-24 确认）。实测 31 件的批次里
  `主图1比1/` 每件就 1 张（`main_1x1_01.jpg`，3 件是空的），所以代价是每件多一个标签页。
  再往里加目录之前先量一遍每件会多开几张。
  🔴 加了第二个子目录之后，**「几件」要往上跳两层数**（`<商品>/主图/`、`<商品>/主图1比1/`）——
  只跳一层数的是子目录数，药丸上的件数会翻倍。见 `MainImagesPill.tickFinder`。
- `FinderService.selectionNow()` 是**现查**的，跟缓存那份 `currentSelection` 不是一回事
  （后者只记单个文件、还是 Finder 激活/失活时刷的）。「把选中的这几个丢进 PS」差一步就开错东西。
- `BatchLinks.swift`：🔴 **只删自己建的符号链接**（按 `attributesOfItem` 判 typeSymbolicLink，
  不跟随链接）。这目录在人家家目录下，普通文件/文件夹一律不碰。
  🔴 **整套 IO 在后台队列**：目标在 `/Volumes`（SMB）上，盘掉了一个 `stat` 能卡好几秒，
  而这活儿由网络回调触发 —— 放主线程上就是整个软件转圈。
  🔴 关开关时清目录要放在 MaterialFeed 那个 `guard !batches.isEmpty` **之前**，
  否则批次本来就空时「关掉」这一下什么都不会发生。
- 🔴 `MainImages.FIRST_ONLY = true`：**每件只开首图**（用户 2026-08-24：「只需要每个主图的第一张，
  一般都是第一张主图有水印」）。全开是 507 张 / 批。
- `MainImagesPill.swift`（v1.10.0，选中就浮出来那颗）三条实测教训：
  🔴 **问 Finder 要选中项不能在后台队列跑** —— `NSAppleScript` 在非主线程上**一声不响地返回空**，
     表现是药丸从不出现、日志一行没有。主线程一次几十毫秒可以接受（只在 Finder 在最前时）；
     真正重的那半（数图 = readdir，SMB）才放后台。
  🔴 **心跳一直跑，别靠 `didActivateApplication` 启动轮询** —— Finder 本来就在最前时（自动更新后
     重启、开机自启）那个通知永远不来，功能从此静默失效。心跳自己看 `frontmostApplication`，
     不在 Finder 时只读一个属性就返回。
  🔴 这台机器上 **`log show` 拿不到 NSLog**（远程排查时别指望它），验证靠临时写 `/tmp` 文件 +
     `CGWindowListCopyWindowInfo` 看窗口在不在屏幕上（`layer=3` 就是 floating）。
     屏幕截不到（`screencapture` 在 ssh 会话里报 could not create image from display）。
- `WindowFollow.swift`（v1.14.0）让药丸贴着宿主窗口走。
  🔴 **移动/缩放通知是注册在那个窗口元素上的，不是应用上** —— 人 ⌘N 开个新窗口，
  旧注册还挂在旧窗口上，表现是「有时候跟、有时候不跟」。所以应用元素上还得盯
  `focusedWindowChanged`，一变就把窗口那几条重新挂过去。
  🔴 **`AXObserverGetRunLoopSource` 要挂主线程的 run loop**：回调里动 NSPanel，AppKit 只认主线程。
  🔴 **推送会漏**（切空间、换显示器、窗口被别的程序移动），所以心跳那一跳在药丸可见时
  照样补一次位 —— **推送负责跟手，心跳负责别跑偏**，两个都得有。
  🔴 **位置没变就别 `setFrameOrigin`**：拖窗时通知一秒好几十条，每条都重设一次浮窗自己会抖。
- 🔴 **访达那头「有人动了才去问它」**（v1.15.0）。原来每 1.5 秒无条件问一次访达
  「选中了什么」——一次 AppleScript 往返约 24ms，**只要访达在最前就一直在花**
  （2026-08-24 实测 1.6% 单核），而且平均要等 0.75 秒才发现变化，加进场 400ms，
  人点完到药丸浮出来 1.2 秒。两头都不划算。
  访达里的选中项**只可能被点击或按键改变**，而事件 tap 本来就在看这两样 ——
  于是 `EventTapService.onUserInput` → `MainImagesPill.noteUserInput()`，防抖 120ms 查一次。
  **两条不能去掉**：30 秒的兜底轮询；以及 tap 没在跑时（人手动「暂停触发」）
  退回原来的每跳都问，不然药丸慢得像坏了。右键松开也收进掩码了 ——
  访达里右键点一个文件也会把它选中。
  🔴 **点下去那一刻要现查一次选中项**（`MainImagesPill.act`）。药丸上那组路径是上一次
  探测留下的，中间被脚本改过就会**开错东西** —— 那比慢半拍严重得多。
  把「正确性」从轮询频率上摘下来之后，兜底才敢从 8 秒放到 30 秒
  （1.6% → 0.35% → **0.1% 单核**，三档都是 mac24g 实测）。
- **界面照 `design/QuickBar 快捷条.dc.html` 做的**（v1.14.0 起）。那份稿子里的「实现侧」便签
  是**决定实现方式的结论**，不是装饰，改界面前先看：进出节奏（进场延迟 400ms 再确认、
  同一宿主 3 秒内不重播）、附着锚点（访达右下内侧 −12,−12；PS 下缘中线上方 10）、
  菜单栏必须模板图且暂停只降 alpha、App 图标各档描边宽度。
  🔴 **药丸可点态是实色强调填充 + 白字 + 前导白点，不是毛玻璃**（v1.15.0 按实拍改的）：
  玻璃灰底浮在 PS 的深色画布上会完全糊掉，人眼扫过去只看到一小块比背景稍亮的雾。
  **只有不可点的「存回中…」才降成中性玻璃** —— 灰掉本身就是「现在别点」。
  🔴 **「点过了就不再弹」这条只能管一小会儿。** 它是防重复丢的（点完手还在那儿，
  药丸立刻又冒出来很容易再点一下），但第一版让它一直管到「选中项变了」为止 ——
  结果从 PS 回到访达、文件夹还选着，药丸就再也不出来了（2026-08-25 用户反馈）。
  现在**从别的应用回到访达**或**过了 20 秒**都会重新武装。不用更短的纯计时是因为
  PS 冷启动能要十几秒，那期间药丸弹回来再点一下，`remaining` 会多记一遍，计数当场就错。
  🔴 **改药丸之后跑 `./Packaging/RenderPill.sh` 离屏渲染核对一遍。**
  这台机器 **`screencapture` 在 ssh 会话里截不到屏**（报 could not create image from display），
  而药丸是一颗浮窗，绘制层次排错了从外面一点看不出来 —— 1.15.1 就把实色填充排到了
  毛玻璃底下，发出去才被实拍打回来。那个脚本把 `PillView` 原样接进一个小程序跑一遍，
  产物就是它真实的绘制结果（`scp mac24g:'/tmp/pill/*.png' .` 取回来看）。
  🔴 **自绘的层不能直接 `self.layer?.addSublayer`**：AppKit 会把**子视图的 layer 排到
  手动加的 sublayer 上面**，于是毛玻璃反过来盖住实色填充。挂在一个排在 `blur` 之后的
  子视图（`paint`）上，顺序才由子视图数组说了算。
  🔴 `PillView` 里三条实测：`NSTrackingArea` 必须 `.activeAlways`（QuickBar 从来不是活跃应用，
  别的 option 一个鼠标事件都收不到，表现是悬停态永不出现）；进度线宽度要用 `bounds` 现算
  （药丸宽度随中文字数变）；改 layer 颜色要包 `CATransaction.setDisableActions`，
  否则隐式动画会拖出一条 0.25 秒的尾巴。
- 用户面前那台机器是 **mac24g**（浏览器、Finder、PS 都在这台）。另一台 `macmini-i7` 跑采集/runner，
  **有意不装 QuickBar**（用户 2026-08-24 明确说不用），别把「要在人面前发生」的动作推给它。

## 存回原位：改完的图按原路径覆盖写回（v1.11.0）

去水印的后半程。`Core/Photoshop.swift` 是**唯一一处跟 PS 说话的地方**。

- 🔴 **绝不在主线程上发 AE**。Apple Event 是同步等待的，PS 压着任何模态框（存储进度、
  生成式填充、缺字体）就一直不回复 —— 2026-08-24 实测：终端里问它 `count of documents`，
  40 秒没回来。所以跑在一条 `Thread` + `CFRunLoopRun()` 的专用线程上。
- 🔴 **run loop 是那条线程的命根子**。没有 run loop 的 `DispatchQueue` 上 `NSAppleScript`
  会一声不响返回空（跟 MainImagesPill 那一轮是同一个坑）。为了不把这条赌进去：
  **每次动作的第一发永远是只读探测**（`infoScript`），撞上「空且无错」就把
  `mainThreadOnly` 翻成 true，之后全走主线程。只读的重来一次没有代价，写盘的不能赌。
- 🔴 **20 秒没回话要主动说话，而且要把那条线程扔掉**。AE 是同步的，卡住的那一发会一直占着
  专用线程，**后面每一发都排在它后面**（2026-08-24 实测：一发卡住，之后两发一个都没跑）。
  超时兜底除了说话，还必须 `thread = nil` 换一条新的 —— 不然一次卡死之后这功能到重启为止都是哑的。
- 🔴 **存回去用 `file path of d` 拿到的 alias，不拼路径字符串**。素材盘是 SMB，
  服务端读到的目录名和访达呈现的可能差一次 Unicode 归一化（URLScheme 那节已经吃过一次）。
- 🔴 **JPEG 存第 9 档，不是 12。** 存回的是一张**本来就压过**的图，12 档只会把体积翻一倍：
  真素材 1440×1920 实测 —— 原图 732,600 字节（亮度量化均值 12.7）、q9 684,460（10.4）、
  q12 1,476,300（1.7）。多出来的精度大半花在保留原图自己的压缩痕迹上，而图传上淘宝还会被
  平台再压一次。**别往 6 以下降**：PS 在 7 档以下切到 **4:2:0**，色度分辨率减半，
  布料花色和文字会发虚 —— 那是断崖不是渐变。口径写在 `Photoshop.JPEG_QUALITY`。
  `format options:optimized`（基线已优化）是白捡的 2.1%：量化表一个字节不变、画质零损失，
  684,409 → 669,769。不写这一项 PS 默认走 `standard`。
- **这条路 = PS 的「文件 → 存储为 / 存储副本」**，逐项对应那个「JPEG 选项」对话框。
  **不是「导出为」/「存储为 Web 所用格式」**：那是另一套引擎，画质刻度 0–100 不是 0–12
  （实测 SFW q80 反而比这儿的 q9 更细、文件更大 842 KB），而且会把 EXIF/XMP/ICC 剥光。
  「存储为」这条固有会带上约 18.7 KB 元数据（EXIF + Photoshop 资源块 + XMP + sRGB 的 ICC），
  原始下载图只有 16 B 的 JFIF —— 有人问「怎么比原图多出一截」时先想到这个。
- 🔴 **`save … in` 的目标必须是 file specification，不能是 alias。**
  `file path of d` 给的就是 alias，直接喂回去必报 **8800「发生了常规 Photoshop 错误。
  该功能可能无法在这个版本的 Photoshop 中使用」** —— 一句有用的话都没有，1.12.0/1.12.1 卡在这儿。
  2026-08-24 在真 PS 上逐参数试过：目标写 `POSIX file` 时，带不带 `embed color profile`、
  带不带 `appending no extension` 全部成功；只要换成 alias 就必失败。
  转换写成**处理器** `on toFile(a) return POSIX file (POSIX path of a) end toFile`，
  在 `tell` 块里 `my toFile(file path of d)` 调用 —— 处理器体在脚本自己的上下文求值，
  一举绕开下面那条抢词。（`POSIX file` 直接写在 `tell` 块里也不行，PS 会当成自己的对象去解，
  报 -1728「不能获得 …of «script»」。）
- 🔴 **`POSIX path of` 绝不能写在 `tell application id "com.adobe.Photoshop"` 块里面。**
  PS 的字典里有一整套 **Path Suite**（`path item` / `path name` / `entire path` / `target path`…，
  贝塞尔路径那套），`path` 这个词被它抢走，`POSIX path of x` 于是被送给 PS 而不是交给
  StandardAdditions，PS 不认 → 报错。1.12.0 就栽在这儿：从 Finder 丢进去的图也一律走进
  「这张没有原始路径」。**取出来、出了 `tell` 块再转**（Adobe 自己的示例也是这么写的）。
  Finder 没有 `path` 术语，所以 `FinderService` 里同样的写法一直没事 —— 别拿那边的经验推这边。
  连带的口径：**判「能不能存回」看 `file path` 拿没拿到，不看 POSIX 串**；认扩展名用
  `name of current document`。POSIX 串只用来显示和 reveal，它失败不该挡住写盘。
- 🔴 **只认 jpg / png**。覆盖写回意味着原图没了，猜错格式的代价是一张烧进 JPEG 块的 PNG，
  人不会立刻发现。别的扩展名明说跳过。
- 🔴 **`saveAllScript` 从最后一个往前数着走**（`repeat with i from (count of documents) to 1 by -1`）：
  存完就关，关掉 `document i` 之后 1…i-1 下标不动。正着走漏一半；
  写成 `repeat while (count of documents) > 0` 则会被「跳过但不关」的文档卡成死循环。
- **药丸的数字不问 PS**（`Photoshop.remaining`）：QuickBar 自己记丢进去几张，
  每存回一张拿 PS 回的真实 `count of documents` 校准。心跳里发 AE = PS 忙时整条心跳陪着卡。
- 🔴 **动作失败一律 `Notify.problem`（弹框），不能用 `Notify.tell`（通知）。**
  专注模式 / 「通知样式：无」会把横幅**整条吞掉**：2026-08-24 实测，「存回原位」连点三次、
  三条通知全部投递成功（日志里 `Added notification request … hasError: 0`），人一条都没看见，
  表现就是「按了没反应」，为此白查了一轮。
- 🔴 **远程排查看 `~/Library/Logs/QuickBar.log`，别指望 `log show`。**
  `log show --predicate 'process == "QuickBar"'` 是能跑的（早先记的「拿不到」不准确），
  但 NSLog 的**正文是 `<private>`**，只看得到一行占位符 —— 能看出「点击到了 / 脚本跑了 /
  发了通知」这类骨架，看不到任何内容。`Notify.log` 现在同时落一份明文到那个文件。
- **要在真 PS 上试脚本**：`ssh mac24g` 跑 `osascript` 需要「sshd 想要控制 Photoshop」授权
  （2026-08-24 已批）。安全做法：`cp` 一张图到 `/tmp` → `open -b com.adobe.Photoshop` 打开它 →
  **先 `name of current document` 确认最前面的是那个临时文件再动手**，否则会覆盖人正在改的真素材。
  只读的探测直接跑；要试 `save` 就加 `with copying` 存到 `/tmp`。
  🔴 **别对着 PS 已经打开的那个文件再 `cp` 一次** —— PS 会弹「磁盘拷贝已更改，是否更新？」，
  那是个模态框，之后所有 AE 全部挂住（实测卡了一轮，得用 System Events 点掉「取消」再收拾）。
  测完记得把临时文档 `close … saving no`，别给人留一堆标签页。
- 改 AppleScript 之后**先在 Mac 上 `osacompile` 过一遍**再信它 —— 但注意
  **`osacompile` 只管语法，管不了术语被抢、也管不了参数类型**
  （`POSIX path` 抢词和 alias 当目标这两条，编译全程绿灯，运行才炸）：
  `python3` 把 `Photoshop.swift` 里的字面量抠出来、替掉插值，`scp` 上去 `osacompile -o /tmp/x.scpt`。
  PS 的术语只有它自己的 sdef 说了算，Swift 编译器一个字都帮不上。

## 其它

- **本地开发版会被自动更新器换掉**：`./build.sh` 出的是 `0.0.0-dev`，已加护栏（版本含 `dev` 不参与
  自动更新）。排查「代码明明改了跑起来还是旧行为」先比对 `CFBundleVersion`，别信「刚装过」。
- **签名必须用固定证书**：TCC 授权按签名主体记，ad-hoc 每次构建 cdhash 变，静默更新完权限就掉。
- 更多实测硬结论（AX 面板判定、事件 tap、面板尺寸、拼音）见 README「它是怎么做到的」与
  `/workspace/.claude/projects/-home-yujie/memory/quickbar_mac_shortcut_app.md`。
