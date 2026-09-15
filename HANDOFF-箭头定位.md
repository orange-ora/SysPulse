# SysPulse 交接说明：菜单栏面板箭头定位问题（历史快照）

> **⚠️ 本文件是 2026-09-15 凌晨的历史快照，内容已过时**——当时箭头问题还没解决，
> 里面记的"解法"后来被证明是错的。**新会话请读同目录的 `HANDOFF.md` + `README.md`，
> 不要按本文件操作**；这里只作踩坑历史保留。
>
> 给下一位接手的人（或 AI）看。项目本身的说明在 `README.md`，这里只讲**这个箭头定位问题**：
> 文件位置、现状、已验证的事实、以及可复现的验证手段。
>
> **当前状态：代码已回滚，没有任何修正**（2026-09-15 按用户要求回滚）。
> 但下一节「1」记录了一个**已测出、验收数据很好、却因回滚而未在代码里生效**的解法——
> 接手时请先读那一节，再决定是否重新启用。

## 0. 问题

macOS 菜单栏应用 SysPulse 的下拉面板（`NSPopover`）上方有一个指向状态栏图标的箭头。
**需求：不管用户开了几个显示项（图标宽度随之变化），箭头都要指向图标中心。**

## 1. ⭐ 已找到的解法（已回滚，代码里当前**没有**生效）

**结论：箭头偏移是一个与图标宽度无关的恒定值，把锚点矩形中心右移 14pt 即可。**

```swift
// Sources/SysPulse/StatusItemController.swift
private func anchorRect(for button: NSStatusBarButton) -> NSRect {
    let bounds = button.bounds
    return NSRect(x: bounds.midX + 14 - 15, y: bounds.midY - 0.5, width: 30, height: 1)
}
// 并在 popover.show(relativeTo: anchorRect(for: button), of: button, preferredEdge: .minY)
// 以及面板开着时"图标宽度变了就重新 show 一次"（见下面 2.2）
```

要点：

- 系统渲染出的**箭头尖端恒比锚点矩形中心偏左约 14pt**，且在
  图标宽 213 / 159 / 105 / 48pt 四种配置下都是 13.75～14.25pt（即与图标宽度无关）。
- 锚点矩形取 **30pt 宽**（而不是 1pt）：锚点一旦越出按钮范围，系统会把箭头**夹回按钮边缘**，
  修正量就失效了；30pt 在最窄的按钮（图标 48pt / 按钮 64pt）下仍在界内。

**验收数据**（该轮记录，纯净版无插桩）：

| 指标数 | 图标宽 | 箭头 − 图标/按钮中心 |
| --- | --- | --- |
| 4 项 | 213pt | +0.25pt |
| 3 项 | 159pt | +0.25pt |
| 2 项 | 105pt | +0.25pt |
| 1 项 | 48pt | +0.75pt |

### 1.1 这套数据的一个待补验证（重要）

上表的「图标中心」是**由窗口 frame 反推的"按钮中心"**，不是像素级实测的图标中心。
也就是说它证明了「**箭头对准了系统认为的锚点中心**」，但**没有**独立验证
「按钮中心 = 图标可见内容的中心」。

本次（回滚前）我用像素法量过一次，当时的数据是：图标可见文字
`↓1.0K CPU 14 GPU 59 MEM 60` 画在屏幕 **1071–1267（中点 1169）**，
而箭头在 **1185.8**，即**偏右约 17pt**。

两者结论不一致，可能的原因：
- 像素量法把相邻系统图标算了进来（见 4. 的坑），或把图标内边距算了/没算；
- 或者「按钮中心 = 图标内容中心」这个前提在某些图标宽度下不成立。

**所以接手后的第一件事建议是**：用第 4 节的方法（纯色图标 + `screencapture -l` 单拍面板）
做一次独立复核，确认 `+14` 在**真实图标**下也准。如果准，就把它重新启用；
如果不准，就退回「无修正」再找出真正的规则。

## 2. 当前代码（回滚后）

`Sources/SysPulse/StatusItemController.swift` 第 164 行——**没有任何修正，官方写法**：

```swift
popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
```

回滚时移除的东西（**不要以为它们还在**）：

- `anchorRect(for:)`（锚点矩形计算，含 `+14` 修正）
- `repositionPanelIfNeeded()`（面板开着时重新锚定的逻辑）
- `updateStatusItem` 里每次重绘后的重新锚定调用
- 属性 `lastAnchorRect`、`currentIconWidth`

### 2.1 图标宽度怎么来的

`MenuBarImage.render(...)` 按当前显示项返回图片，`image.size.width` 就是图标宽度。
图标各段是**固定槽位宽**（速度按 `↓888M` 占位、百分比按 `CPU 100` 占位），
所以宽度只随**选项个数**变化、不随数值变化。

### 2.2 做动态对准的前提（必读）

**`NSPopover` 不会跟着锚点自己走。** 实测：面板开着时把状态栏图标从 80pt 换成 180pt，
popover 停在 x=775 不动；重新 `show` 才移动到 x=725。
→ 想让"切换显示项后箭头仍对准"，**必须自己再调一次 `show`**。

（顺带：对已显示的 popover 再调一次 `show(relativeTo:…)` 确实会重新定位，
实测锚点从左挪到右，popover 内容中心 836 → 956。）

## 3. 试过但**错误**的做法（不要改回去）

- `bounds.midX − (iconWidth − 105.5)`：**错**。`105.5` 来自
  「分两次识别面板深色区域与菜单栏白字、再各算中心」的**错误量法**，
  中途把别的深色窗口算进了面板中心；方向也是反的（应右移）。
  实测该写法随图标宽度恶化到偏 **121pt**，比完全不修正更差。
- 单纯用 `button.bounds.midX` 做锚点中心：偏（缺那个 14pt）。
- 把 `statusItem.length` 直接设成图片宽度（想让按钮框 = 图标）：实测更差。

## 4. 可复现的验证手段（要量就用这套）

> 血泪教训：**先看清楚再动手**。大量时间浪费在"用像素阈值从菜单栏反推坐标"上，
> 而那套方法本身不可靠。

- **看界面**：`screencapture -x -R x,y,w,h out.png`（区域单位是**点**），然后直接看图。
  这是最可靠的手段。
- **量图标真实位置**：临时把状态栏图标换成一张**纯色不透明**图片
  （如 `NSColor.systemPink`），截图后按颜色找左右边界。这是唯一可靠的"图标在哪"的判据。
- **量箭头位置**：`screencapture -x -l <面板窗口 id>` **单独拍面板窗口**，
  图像里按 alpha 找顶部那个凸起（箭头），取其列范围中心。
  面板窗口 id 用 `CGWindowListCopyWindowInfo` 按 owner name 过滤拿到
  （工具：`Tools/VerifyArrow/winlist.swift`，编译后运行即列出窗口与真实 frame）。
- **坐标换算的坑**：
  - `screencapture` 的 `-R` / `-l` 单位是**点**，输出是 **2 倍像素**（屏幕 1710x1107 pt）。
  - `CGWindowList` 的 `bounds` 原点在**左上**，`NSWindow.frame` 在**左下**。
  - 面板窗口宽 368pt = 内容 342pt + 两侧阴影各 13pt → **内容中心 = 窗口 minX + 13 + 171**。
  - **必须在同一状态、同一套屏幕坐标下同时量箭头和图标**，否则会得出
    「偏差随图标宽度线性变化」的假象（状态栏项会整体挪位，而面板停在旧位置）。
- **合成点击**：`Tools/Clicker <x> <y>`。注意它**在真实 `NSPopover` 里常被"点了外部"逻辑
  吃掉**（面板关掉但控件没触发），控件交互别只靠它验证。
- **程序化打开面板**：临时加环境变量 + 定时器调用 `applyToggle()`，比合成点击可靠。
  本次用过 `AUTO_OPEN_PANEL` / `AUTO_TOGGLE_GPU` 之类临时钩子，**用完必须删**。
- **量面板实际位置**：临时把 `popover.contentViewController?.view.window?.frame` 写到文件。

## 5. 环境注意事项（都踩过）

- **`codesign` 会改变二进制内容**：`build/SysPulse` 未签名 931600 字节，
  签名后 945376 字节。**不要拿未签名产物和已安装产物比 md5**，会误判成"装的是旧版"。
  要比时间戳。
- **`defaults write` 改不了正在运行的 App 的显示项**：`Preferences` 是内存缓存的
  `ObservableObject`，不监听外部改 plist。想用脚本复现"切换显示项"，要么在 App 内点，
  要么**先改 plist 再启动**。本次用 `defaults write` 测过，得出过"改动没生效"的错误结论。
- **`build.sh` 的可写性判断有坑**：它用 `[ -w /Applications ]`。若当前用户不是
  `/Applications` 属主（即使在 `admin` 组、目录组可写），它会**误判为不可写**、
  改为只打包到 `dist/`，**并且在此之前已经杀掉了正在运行的实例**——
  结果是监控停了、`/Applications` 里还是旧版。此时手工装回去：

  ```bash
  rm -rf /Applications/SysPulse.app
  cp -R dist/SysPulse.app /Applications/SysPulse.app
  codesign --force --deep --sign - /Applications/SysPulse.app
  open /Applications/SysPulse.app
  ```

- **离屏渲染（`NSHostingView` + `cacheDisplay`）会丢语义色文字**，
  验证界面对比度要用真实窗口或屏幕截图。

## 6. 文件与位置

| 东西 | 路径 |
| --- | --- |
| 项目根目录 | `/Users/orange/Documents/DeepSeek/SysPulse` |
| 安装的 App（机器上唯一副本） | `/Applications/SysPulse.app` |
| **面板弹出 / 箭头定位** | `Sources/SysPulse/StatusItemController.swift`（第 164 行） |
| 菜单栏图标绘制 | `Sources/SysPulse/MenuBarImage.swift` |
| 面板 UI | `Sources/SysPulse/DashboardView.swift` |
| 构建脚本 | `./build.sh` |
| 项目说明（必读） | `README.md`（「开发备注」里有本问题的记录） |
| 验证工具 | `Tools/`（`Clicker`、`StatusProbe`、`LayoutProbe`、`VerifyArrow/winlist.swift`） |
| 用户偏好 | `~/Library/Preferences/com.local.syspulse.plist` |

构建：

```bash
cd /Users/orange/Documents/DeepSeek/SysPulse
./build.sh              # 编译 + 安装到 /Applications + 启动
./build.sh --no-launch  # 只编译安装不启动
./build.sh --local      # 只打包到 dist/，不安装
```

## 7. 当前状态清单

- **箭头相关代码已全部回滚**：
  `grep -rn "anchorRect\|repositionPanelIfNeeded\|lastAnchorRect\|currentIconWidth" Sources/` → 空。
- 源码可编译（`./build.sh` 通过），**无调试残留**：
  `grep -rn "CALIB\|AUTO_OPEN\|/tmp/" Sources/` → 空。
- `/Applications/SysPulse.app` 已构建安装并运行。
- 本问题之外**保留**的改动（不要回滚）：
  - `DashboardView.swift`：「显示项」卡片排版优化——紫色徽标、标题与开关行间距 12pt、
    四个开关等宽铺满、勾位固定宽度；
  - `Tools/StatusProbe/main.swift`：修好了原有编译错误（`render` 缺 `density` 参数）；
  - `Tools/LayoutProbe`：新增，量三档排版宽度（顺带发现单行/极简档网速段宽度会跳动，
    `README.md` 已记为已知缺陷）；
  - `Tools/VerifyArrow/winlist.swift`：列出 App 窗口与真实 frame（验箭头用）；
  - `README.md`：「开发备注」补充了本问题现状与验证方法、`codesign` 改内容、
    `defaults write` 改不动运行中的 App。
