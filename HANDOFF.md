# SysPulse 工作交接（2026-09-16）

> **新会话接手请读这份，再加上 `README.md`。** 这份只讲"当前状态 + 今天做了什么 + 还差什么"，
> 项目本身的完整说明（数据来源、刘海、构建、所有历史踩坑）都在 `README.md`。
>
> 这一轮针对"面板换档跳动"的**完整排查过程、实验数据、失败方案、未验证假设**，
> 都在 `DEVLOG-面板跳动-2026-09-16.md` —— 要接着修这个 bug 请先读它。
>
> 同目录下旧的 `HANDOFF-箭头定位.md` 是 9-15 凌晨的快照，**内容已过时**，只作历史保留。

## 0. 一句话现状

**面板换档跳动的根因已经钉死，但只修好了一半。**

- **图标增加（面板左移）→ 正常**；**图标减少（面板右移）→ 仍会反向跳一下**（一帧左右）。
- 根因：换档时**系统自己会移动面板**（用"新宽度 + 旧 x"算出的中间态位置）。
  减少方向上那个位置离正确位置差 45pt、看得见；增加方向上恰好等于最终位置、看不出来。
- 当前代码（`5b6a0f7` = `99febbe` 内容）判据是"只看状态栏窗口的 x 变化"，
  已解决增加方向；**减少方向为什么仍跳、以及"系统为什么出手"，还没做直接验证**。
- **下一步实验方案写在 `DEVLOG` 第 4 节**，别从零重来。

其余功能（面板排版、菜单选完收面板、流光、箭头跟随）都正常。

## 1. 项目位置与常用命令

| 东西 | 路径 |
| --- | --- |
| 项目根目录 | `/Users/orange/Documents/DeepSeek/SysPulse` |
| 安装的 App（机器上唯一副本） | `/Applications/SysPulse.app` |
| 源码 | `Sources/SysPulse/*.swift`（12 个文件，约 2070 行） |
| 构建 | `cd /Users/orange/Documents/DeepSeek/SysPulse && ./build.sh` |
| 偏好 | `~/Library/Preferences/com.local.syspulse.plist` |
| 历史版本存档 | `Backups/`（16 个文件副本，按需 `cp` 回来） |

`build.sh` 会**先杀掉正在运行的实例**再替换二进制。用 `--no-launch` 只编译不启动时，
**实例会被杀掉且不会自动起来**，记得手动 `open /Applications/SysPulse.app`。
它的安装判定用的是 `[ -w /Applications ]`，某些 shell 下会**误判不可写**、只打包到 `dist/`；
这时手动装回：`cp -R dist/SysPulse.app /Applications/SysPulse.app` + `codesign --force --deep --sign -` + `open`。

## 2. 当前状态（可直接核对）

- 运行中，偏好：四项指标全开 · 自动排版（`auto`）· 刷新 1 秒 · 流光开启
- 编译 **0 错误 0 告警**；源码里**没有任何调试代码**（`grep -rn "AUTO_\|TRACE\|/tmp/" Sources/` 为空）
- 空闲开销 **0.13% CPU / 50.6 MB**（流光本身约 +0.11%；面板开过一次后内存 +38MB 由 AppKit 持有）
- 这一轮的改动只集中在 `StatusItemController.swift`（`syncPanelAnchor` 一带）

## 3. 今天做完的事（都已验证）

### 3.1 面板「显示项」卡片排版（`DashboardView.swift`）
- 徽章改紫色、与上方卡片同一网格（徽章 20pt、图标-标题间距 7pt）
- 标题行与开关行间距 9.5pt → **12.5pt**
- 四个开关等宽铺满卡片；勾位固定 9pt 宽（开关时标签不左右移动）；关掉的开关加 0.5pt 描边

### 3.2 底部菜单选完收起整个面板（`DashboardView` + `StatusItemController`）
- 需求：底部「刷新 / 排版 / 启动」里选任一项后，**面板一起收起**
- 实现：`DashboardView.onMenuSelection` → `StatusItemController.closePopoverIfShown()`
- 坑：**不能在菜单项 action 里直接 `performClose`**（`NSMenu` 还在收尾，`isShown` 会立刻变 false
  但窗口仍在屏幕上）→ 丢到下一个 runloop 再关

### 3.3 菜单栏「流光」背景（`MenuBarImage.drawGlow`）
- **没有"流光 API"**：`MeshGradient` 要 macOS 15、`.glassEffect` 要 26，而部署目标是 14
- 做法：自绘渐变圆角矩形 + **3 组色带、相位各差 120°**（正弦"包"控制明暗）→ 整条此起彼伏地流动
- 只做**横向**渐变（竖向恒定，否则那点高度会糊）
- 15fps 定时器推进相位，**每帧只重画这一层渐变**（文字排版仍只在数据刷新时做）
- 当前参数（`drawGlow` 内）：
  ```swift
  baseHues = [0.58, 0.75, 0.50]   // 蓝 / 紫 / 青
  alpha * 0.40                     // 浓淡（0.24 极透 ↔ 0.44 偏实）
  cycle = 240, turns = 2.5         // 波长 / 流动速度
  ```
- **试过又回滚的**：玻璃质感（顶部高光 + 亮边 + 底缘暗边）、整体提亮（`brightness 1.15`）
  ——存档在 `Backups/流光-v3.x`，想要可以 `cp` 回来

### 3.4 箭头跟随图标（上一轮修好的，这一轮仍然有效）
- 实现：`syncPanelAnchor()`——以"状态栏窗口 frame 变化"为触发条件，
  每次重绘（含流光帧）检查一次，变了就按新锚点 `popover.show` 一次
- 验证：三种图标宽度偏差都 ≤0.5pt
- **踩过的坑（三次都改错地方）**：
  1. 放在 `if allowLayoutChange` 分支里 → 换档那次触发不到
  2. 延时 50ms / 循环追 50ms×12 → 启动升档要等下一次数据刷新，追丢了
  3. 判据用 `popover.isShown` → 开合动画期间滞后，把对齐整段跳过
- **位移动画已按用户要求回滚**（`animatePanel` 已删除）

### 3.5 换档时面板跳一下 —— **根因已钉死，减少方向仍未解决**

**现象**：面板开着时关掉「网速」（图标减少、面板右移），箭头**先反向跳一下**；
开「网速」（图标增加）则正常。

**已钉死的因果（均有对照实验，详见 `DEVLOG` 第 2 节）**：
1. 系统换档时**分两段**改状态栏窗口：先改**宽度**（x 不动，且会先 ±2pt 微调），
   约 15~30ms 后才改 **x**。
2. **系统会自己移动面板**（`NSWindow.didMoveNotification` + 调用栈证实不是我发起的），
   用的是 `旧 x + 新宽度/2` 这个**算错的中间态**：减少方向算出 902（正确是 947），
   增加方向算出 924（恰好就是最终位置）。
3. `popover.show` 有两个坑：**面板已显示时可能被系统整个吞掉**（实测 `before=902 after=902`）；
   **面板 alpha=0 时连调用都不返回**。

**当前修法**：`syncPanelAnchor` 判据改成**只看 x 变化**（x 的最后一次变化才代表排版完成），
定位前再读一次 frame。代码 473 行，去抖/预测/校正全部删除。

**验证**：图标增加方向 `979 → 924` 一步到位；图标减少方向仍有约一帧的中间态（`902`）。

**走过的弯路（别再走）**：去抖 60/120ms、右边缘守恒预测、16ms 定时器校正、
"收面板稳定后重开"（用户明确否决）、"alpha=0 隐藏"（技术上不可行）。
共同错误是都在回答"我该什么时候喊 `show`"，没问"**为什么系统要摆那一下**"。

## 4. 两个交互上的提醒（别重走弯路）

- **合成点击（`Tools/Clicker`）能点开面板，但点不进 `NSPopover` 里的控件**。
  要复现"面板开着时切换显示项"，得在 App 内加**临时环境变量钩子**触发（配方见第 7 节）。
- **`defaults write` 改不了"正在运行的 App"的偏好**（`Preferences` 是内存缓存）。
  实测即使 `pkill` 掉 cfprefsd、确认 plist 里已是新值，重启后 App 仍读旧值——
  要复现不同显示项组合，最省事的办法是用 App 内钩子或直接在面板里点，不要跟 cfprefsd 较劲。

## 5. 开发与验证手段（这套是今天沉淀出来的，直接用）

### 5.1 环境坑（都踩过）
- **`codesign` 会改变二进制内容**：`build/SysPulse` 未签名 931600 字节、签名后 945376。
  **不要拿未签名产物和已安装产物比 md5**，要比时间戳。
- `screencapture` 的 `-R`/`-l` 单位是**点**、输出是 **2 倍像素**；
  `CGWindowList` 的 `bounds` 原点在**左上**（y 向下）、`NSWindow.frame` 在**左下**，别混用。
- 面板窗口 `368 × 533`、`layer=25`；`Tools/winlist` 能直接列出它的 frame。

### 5.2 量测方法（关键判据）
- **面板的箭头位置** ＝ `面板窗口.minX + 13 + 171`
- **图标中心** ＝ `状态栏窗口.minX + width/2`（窗口比图片宽 16pt，两侧各 8pt，中心相同）
- **不要数 `CGWindowList` 里 layer=25 的窗口来判"面板是否开着"**：面板关闭后那个窗口还在列表里。
  用**自己维护的 `isPanelOpen`**，或判断窗口是否真在屏幕上。
- **不要用像素阈值从菜单栏反推图标中心**：相邻的 VPN／天气／输入法图标会被算进来。
- **这次最好用的手段：让 App 自己 3ms 采样 `popover` 窗口的 frame**（临时诊断代码，
  验证完删掉）。它比从外面猜可靠得多，时间戳还能和 App 内事件直接对齐。
  这次也试过在外部用 `CGWindowListCopyWindowInfo` 采样——**当前环境里拿不到本进程窗口**
  （那条路需要"屏幕录制"权限），别在这上面浪费时间。

### 5.3 现有工具（`Tools/`）
`Clicker`（合成点击，注意第 4 节和 5.1 的限制）、`StatusProbe`（把面板渲染成真实窗口便于截图）、
`LayoutProbe`（量三档排版宽度）、`VerifyArrow/winlist.swift`（列 App 窗口与真实 frame）、
`CPUSpy`（量指定进程 CPU/内存）、`NetSpy`、`GPUStress`、`MakeIcon`。

## 6. 已知的其他问题 / 待办

1. **图标减少时面板仍跳一下**（当前第一优先）。要验证的假设与实验方案见
   `DEVLOG-面板跳动-2026-09-16.md` 第 4 节：需要抓"系统挪面板那一刻
   `button.window.frame` 到底是旧 x 还是新 x"，并补全 2×2（起手档位 × 变化方向）对照。
2. **单行档 / 极简档的网速段宽度会随数值变**（159pt ↔ 213pt），两行档正常；
   `Tools/LayoutProbe` 可复现；README 已记为已知缺陷。
3. **箭头对准的是"状态栏窗口中心"**，而图标**可见内容**中心比窗口中心偏右约 21pt
   （系统渲染图片的位置特性，与代码无关）。用户未提出，未处理。
4. 版本管理现在有 git 了，`Backups/` 里的文件副本可以不再依赖；
   本轮各版本索引见 `DEVLOG` 第 6 节。

## 7. 复现"面板反向跳"的调试配方（下次改这块时直接用）

1. 在 `StatusItemController` 里**临时**加：`SYSPULSE_TRACE=1` 时把
   ①每次 `popover.show` 的 rect/时间戳、②状态栏窗口 frame、③`popover` 窗口 frame
   （**用一个 3ms 的 `DispatchSourceTimer` 采样**）写成一行行日志；
   再加一个 `SYSPULSE_AUTO_TOGGLE_DELAY/INTERVAL` 钩子在 App 内切换 `preferences.showNetwork`
   （合成点击进不了 popover，这是唯一能自动复现"面板开着时换档"的办法）。
2. 装到 `/Applications`，用 `open --env SYSPULSE_TRACE=1 --env SYSPULSE_TRACE_FILE=/tmp/t.txt
   --env SYSPULSE_AUTO_TOGGLE_DELAY=4 /Applications/SysPulse.app` 启动；
   用 `Tools/Clicker <图标中心x> 12` 点开面板。
3. 把日志按 `x` 变化点抽出来看轨迹：**是否存在一个既不是起点也不是终点的 x**。
4. 验证完**把诊断代码全部删掉**（`grep -rn "AUTO_\|TRACE\|/tmp/" Sources/` 必须为空），
   再 `./build.sh` 重编。
