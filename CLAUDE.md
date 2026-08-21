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

## 其它

- **本地开发版会被自动更新器换掉**：`./build.sh` 出的是 `0.0.0-dev`，已加护栏（版本含 `dev` 不参与
  自动更新）。排查「代码明明改了跑起来还是旧行为」先比对 `CFBundleVersion`，别信「刚装过」。
- **签名必须用固定证书**：TCC 授权按签名主体记，ad-hoc 每次构建 cdhash 变，静默更新完权限就掉。
- 更多实测硬结论（AX 面板判定、事件 tap、面板尺寸、拼音）见 README「它是怎么做到的」与
  `/workspace/.claude/projects/-home-yujie/memory/quickbar_mac_shortcut_app.md`。
