# 界面设计稿

QuickBar 的界面稿，Claude Design 画布格式（`.dc.html`）。
浏览器直接打开任一个 `.dc.html` 就能看，右上角有 `dark` 开关。

| 文件 | 里面有什么 |
|---|---|
| `QuickBar 快捷条.dc.html` | `Main` 常规 · `Filter` 拼音筛选 · `Panel` 文件面板形态 · `Pill` 浮窗药丸 · `MenuBar` 图标与菜单 · `Onboarding` 权限引导 · `Icon` App 图标 |
| `QuickBar 设置窗.dc.html` | 设置窗那五个侧栏分页 |
| `support.js` | 画布运行时，两份稿子共用。**不要手改** |

线上那份：<https://claude.ai/design/p/fae1a210-97be-46a8-9d09-869de1ec377a>

## 和实现的关系

**「快捷条」那份已经落地了**（v1.14.0）：药丸、快捷条本体、菜单栏图标、引导页、App 图标
都照着改过。稿子里那几张「实现侧」便签记的是决定实现方式的结论（进出节奏、附着锚点、
模板图规则、图标各档描边），代码里对应位置的注释都指回了这里。

**「设置窗」那份还没落地。**

上一版稿子（对着 v1.4.0 画的九块，`Main/Filter/Panel/MenuBar/Onboarding/Settings/Trigger/
Permissions/General` 加 `canvas.json` 和 `src/`）已经删掉 —— 它落后了九个版本，缺素材批次
整块、快捷条上的批次分组和浮窗药丸，留着只会被当成规格。要翻旧账去 git 历史里找。

**它终究是稿子不是规格**：代码继续改的话这里不会自动跟着变，**以实际运行的软件为准**。

## 怎么改

在线上那份画布里改，然后同步回来（`DesignSync` 的 `get_file`，或者页面上导出）。
稿子里的文件夹名（`~/素材库`、`2026Q3 上新` 之类）都是编的示例，跟任何人的实际目录无关。
