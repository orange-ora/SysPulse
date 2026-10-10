import AppKit
import SwiftUI

// 当前 SDK 同时导出 State 宏；命令行 Swift 5 构建明确使用属性包装器。
private typealias PanelState<Value> = SwiftUI.State<Value>

/// 数据主视图与设置页共享同一层轻玻璃；所有采样和历史仍由 SystemMonitor 持有。
enum DashboardPage { case overview, settings }
enum DashboardDetail: String { case cpu = "CPU", gpu = "GPU", memory = "内存", network = "网络" }

struct DashboardView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var preferences: Preferences
    let usesWindowSurface: Bool
    let naturalSizeDidChange: ((CGSize) -> Void)?
    @ObservedObject private var login = LaunchAtLogin.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @PanelState private var page: DashboardPage
    @PanelState private var selectedDetail: DashboardDetail?
    @PanelState private var displayedDetail: DashboardDetail
    @StateObject private var detailMotion: PanelDetailAnimation
    @PanelState private var nativeCanvasAttached = false

    init(monitor: SystemMonitor, preferences: Preferences,
         initialPage: DashboardPage = .overview, initialDetail: DashboardDetail? = nil,
         usesWindowSurface: Bool = false, naturalSizeDidChange: ((CGSize) -> Void)? = nil,
         detailMotion: PanelDetailAnimation? = nil) {
        self.monitor = monitor
        self.preferences = preferences
        self.usesWindowSurface = usesWindowSurface
        self.naturalSizeDidChange = naturalSizeDidChange
        _page = State(initialValue: initialPage)
        _selectedDetail = State(initialValue: initialDetail)
        _displayedDetail = State(initialValue: initialDetail ?? .cpu)
        let motion = detailMotion ?? PanelDetailAnimation(initiallyExpanded: initialDetail != nil)
        motion.initialize(expanded: initialDetail != nil)
        _detailMotion = StateObject(wrappedValue: motion)
    }

    private var snapshot: MetricsSnapshot { monitor.snapshot }
    private var palette: PanelPalette {
        PanelPalette(transparency: reduceTransparency ? 0 :
            Preferences.normalizedPanelTransparency(preferences.panelTransparency))
    }

    private var transparency: Double {
        Preferences.normalizedPanelTransparency(preferences.panelTransparency)
    }
    private var frostAmount: Double {
        pow(max(0, (0.45 - transparency) / 0.45), 2)
    }
    private var usesClearGlass: Bool { transparency >= 0.65 }

    var body: some View {
        Group {
            if usesWindowSurface {
                content
                    // 首次离屏测量仍取自然高度；挂到窗口后，内容始终贴齐宿主顶边。
                    .frame(minHeight: nativeCanvasAttached ? 0 : nil,
                           maxHeight: nativeCanvasAttached ? .infinity : nil, alignment: .top)
                    .background(PanelWindowAttachment { _ in
                        DispatchQueue.main.async {
                            if !nativeCanvasAttached { nativeCanvasAttached = true }
                        }
                    })
            } else if #available(macOS 26.0, *), !reduceTransparency {
                content
                    .background {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.thickMaterial)
                            .opacity(frostAmount * 0.85)
                    }
                    .glassEffect(
                        usesClearGlass ? Glass.clear : Glass.regular,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
            } else {
                content
                    .background {
                        PanelMaterial()
                            .overlay {
                                palette.surface.opacity(reduceTransparency ? 1 :
                                    0.22 * (1 - transparency))
                            }
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: usesClearGlass)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if page == .overview {
                overview.transition(.opacity)
            } else {
                settings.modifier(PanelReadingPlate(palette: palette)).transition(.opacity)
            }
        }
        .padding(14)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { naturalSizeDidChange?($0) }
        .foregroundStyle(palette.primary)
        .tint(palette.accent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: page)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 6)
                .modifier(PanelReadingPlate(palette: palette))
                .modifier(PointerCardHover(cornerRadius: 12, borderTint: palette.accent,
                                           borderOpacity: 0.80, palette: palette, tracksSubcontrols: true))
            metricGrid
            if usesWindowSurface {
                PanelDetailSection(animation: detailMotion, expanded: selectedDetail != nil,
                                   reduceMotion: reduceMotion,
                                   detail: AnyView(detailPanel(displayedDetail)),
                                   tail: AnyView(overviewTail))
                    .frame(width: 332)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let detail = selectedDetail {
                        detailPanel(detail).transition(.opacity)
                    }
                    overviewTail
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: selectedDetail)
            }
        }
    }

    private var overviewTail: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceInformationPanel
            metricToggles.modifier(PanelReadingPlate(palette: palette))
            menuBarEffects.modifier(PanelReadingPlate(palette: palette)).padding(.top, 6)
            separator
            footer
                .padding(.horizontal, 4)
                .modifier(PanelReadingPlate(palette: palette))
                .padding(.vertical, 6)
                .modifier(PointerCardHover(cornerRadius: 12, borderTint: palette.accent,
                                           borderOpacity: 0.80, palette: palette, tracksSubcontrols: true))
                .padding(.vertical, -6)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .frame(width: 16, height: 17)
                    Text("SysPulse")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text("系统运行 \(Format.uptime(snapshot.uptime)) · \(snapshot.processCount) 进程")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Button { detailMotion.cancel(); page = .settings } label: {
                PanelHoverPlate(palette: palette, plate: palette.tile, circular: true) { hovered in
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .regular))
                        .rotationEffect(.degrees(hovered && !reduceMotion ? 45 : 0))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0), value: hovered)
                        .frame(width: 30, height: 30)
                }
            }
            .buttonStyle(PanelPressButtonStyle())
            .foregroundStyle(palette.secondary)
            .help("显示与外观")
            .accessibilityLabel("打开显示与外观设置")
            .accessibilityIdentifier("panel.settings")
        }
        .padding(.vertical, 4)
    }

    private var metricGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                metricTile(.cpu, icon: "cpu", fraction: snapshot.cpuUsage,
                           detail: "用户 \(Format.percent(snapshot.cpuUser)) · 系统 \(Format.percent(snapshot.cpuSystem))",
                           history: monitor.cpuHistory)
                metricTile(.gpu, icon: "display", fraction: snapshot.gpuUsage.map { $0 / 100 },
                           detail: gpuSubtitle, history: monitor.gpuHistory)
            }
            HStack(spacing: 8) {
                metricTile(.memory, icon: "memorychip", fraction: snapshot.memoryFraction,
                           detail: "\(Format.bytes(snapshot.memoryUsed)) / \(Format.bytes(snapshot.memoryTotal))",
                           history: monitor.memoryHistory)
                networkTile
            }
        }
    }

    private func metricTile(_ kind: DashboardDetail, icon: String, fraction: Double?,
                            detail: String, history: [Double]) -> some View {
        Button { toggleDetail(kind) } label: {
            VStack(alignment: .leading, spacing: 5) {
                tileHeading(kind.rawValue, icon: icon, color: palette.metricTint(kind))
                Text(fraction.map { Format.percent($0) } ?? "--")
                    .font(.system(size: 28, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.readingColor(kind, fraction: fraction,
                                                          memoryPressure: snapshot.memoryPressure))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(detail)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Sparkline(series: [history], colors: [palette.metricTint(kind)], upperBound: 1)
                    .frame(height: 30)
                    .accessibilityHidden(true)
            }
            .padding(11)
            .frame(maxWidth: .infinity)
            .frame(height: 136)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PointerCardButtonStyle(tint: palette.metricTint(kind), palette: palette,
                                           selected: selectedDetail == kind))
        .help(detailDescription(kind))
        .accessibilityLabel("\(kind.rawValue)，\(fraction.map { Format.percent($0) } ?? "尚未就绪")，\(detail)\(kind == .memory ? "，压力：" + snapshot.memoryPressure.title : "")")
        .accessibilityHint("展开详细信息")
        .accessibilityIdentifier("panel.metric.\(kind)")
    }

    private var networkTile: some View {
        Button { toggleDetail(.network) } label: {
            VStack(alignment: .leading, spacing: 5) {
                tileHeading("网络", icon: "arrow.up.arrow.down", color: palette.metricTint(.network))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.metricTint(.network))
                    Text(Format.speed(snapshot.downSpeed))
                        .font(.system(size: 21, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(palette.readingPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(height: 34, alignment: .leading)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                    Text(Format.speed(snapshot.upSpeed)).monospacedDigit()
                }
                .font(.system(size: 10.5))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                Spacer(minLength: 0)
                Sparkline(series: [monitor.downHistory, monitor.upHistory],
                          colors: [palette.metricTint(.network), palette.metricTint(.network).opacity(0.65)], upperBound: nil)
                    .frame(height: 30)
                    .accessibilityHidden(true)
            }
            .padding(11)
            .frame(maxWidth: .infinity)
            .frame(height: 136)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PointerCardButtonStyle(tint: palette.metricTint(.network), palette: palette,
                                           selected: selectedDetail == .network))
        .help(detailDescription(.network))
        .accessibilityLabel("网络，下载 \(Format.speed(snapshot.downSpeed))，上传 \(Format.speed(snapshot.upSpeed))")
        .accessibilityHint("展开本次运行累计流量")
        .accessibilityIdentifier("panel.metric.network")
    }

    private func tileHeading(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11.5, weight: .medium))
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(color)
    }

    private func tileStyle(_ kind: DashboardDetail, selected: Bool) -> some ViewModifier {
        PanelGlassStyle(palette: palette, cornerRadius: 12,
                          tint: palette.metricTint(kind), selected: selected)
    }

    private func setDetail(_ detail: DashboardDetail?) {
        if usesWindowSurface { detailMotion.request(expanded: detail != nil) }
        if let detail { displayedDetail = detail }
        selectedDetail = detail
    }

    private func toggleDetail(_ detail: DashboardDetail) {
        setDetail(selectedDetail == detail ? nil : detail)
    }

    private var gpuSubtitle: String {
        if snapshot.gpuUsage == nil {
            return snapshot.gpuUnavailable ? "该机型未提供计数器" : "等待 GPU 数据"
        }
        var parts: [String] = []
        if let cores = snapshot.gpuCores { parts.append("\(cores) 核") }
        if let memory = snapshot.gpuMemory { parts.append(Format.bytes(memory)) }
        return parts.isEmpty ? "实时利用率" : parts.joined(separator: " · ")
    }

    private func detailDescription(_ kind: DashboardDetail) -> String {
        switch kind {
        case .cpu:
            return "用户 \(Format.percent(snapshot.cpuUser)) · 系统 \(Format.percent(snapshot.cpuSystem)) · \(snapshot.cpuCores) 核"
        case .gpu:
            var parts: [String] = []
            if snapshot.gpuUsage == nil { parts.append(gpuSubtitle) }
            if let cores = snapshot.gpuCores { parts.append("\(cores) 核") }
            if let memory = snapshot.gpuMemory { parts.append("GPU 内存 \(Format.bytes(memory))") }
            return parts.isEmpty ? "实时利用率" : parts.joined(separator: " · ")
        case .memory:
            return "压力：\(snapshot.memoryPressure.title) · 已用 \(Format.bytes(snapshot.memoryUsed)) / \(Format.bytes(snapshot.memoryTotal)) · 交换 \(Format.bytes(snapshot.swapUsed))"
        case .network:
            return "本次运行接收 \(Format.bytes(snapshot.totalDown)) · 发送 \(Format.bytes(snapshot.totalUp))"
        }
    }

    private func detailPanel(_ kind: DashboardDetail) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(kind.rawValue) 明细")
                    .font(.system(size: 10.5, weight: .medium))
                    .contentTransition(.opacity)
                Text(detailDescription(kind))
                    .font(.system(size: 10.5))
                    .contentTransition(.opacity)
                    .monospacedDigit()
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { setDetail(nil) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(PanelPressButtonStyle())
            .modifier(PanelGlassStyle(palette: palette, cornerRadius: 6, isControl: true))
            .foregroundStyle(palette.secondary)
            .accessibilityLabel("收起明细")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(tileStyle(kind, selected: false))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: kind)
    }

    private var deviceInformationPanel: some View {
        let device = monitor.deviceInformation
        var processorParts = [device.processorName]
        if snapshot.cpuCores > 0 { processorParts.append("\(snapshot.cpuCores) 核 CPU") }
        if let cores = snapshot.gpuCores { processorParts.append("\(cores) 核 GPU") }
        return DeviceInformationCard(
            modelName: device.modelName,
            processorDescription: processorParts.filter { !$0.isEmpty }.joined(separator: " · "),
            memoryDescription: device.memoryDescription,
            palette: palette
        )
    }

    private var metricToggles: some View {
        HStack(spacing: 3) {
            Text("菜单栏")
                .font(.system(size: 11))
                .foregroundStyle(palette.secondary)
                .frame(width: 36, alignment: .leading)
            metricToggle("网速", key: "network", isOn: $preferences.showNetwork)
            metricToggle("CPU", key: "cpu", isOn: $preferences.showCPU)
            metricToggle("GPU", key: "gpu", isOn: $preferences.showGPU)
            metricToggle("内存", key: "memory", isOn: $preferences.showMemory)
        }
        .padding(.top, 1)
    }

    private func metricToggle(_ title: String, key: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(isOn.wrappedValue ? palette.controlGreen : Color.clear)
                    .overlay(Circle().strokeBorder(isOn.wrappedValue ? Color.clear : palette.secondary, lineWidth: 1))
                    .frame(width: 5, height: 5)
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isOn.wrappedValue ? palette.controlGreenText : palette.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelControlButtonStyle(tint: palette.controlGreen, selected: isOn.wrappedValue,
                                            palette: palette))
        .accessibilityLabel("菜单栏显示\(title)")
        .accessibilityValue(isOn.wrappedValue ? "开启" : "关闭")
        .accessibilityIdentifier("panel.toggle.\(key)")
        .help("在菜单栏\(isOn.wrappedValue ? "隐藏" : "显示")\(title)")
    }

    private var menuBarEffects: some View {
        HStack(spacing: 3) {
            Text("光　效")
                .font(.system(size: 11))
                .foregroundStyle(palette.secondary)
                .frame(width: 36, alignment: .leading)
            PanelSegmentedControl(selection: $preferences.menuBarEffect,
                options: MenuBarEffect.allCases.map { ($0, $0.title) },
                label: "菜单栏光效", palette: palette,
                optionHelp: { effect in
                    effect == .iridescent ? "清透玻璃衬托冷色文字，加亮珠光沿字形扫过" : effect.title
                },
                optionIdentifier: { "panel.effect.\($0.rawValue)" })
        }
    }

    private var separator: some View { palette.divider.frame(height: 0.5) }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { detailMotion.cancel(); page = .settings } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10.5))
                    Text("\(intervalTitle(preferences.refreshInterval))刷新 · \(layoutTitle(preferences.menuBarLayout))排版")
                        .font(.system(size: 11))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelPressButtonStyle())
            .foregroundStyle(palette.secondary)
            .accessibilityLabel("调整刷新频率和排版")
            Spacer(minLength: 8)
            Button { NSApp.terminate(nil) } label: {
                PanelHoverPlate(palette: palette, plate: palette.warning.opacity(0.10)) { _ in
                    Label("退出", systemImage: "power")
                        .font(.system(size: 11))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                }
            }
            .buttonStyle(PanelPressButtonStyle())
            .foregroundStyle(palette.warning)
            .padding(.vertical, -3)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 7) {
                Button { page = .overview } label: {
                    PanelHoverPlate(palette: palette, plate: palette.tile, circular: true) { hovered in
                        // 只移动箭头绘制位置，圆框与标题行占位保持不变。
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .offset(x: hovered && !reduceMotion ? -1.6 : 0)
                            .scaleEffect(hovered && !reduceMotion ? 1.08 : 1)
                            .animation(reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0), value: hovered)
                            .frame(width: 24, height: 24)
                    }
                }
                .buttonStyle(PanelPressButtonStyle())
                .foregroundStyle(palette.secondary)
                .accessibilityLabel("返回指标面板")
                .accessibilityIdentifier("panel.back")
                Text("显示与外观").font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            settingSection("刷新频率") {
                PanelSegmentedControl(selection: $preferences.refreshInterval,
                    options: [(0.5, "0.5 秒"), (1.0, "1 秒"), (2.0, "2 秒"), (5.0, "5 秒")],
                    label: "刷新频率", palette: palette)
            }
            settingSection("菜单栏排版") {
                PanelSegmentedControl(selection: $preferences.menuBarLayout,
                    options: [(.auto, "自动"), (.full, "单行"), (.compact, "双行"), (.minimal, "极简")],
                    label: "菜单栏排版", palette: palette)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("玻璃通透")
                    Spacer()
                    Text("\(Int((transparency * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(palette.primary)
                        .contentTransition(.numericText(value: transparency))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.2, extraBounce: 0), value: transparency)
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.secondary)
                PanelGlassSlider(value: $preferences.panelTransparency,
                                 valueText: "\(Int((transparency * 100).rounded()))%")
                    .disabled(reduceTransparency)
                HStack {
                    Text("厚磨砂")
                    Spacer()
                    Text("清透玻璃")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(palette.secondary)
                Text(reduceTransparency ? "系统已开启减少透明度，面板使用实色背景。" : "从柔雾到透亮，读数保持清晰")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondary)
            }
            separator
            VStack(alignment: .leading, spacing: 7) {
                Toggle("开机启动", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                    .toggleStyle(PanelSwitchToggleStyle(palette: palette))
                    .font(.system(size: 11))
                    .accessibilityIdentifier("panel.login")
                if let message = login.errorMessage {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button { preferences.resetDisplaySettings() } label: {
                Text("恢复显示默认值")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(PointerCardButtonStyle(tint: palette.accent, palette: palette,
                                               cornerRadius: 8, edgeLift: 3))
            .help("恢复显示项、刷新频率、排版、菜单栏效果和通透度；保留开机启动设置")
        }
    }

    private func settingSection<Content: View>(_ title: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary)
            content()
        }
    }

    private func intervalTitle(_ interval: Double) -> String {
        String(format: interval == interval.rounded() ? "%.0f 秒" : "%.1f 秒", interval)
    }

    private func layoutTitle(_ layout: MenuBarLayout) -> String {
        switch layout {
        case .auto: return "自动"
        case .full: return "单行"
        case .compact: return "双行"
        case .minimal: return "极简"
        }
    }
}

/// 中性清透磨砂；四项指标分别使用鲜亮的青绿、紫罗兰、琥珀金与湖蓝。
struct PanelPalette {
    let transparency: Double
    var surface: Color { Color(red: 235 / 255, green: 238 / 255, blue: 240 / 255) }
    var softWhite: Color { Color(red: 245 / 255, green: 247 / 255, blue: 249 / 255) }
    var primary: Color { Color(red: 39 / 255, green: 43 / 255, blue: 49 / 255) }
    // 大读数用不带蓝灰偏色的实色；独立于标题、小字和通用提示配色。
    var readingPrimary: Color { Color(white: 20 / 255) }
    var readingWarning: Color { Color(red: 202 / 255, green: 130 / 255, blue: 0 / 255) }
    var readingCritical: Color { Color(red: 217 / 255, green: 45 / 255, blue: 32 / 255) }
    var secondary: Color { Color(red: 99 / 255, green: 105 / 255, blue: 114 / 255) }
    var accent: Color { Color(red: 179 / 255, green: 128 / 255, blue: 67 / 255) }
    var selectedText: Color { Color(red: 133 / 255, green: 83 / 255, blue: 33 / 255) }
    var controlGreen: Color { Color(red: 55 / 255, green: 203 / 255, blue: 105 / 255) }
    var controlGreenText: Color { Color(red: 29 / 255, green: 112 / 255, blue: 60 / 255) }
    var warning: Color { Color(red: 165 / 255, green: 99 / 255, blue: 25 / 255) }
    var critical: Color { Color(red: 181 / 255, green: 57 / 255, blue: 47 / 255) }
    var readingPlate: Color { softWhite.opacity(0.10 * pow(transparency, 4)) }
    var tile: Color { softWhite.opacity(0.12 + 0.10 * (1 - transparency)) }
    var tileBorder: Color { Color(red: 99 / 255, green: 113 / 255, blue: 130 / 255).opacity(0.13) }
    var divider: Color { selectedText.opacity(0.14) }
    func metricTint(_ kind: DashboardDetail) -> Color {
        switch kind {
        case .cpu: return Color(red: 0 / 255, green: 163 / 255, blue: 119 / 255)
        case .gpu: return Color(red: 151 / 255, green: 78 / 255, blue: 235 / 255)
        case .memory: return Color(red: 218 / 255, green: 143 / 255, blue: 12 / 255)
        case .network: return Color(red: 0 / 255, green: 150 / 255, blue: 223 / 255)
        }
    }
    func readingColor(_ kind: DashboardDetail, fraction: Double?, memoryPressure: MemoryPressure) -> Color {
        guard let fraction else { return secondary }
        switch kind {
        case .cpu: return metricColor(fraction)
        case .gpu: return fraction >= 0.97 ? readingCritical : fraction >= 0.92 ? readingWarning : readingPrimary
        case .memory: return memoryColor(memoryPressure)
        case .network: return readingPrimary
        }
    }
    func memoryColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal, .unknown: return readingPrimary
        case .warning: return readingWarning
        case .critical: return readingCritical
        }
    }
    func metricColor(_ fraction: Double) -> Color {
        fraction >= 0.92 ? readingCritical : fraction >= 0.80 ? readingWarning : readingPrimary
    }
}

/// 整片的轻微支撑姿态：边缘始终笔直，不产生局部鼓起。
/// 原生玻璃保持平面采样；前景、裁切和描边使用同一个正交投影。
private enum PanelCardSupport {
    static func transform(_ support: CGPoint, in size: CGSize) -> CGAffineTransform {
        let pitch = Double(support.y) * .pi / 300 // 最大约 0.6°。
        let yaw = Double(support.x) * .pi / 300
        let a = CGFloat(cos(yaw))
        let b = CGFloat(sin(pitch) * sin(yaw))
        let d = CGFloat(cos(pitch))
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        return CGAffineTransform(a: a, b: b, c: 0, d: d,
                                 tx: center.x * (1 - a) + support.x * 0.4,
                                 ty: center.y * (1 - d) - b * center.x + support.y * 0.4)
    }
}

private struct PanelCardSurfaceShape: InsettableShape {
    var cornerRadius: CGFloat
    var support = CGPoint.zero
    var reserve: CGFloat = 0
    var insetAmount: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(support.x, support.y) }
        set { support = CGPoint(x: newValue.first, y: newValue.second) }
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: reserve + insetAmount, dy: reserve + insetAmount)
        guard box.width > 0, box.height > 0 else { return Path() }
        return RoundedRectangle(cornerRadius: max(0, cornerRadius - insetAmount), style: .continuous)
            .path(in: box)
            .applying(PanelCardSupport.transform(support, in: rect.size))
    }
}

/// 玻璃与其前景一起提交给系统，避免背景玻璃把同一控件的文字采入模糊层。
struct PanelGlassStyle: ViewModifier {
    let palette: PanelPalette
    var cornerRadius: CGFloat = 12
    var tint: Color = .white
    var selected = false
    var isControl = false
    var magnetic = false
    var support = CGPoint.zero
    var hoverCenter: UnitPoint? = nil
    var hoverRadius: CGFloat = 120
    var emphasis: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: PanelCardSurfaceShape {
        PanelCardSurfaceShape(cornerRadius: cornerRadius, support: support,
                           reserve: magnetic ? 2 : 0)
    }

    private var edgeStyle: AnyShapeStyle {
        if let hoverCenter {
            return AnyShapeStyle(RadialGradient(
                colors: [tint.opacity(0.38), .white.opacity(0.32), palette.tileBorder],
                center: hoverCenter, startRadius: 0, endRadius: hoverRadius))
        }
        return AnyShapeStyle(LinearGradient(
            colors: [.white.opacity(0.80), selected ? tint.opacity(0.48) : emphasis > 0 ? tint.opacity(emphasis) : palette.tileBorder,
                     .white.opacity(0.38)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var wash: Color {
        tint.opacity(reduceTransparency ? 0.045 : selected ? 0.16 : 0.035)
    }

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(shape.fill(palette.softWhite).overlay(shape.fill(wash)))
            } else if #available(macOS 26.0, *) {
                if magnetic {
                    // 原生材质铺满预留区，再按同一刚性姿态裁切；只有一张可见的卡片。
                    content
                        .background(shape.fill(wash))
                        .glassEffect(palette.transparency < 0.65 ? Glass.regular : Glass.clear,
                                     in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .clipShape(shape)
                } else {
                    content
                        .background(shape.fill(wash))
                        .glassEffect(isControl || palette.transparency < 0.65 ? Glass.regular : Glass.clear,
                                     in: shape)
                }
            } else {
                content.background {
                    PanelMaterial()
                        .overlay(palette.softWhite.opacity(0.16 + 0.16 * (1 - palette.transparency)))
                        .overlay(wash)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay {
            shape.strokeBorder(edgeStyle, lineWidth: selected ? 1 : 0.75)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// 不含前景的旋钮与轨道使用同一材质；不接管控件事件。
private struct PanelGlassSurface: View {
    let palette: PanelPalette
    var cornerRadius: CGFloat = 12
    var tint: Color = .white
    var selected = false
    var isControl = false

    var body: some View {
        Color.clear.modifier(PanelGlassStyle(palette: palette, cornerRadius: cornerRadius,
                                            tint: tint, selected: selected, isControl: isControl))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct PanelReadingPlate: ViewModifier {
    let palette: PanelPalette
    func body(content: Content) -> some View {
        content.padding(6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.readingPlate))
            .padding(-6)
    }
}

/// 整张卡片微幅撑起，轮廓保持笔直；外层命中区域固定。
/// 原生材质保持平面采样，使用统一的刚性姿态，不做局部弯曲。
struct PointerCardHover: ViewModifier {
    var cornerRadius: CGFloat = 10
    var borderTint: Color = .white
    var borderOpacity: Double = 0.80
    var palette: PanelPalette? = nil
    var selected = false
    var emphasis: Double = 0
    var edgeLift: Double = 3
    // 内嵌按钮的卡片独立跟踪固定命中区域，视觉姿态仍使用共享玻璃实现。
    var tracksSubcontrols = false
    var isPressed = false
    var scalesOnPress = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @PanelState private var isHovered = false
    @PanelState private var position = CGPoint.zero
    @PanelState private var cardSize = CGSize.zero

    /// 距离任一边缘 28pt 内逐渐吸附；中心保持平整，四角连续衔接。
    private var edgeAttraction: Double {
        guard isHovered, !reduceMotion, !isPressed else { return 0 }
        let band = min(28, min(cardSize.width, cardSize.height) * 0.38)
        guard band > 0 else { return 0 }
        let distance = min((1 - abs(position.x)) * cardSize.width * 0.5,
                           (1 - abs(position.y)) * cardSize.height * 0.5)
        let proximity = Double(min(max(1 - distance / band, 0), 1))
        return proximity * proximity * (3 - 2 * proximity)
    }

    private func tilt(_ coordinate: CGFloat, span: CGFloat) -> Double {
        guard palette == nil, !reduceMotion, !isPressed, span > 0 else { return 0 }
        return atan2(Double(coordinate) * edgeLift * edgeAttraction, Double(span) * 0.5)
    }

    private var edgeSupport: CGPoint {
        guard palette != nil, !reduceMotion, !isPressed else { return .zero }
        let amount = min(1, edgeLift / 3) * edgeAttraction
        return CGPoint(x: position.x * amount, y: position.y * amount)
    }

    private var reflectionShape: PanelCardSurfaceShape {
        PanelCardSurfaceShape(cornerRadius: cornerRadius, support: edgeSupport,
                           reserve: palette == nil ? 0 : 2)
    }

    @ViewBuilder
    private func surface<V: View>(_ view: V) -> some View {
        if let palette {
            view.modifier(PanelGlassStyle(palette: palette, cornerRadius: cornerRadius,
                                         tint: borderTint, selected: selected, magnetic: true,
                                         support: edgeSupport, hoverCenter: isHovered ? highlightCenter : nil,
                                         hoverRadius: max(1, max(cardSize.width, cardSize.height) * 0.65),
                                         emphasis: emphasis))
        } else {
            view
        }
    }

    private var highlightCenter: UnitPoint {
        reduceMotion ? .center : UnitPoint(x: 0.5 + position.x * 0.5, y: 0.5 + position.y * 0.5)
    }

    private func updatePointer(_ point: CGPoint?) {
        guard let point else {
            isHovered = false
            position = .zero
            return
        }
        guard cardSize.width > 0, cardSize.height > 0 else { return }
        if !isHovered { isHovered = true }
        if !reduceMotion {
            position = CGPoint(x: min(max(point.x / cardSize.width, 0), 1) * 2 - 1,
                               y: min(max(point.y / cardSize.height, 0), 1) * 2 - 1)
        }
    }

    func body(content: Content) -> some View {
        ZStack {
            surface(content
                .transformEffect(PanelCardSupport.transform(edgeSupport, in: cardSize))
                .background {
                    GeometryReader { geometry in
                        reflectionShape
                            .fill(RadialGradient(colors: [.white.opacity(0.32), .white.opacity(0.08), .clear],
                                                 center: highlightCenter, startRadius: 0,
                                                 endRadius: max(geometry.size.width * 0.42, geometry.size.height)))
                            .opacity(isHovered ? 1 : 0)
                    }
                    .allowsHitTesting(false)
                })
                .overlay {
                    if palette == nil {
                        reflectionShape.strokeBorder(borderTint.opacity(borderOpacity), lineWidth: 0.75)
                            .opacity(isHovered ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                }
                .rotation3DEffect(.radians(tilt(position.y, span: cardSize.height)),
                                  axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.5)
                .rotation3DEffect(.radians(tilt(-position.x, span: cardSize.width)),
                                  axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
                .scaleEffect(reduceMotion || !isPressed || !scalesOnPress ? 1 : 0.985)
                .animation(reduceMotion ? nil :
                    .interactiveSpring(response: isHovered ? 0.20 : 0.24,
                                       dampingFraction: 1, blendDuration: 0), value: position)
                .animation(.easeOut(duration: reduceMotion ? 0.10 : isHovered ? 0.12 : 0.18), value: isHovered)
                .animation(reduceMotion ? .easeOut(duration: 0.08) :
                    .smooth(duration: isPressed ? 0.08 : 0.18, extraBounce: 0), value: isPressed)
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.size, initial: true) { _, size in
                        if cardSize != size { cardSize = size }
                    }
            }
            .allowsHitTesting(false)
        }
        .background {
            if tracksSubcontrols {
                PanelCardPointerTracking(didMove: updatePointer)
            }
        }
        .onContinuousHover { phase in
            guard !tracksSubcontrols else { return }
            switch phase {
            case .active(let point): updatePointer(point)
            case .ended: updatePointer(nil)
            }
        }
        .onDisappear {
            isHovered = false
            position = .zero
        }
    }
}

/// 指针区域固定在未变换的卡片外层，子按钮的 SwiftUI 悬停不会截断位置跟踪。
private struct PanelCardPointerTracking: NSViewRepresentable {
    let didMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView(didMove: didMove) }
    func updateNSView(_ view: TrackingView, context: Context) { view.didMove = didMove }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { view.clearTracking() }

    final class TrackingView: NSView {
        var didMove: (CGPoint?) -> Void
        private var pointerArea: NSTrackingArea?
        private var motionMonitor: Any?
        override var isFlipped: Bool { true }

        init(didMove: @escaping (CGPoint?) -> Void) {
            self.didMove = didMove
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let motionMonitor { NSEvent.removeMonitor(motionMonitor) }
            motionMonitor = nil
            guard window != nil else { return }
            motionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                self.didMove(self.bounds.contains(point) ? point : nil)
                return event
            }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // inVisibleRect 自动跟随可见区域；位置动画不应重建追踪区。
            guard pointerArea == nil else { return }
            let area = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil)
            pointerArea = area
            addTrackingArea(area)
        }
        override func mouseEntered(with event: NSEvent) { move(event) }
        override func mouseMoved(with event: NSEvent) { move(event) }
        override func mouseExited(with event: NSEvent) { didMove(nil) }
        private func move(_ event: NSEvent) { didMove(convert(event.locationInWindow, from: nil)) }
        func clearTracking() {
            if let motionMonitor { NSEvent.removeMonitor(motionMonitor) }
            motionMonitor = nil
            if let pointerArea { removeTrackingArea(pointerArea) }
            pointerArea = nil
        }
        deinit {
            if let motionMonitor { NSEvent.removeMonitor(motionMonitor) }
        }
    }
}

/// 指标卡片的命中区域保持原尺寸，视觉反馈只作用于内部绘制。
private struct PointerCardButtonStyle: ButtonStyle {
    let tint: Color
    let palette: PanelPalette
    var selected = false
    var cornerRadius: CGFloat = 12
    var edgeLift: Double = 3

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PointerCardHover(cornerRadius: cornerRadius, borderTint: tint,
                                       borderOpacity: 0.80, palette: palette, selected: selected,
                                       edgeLift: edgeLift, isPressed: configuration.isPressed))
    }
}

/// 按压只改变绘制，不改变按钮布局。
private struct PanelPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scalesContent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && scalesContent && !reduceMotion ? 0.985 : 1)
            .brightness(configuration.isPressed ? 0.015 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.08) :
                .smooth(duration: configuration.isPressed ? 0.08 : 0.18, extraBounce: 0),
                value: configuration.isPressed)
    }
}

/// 小按钮仅在悬停时显露玻璃与细边，前景和命中范围始终保持不变。
private struct PanelHoverPlate<Content: View>: View {
    let palette: PanelPalette
    let plate: Color
    var cornerRadius: CGFloat = 8
    var circular = false
    @ViewBuilder let content: (Bool) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @PanelState private var isHovered = false

    private var shape: AnyShape {
        circular ? AnyShape(Circle()) :
            AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    var body: some View {
        content(isHovered)
            .background {
                GeometryReader { geometry in
                    // 圆形控件使用等边尺寸；玻璃、反光和轮廓共享同一裁切。
                    shape.fill(plate)
                        .modifier(PanelGlassStyle(palette: palette,
                            cornerRadius: circular ? min(geometry.size.width, geometry.size.height) / 2 : cornerRadius,
                            isControl: true))
                        .clipShape(shape)
                        .opacity(isHovered ? 1 : 0)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: isHovered ? 0.16 : 0.24), value: isHovered)
    }
}

/// 玻璃通透滑块：自绘轨道与玻璃滑钮，拖动即时跟手，外部重置时平滑滑动。
/// 无障碍由原生 Slider 提供，角色、数值与调节动作与改动前一致。
private struct PanelGlassSlider: View {
    @Binding var value: Double
    let valueText: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @PanelState private var isHovered = false
    @PanelState private var isDragging = false
    @FocusState private var isFocused: Bool

    /// 透明玻璃槽加厚，滑钮略高于轨道；整体仍保留紧凑的设置页尺度。
    private let knobWidth: CGFloat = 32
    private let knobHeight: CGFloat = 22
    private let trackHeight: CGFloat = 16
    private let step = 0.01

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - knobWidth)
            let fraction = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Color.clear
                    .modifier(PanelSliderClearGlass())
                    .frame(height: trackHeight)
                    .overlay {
                        PanelSliderStarlight(reduced: reduceMotion || !isEnabled,
                                             active: isHovered || isDragging,
                                             engaged: isDragging || isFocused,
                                             dragging: isDragging,
                                             progress: fraction)
                            .frame(height: trackHeight)
                            .mask {
                                Canvas { context, size in
                                    context.fill(Path(CGRect(x: 0, y: 0,
                                        width: travel * fraction + knobWidth / 2,
                                        height: size.height)), with: .color(.white))
                                    let width = knobWidth * knobScale
                                    let height = knobHeight * knobScale
                                    let cutout = CGRect(x: travel * fraction - (width - knobWidth) / 2,
                                                        y: (size.height - height) / 2,
                                                        width: width, height: height)
                                    context.blendMode = .destinationOut
                                    context.fill(Path(roundedRect: cutout, cornerRadius: height / 2),
                                                 with: .color(.white))
                                }
                            }
                            .clipShape(Capsule())
                            .opacity(fraction > 0 ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                knob.offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .animation(isDragging || reduceMotion ? nil : .smooth(duration: 0.23, extraBounce: 0), value: fraction)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    isDragging = true
                    isFocused = true
                    setValue((drag.location.x - knobWidth / 2) / travel)
                }
                .onEnded { _ in isDragging = false })
        }
        .frame(height: 24)
        .onHover { isHovered = $0 }
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .focusable(isEnabled)
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) { nudge(-step) }
        .onKeyPress(.downArrow) { nudge(-step) }
        .onKeyPress(.rightArrow) { nudge(step) }
        .onKeyPress(.upArrow) { nudge(step) }
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...1, step: step)
                .accessibilityLabel("玻璃通透")
                .accessibilityValue(valueText)
                .accessibilityIdentifier("panel.transparency")
        }
    }

    private var knobScale: CGFloat {
        reduceMotion ? 1 : isDragging ? 1.06 : isHovered ? 1.03 : 1
    }

    private var knob: some View {
        Color.clear
            .modifier(PanelSliderClearGlass())
            .overlay {
                Capsule().strokeBorder(.white.opacity(isFocused ? 0.95 : isHovered || isDragging ? 0.80 : 0.50),
                                        lineWidth: isFocused ? 1.25 : 0.75)
                    .allowsHitTesting(false)
            }
            .frame(width: knobWidth, height: knobHeight)
            .scaleEffect(knobScale)
            .animation(reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0), value: isDragging)
            .animation(reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0), value: isHovered)
    }

    private func setValue(_ proposed: Double) {
        let rounded = (min(max(proposed, 0), 1) * 100).rounded() / 100
        if value != rounded { value = rounded }
    }

    private func nudge(_ delta: Double) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        setValue(value + delta)
        return .handled
    }
}

/// 专用于通透滑条：不使用 palette 染色，轨道与滑钮始终为 clear 玻璃。
private struct PanelSliderClearGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(Capsule().fill(Color(white: 0.94)))
            } else if #available(macOS 26.0, *) {
                content.glassEffect(Glass.clear, in: Capsule())
            } else {
                content.background { PanelMaterial().clipShape(Capsule()) }
            }
        }
        .overlay {
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.78), .white.opacity(0.14), .white.opacity(0.44)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.65)
                .allowsHitTesting(false)
        }
    }
}

/// 蓝紫与冰青交织在玻璃内部，珠光细线与星点缓慢流动；减少动态效果时静止。
private struct PanelSliderStarlight: View {
    let reduced: Bool
    let active: Bool
    let engaged: Bool
    let dragging: Bool
    let progress: Double
    @StateObject private var particleClock = PanelSliderParticleClock()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduced)) { timeline in
            let time = reduced ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let particleTime = reduced ? 0 : particleClock.phase(at: timeline.date.timeIntervalSinceReferenceDate)
            Canvas { context, size in
                guard size.width > 0, size.height > 0 else { return }
                drawColorField(context: &context, size: size, time: time)
                let wake = reduced ? 0 : particleClock.wake(at: timeline.date.timeIntervalSinceReferenceDate)
                let feedback = reduced ? 0 : particleClock.feedback(at: timeline.date.timeIntervalSinceReferenceDate)
                drawFlowDust(context: &context, size: size, time: particleTime, wake: wake, feedback: feedback)
                for index in 0..<286 {
                    let seed = Double(index)
                    let base = random(seed + 1)
                    let direction = random(seed + 71) < 0.5 ? -1.0 : 1.0
                    let rate = 0.24 + random(seed + 137) * 0.83
                    let angle = random(seed + 293) * .pi * 2
                    // 每颗星点有独立速度、相位与回转尺度；反射边界避免堆在槽边。
                    let drift = (0.025 + random(seed + 409) * 0.055) * sin(particleTime * rate * direction + angle)
                              + 0.026 * sin(particleTime * (rate * 1.73) - angle * 2.1)
                    let rawU = base + drift
                    let front = (size.width - 32) * progress / size.width
                    let nearKnob = exp(-pow((rawU - front) / 0.15, 2))
                    let displaced = rawU + wake * nearKnob * (0.65 + 0.65 * cos(angle + particleTime * 0.9))
                    let u = reflected(displaced)
                    let v = reflected(0.5 + 0.32 * sin(particleTime * rate * 0.83 + angle * 1.7)
                                          + 0.19 * sin(particleTime * rate * 1.31 - angle)
                                          + wake * nearKnob * 3.2 * sin(angle + particleTime * 1.1))
                    let point = CGPoint(x: 2 + u * max(size.width - 4, 1),
                                        y: 1.5 + v * max(size.height - 3, 1))
                    let pulse = reduced ? 0.75 : 0.68 + 0.32 * sin(particleTime * (0.65 + rate) + angle)
                    let density = index % 31 == 0 ? 1.0 : index % 7 == 0 ? 0.78 : 0.56
                    let opacity = min(1, ((active || engaged) ? 0.95 : 0.80) * pulse
                                            + nearKnob * feedback * 0.55) * density
                    let radius: CGFloat = index % 31 == 0 ? 0.60 : index % 7 == 0 ? 0.38 : 0.24
                    let halo = radius * (3.0 + nearKnob * feedback * 1.5)
                    let core = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                     width: radius * 2, height: radius * 2))
                    // 少数星点有微小光晕，细尘保持锐利，避免密度增加后蒙上一层白雾。
                    if index % 7 == 0 || nearKnob * feedback > 0.3 {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo,
                                                            width: halo * 2, height: halo * 2)),
                                     with: .radialGradient(Gradient(colors: [.white.opacity(opacity * 0.24), .clear]),
                                                           center: point, startRadius: 0, endRadius: halo))
                    }
                    context.fill(core, with: .color(.white.opacity(opacity)))
                    if index % 31 == 0 {
                        let ray: CGFloat = 1.15 + nearKnob * feedback * 0.45
                        var rays = Path()
                        rays.move(to: CGPoint(x: point.x - ray, y: point.y))
                        rays.addLine(to: CGPoint(x: point.x + ray, y: point.y))
                        rays.move(to: CGPoint(x: point.x, y: point.y - ray * 1.2))
                        rays.addLine(to: CGPoint(x: point.x, y: point.y + ray * 1.2))
                        context.stroke(rays, with: .color(.white.opacity(opacity * 0.85)),
                                       style: StrokeStyle(lineWidth: 0.35, lineCap: .round))
                    }
                }
            }
        }
        .onChange(of: engaged, initial: true) { _, engaged in particleClock.setEngaged(engaged) }
        .onChange(of: progress, initial: true) { _, progress in particleClock.move(to: progress, dragging: dragging) }
        .accessibilityHidden(true)
    }

    private func random(_ seed: Double) -> Double {
        let value = sin(seed * 127.1 + 311.7) * 43758.5453
        return value - floor(value)
    }

    private func reflected(_ value: Double) -> Double {
        let wrapped = value - floor(value / 2) * 2
        return wrapped <= 1 ? wrapped : 2 - wrapped
    }

    private func drawFlowDust(context: inout GraphicsContext, size: CGSize, time: Double, wake: Double, feedback: Double) {
        let front = (size.width - 32) * progress
        // 短小流光散成星点簇，方向各异；近滑钮的星尘随拖动扬起。
        for index in 0..<48 {
            let seed = Double(index + 701)
            let rate = 0.3 + random(seed) * 0.9
            let phase = random(seed + 17) * .pi * 2
            let x = size.width * reflected(random(seed + 31) + 0.06 * sin(time * rate + phase))
            let y = 1.5 + (size.height - 3) * reflected(0.5 + 0.39 * sin(time * rate * 0.71 - phase))
            let response = exp(-pow((x - front) / 42, 2))
            let angle = phase + 1.8 * sin(time * rate * 0.63 + phase)
            let length = 0.8 + random(seed + 43) * 1.4 + response * feedback * 1.8
            let point = CGPoint(x: x + wake * response * 65, y: y)
            let opacity = 0.20 + 0.16 * (0.5 + 0.5 * sin(time * rate + phase)) + response * feedback * 0.30
            var spark = Path()
            spark.move(to: point)
            spark.addLine(to: CGPoint(x: point.x + cos(angle) * length, y: point.y + sin(angle) * length))
            context.stroke(spark, with: .color(.white.opacity(opacity)),
                           style: StrokeStyle(lineWidth: 0.40, lineCap: .round))
        }
        // 无色光脉冲只在滑钮旁短暂出现，反馈强度来自实际位移，反向拖动也有响应。
        if feedback > 0.005 {
            let center = CGPoint(x: front - 5, y: size.height * 0.5)
            let rect = CGRect(x: front - 43, y: 0, width: 48, height: size.height)
            context.fill(Path(rect), with: .radialGradient(
                Gradient(colors: [.white.opacity(feedback * 0.22), .white.opacity(feedback * 0.05), .clear]),
                center: center, startRadius: 0, endRadius: 35))
            let ripple = Path(ellipseIn: CGRect(x: front - 18 - feedback * 8, y: -2,
                                               width: 30 + feedback * 10, height: size.height + 4))
            context.stroke(ripple, with: .color(.white.opacity(feedback * 0.38)), lineWidth: 0.65)
        }
    }

    private func drawColorField(context: inout GraphicsContext, size: CGSize, time: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let width = max(24, (size.width - 32) * progress)
        let phase = time * 0.36
        let blue = Color(red: 0.20, green: 0.49, blue: 1)
        let periwinkle = Color(red: 0.49, green: 0.38, blue: 1)
        let violet = Color(red: 0.61, green: 0.23, blue: 0.96)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [blue.opacity(0.98), periwinkle, violet.opacity(0.98)]),
            startPoint: .zero, endPoint: CGPoint(x: width, y: size.height * 0.45)))

        // 用有色透光层交织，避免大面积 screen 叠加把蓝紫洗成雾白。
        let fields: [(Double, Double, Color)] = [
            (0.08 + progress * 0.22 + 0.06 * sin(phase * 0.7), 0.9, Color(red: 0.10, green: 0.90, blue: 1)),
            (0.25 + progress * 0.34 + 0.08 * sin(phase * 0.6 + 1.5), 0.1, Color(red: 0.83, green: 0.39, blue: 1)),
            (0.50 + progress * 0.28 + 0.07 * sin(phase * 0.8 + 3), 0.85, Color(red: 0.22, green: 0.70, blue: 1))
        ]
        var light = context
        light.blendMode = .normal
        for (x, y, color) in fields {
            let center = CGPoint(x: width * x, y: size.height * y)
            light.fill(Path(rect), with: .radialGradient(
                Gradient(colors: [color.opacity(0.68), color.opacity(0.24), .clear]),
                center: center, startRadius: 0, endRadius: width * 0.34))
        }

        // 宽而柔的交叠色带，再用细光线勾出玻璃内部的珠光层。
        for index in 0..<3 {
            let offset = Double(index) * 1.8
            let y0 = size.height * (0.5 + 0.32 * sin(phase + offset))
            let y1 = size.height * (0.5 + 0.38 * sin(phase * 0.8 + offset + 2))
            var ribbon = Path()
            ribbon.move(to: CGPoint(x: -12, y: y0))
            ribbon.addCurve(to: CGPoint(x: width + 12, y: y1),
                control1: CGPoint(x: width * 0.33, y: size.height * (index == 1 ? 1.6 : -0.5)),
                control2: CGPoint(x: width * 0.67, y: size.height * (index == 1 ? -0.5 : 1.6)))
            var glow = context
            glow.blendMode = .screen
            glow.addFilter(.blur(radius: 1.25))
            let color = index == 1 ? Color(red: 0.24, green: 0.93, blue: 1) : Color(red: 0.79, green: 0.48, blue: 1)
            glow.stroke(ribbon, with: .color(color.opacity(0.30)), lineWidth: 3.5)
            context.stroke(ribbon, with: .color(.white.opacity(index == 1 ? 0.18 : 0.11)),
                           style: StrokeStyle(lineWidth: 0.55, lineCap: .round))
        }
        context.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0.10), location: 0),
                             .init(color: .clear, location: 0.26),
                             .init(color: Color(red: 0.20, green: 0.16, blue: 0.47).opacity(0.08), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }
}

/// 时间积分保持光点位置连续；选中时平滑提速，拖动尾流按方向自然衰减。
private final class PanelSliderParticleClock: ObservableObject {
    private var anchorTime = Date.timeIntervalSinceReferenceDate
    private var anchorPhase = 0.0
    private var sourceSpeed = 1.0
    private var targetSpeed = 1.0
    private let rampDuration = 0.40
    private var lastProgress: Double?
    private var wakeTime = Date.timeIntervalSinceReferenceDate
    private var wakeStrength = 0.0
    private var wakeSource = 0.0
    private var feedbackSource = 0.0
    private var feedbackStrength = 0.0

    func phase(at time: Double) -> Double {
        let elapsed = max(0, time - anchorTime)
        let u = min(elapsed / rampDuration, 1)
        let integratedRamp = rampDuration * (u * u * u - 0.5 * u * u * u * u)
        let ramp = sourceSpeed * min(elapsed, rampDuration) + (targetSpeed - sourceSpeed) * integratedRamp
        return anchorPhase + ramp + targetSpeed * max(0, elapsed - rampDuration)
    }

    func setEngaged(_ engaged: Bool) {
        let speed = engaged ? 3.2 : 1.0
        guard speed != targetSpeed else { return }
        let now = Date.timeIntervalSinceReferenceDate
        let u = min(max((now - anchorTime) / rampDuration, 0), 1)
        anchorPhase = phase(at: now)
        sourceSpeed += (targetSpeed - sourceSpeed) * u * u * (3 - 2 * u)
        targetSpeed = speed
        anchorTime = now
    }

    func move(to progress: Double, dragging: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        if let lastProgress, dragging, abs(progress - lastProgress) > 0.00001 {
            wakeSource = wake(at: now)
            feedbackSource = feedback(at: now)
            wakeStrength = min(max(wakeSource + (progress - lastProgress) * 2.2, -0.09), 0.09)
            feedbackStrength = min(feedbackSource + abs(progress - lastProgress) * 8, 1)
            wakeTime = now
        }
        lastProgress = progress
    }

    func wake(at time: Double) -> Double {
        let elapsed = max(0, time - wakeTime)
        let ramp = exp(-elapsed / 0.05)
        return wakeSource * ramp + wakeStrength * exp(-elapsed / 0.42) * (1 - ramp)
    }

    func feedback(at time: Double) -> Double {
        let elapsed = max(0, time - wakeTime)
        let ramp = exp(-elapsed / 0.045)
        return feedbackSource * ramp + feedbackStrength * exp(-elapsed / 0.30) * (1 - ramp)
    }
}

/// 开机启动开关：保留 Toggle 的标签与无障碍语义，外观换成面板内的滑动开关。
private struct PanelSwitchToggleStyle: ToggleStyle {
    let palette: PanelPalette

    func makeBody(configuration: Configuration) -> some View {
        PanelSwitch(configuration: configuration, palette: palette)
    }
}

private struct PanelSwitch: View {
    let configuration: ToggleStyleConfiguration
    let palette: PanelPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @PanelState private var isHovered = false

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 9) {
                configuration.label
                ZStack {
                    PanelGlassSurface(palette: palette, cornerRadius: 10,
                                      tint: configuration.isOn ? palette.accent : .white,
                                      selected: configuration.isOn)
                        .overlay {
                            Capsule().strokeBorder(palette.accent.opacity(isHovered ? 0.65 : 0.15),
                                                   lineWidth: isHovered ? 1 : 0.5)
                                .allowsHitTesting(false)
                        }
                    PanelGlassSurface(palette: palette, cornerRadius: 8, isControl: true)
                        .frame(width: 16, height: 16)
                        .scaleEffect(isHovered && !reduceMotion ? 1.10 : 1)
                        .offset(x: configuration.isOn ? 12 : -12)
                }
                .frame(width: 44, height: 20)
                .animation(reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0), value: configuration.isOn)
                .animation(reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0), value: isHovered)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressButtonStyle())
        .accessibilityAddTraits(.isToggle)
        .onHover { isHovered = $0 }
    }
}

/// 紧凑控件共用位置感知悬浮；布局固定，分段选中底板继续独立滑动。
private struct PanelControlButtonStyle: ButtonStyle {
    let tint: Color
    let selected: Bool
    var palette: PanelPalette? = nil
    var scalesContent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PointerCardHover(cornerRadius: 6, borderTint: tint,
                                       borderOpacity: selected ? 0.80 : 0.60, palette: palette,
                                       selected: selected, edgeLift: 2,
                                       isPressed: configuration.isPressed, scalesOnPress: scalesContent))
    }
}

private struct PanelSegmentedControl<Value: Equatable>: View {
    @Binding var selection: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let options: [(Value, String)]
    let label: String
    let palette: PanelPalette
    var optionHelp: ((Value) -> String)? = nil
    var optionIdentifier: ((Value) -> String)? = nil

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = selection == option.0
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: 11, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? palette.selectedText : palette.secondary)
                        .transaction { $0.animation = nil }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelControlButtonStyle(tint: palette.accent, selected: selected,
                                                     scalesContent: false))
                .help(optionHelp?(option.0) ?? option.1)
                .accessibilityLabel("\(label)，\(option.1)")
                .accessibilityValue(selected ? "已选择" : "未选择")
                .accessibilityIdentifier(optionIdentifier?(option.0) ?? "\(label).\(index)")
            }
        }
        .background {
            GeometryReader { geometry in
                if !options.isEmpty {
                    let slotWidth = max(0, (geometry.size.width - CGFloat(options.count - 1) * 3) / CGFloat(options.count))
                    let selectedIndex = options.firstIndex { $0.0 == selection } ?? 0
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.accent.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.60), lineWidth: 0.75))
                        .frame(width: slotWidth, height: geometry.size.height)
                        .offset(x: CGFloat(selectedIndex) * (slotWidth + 3))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.23, extraBounce: 0), value: selection)
                }
            }
            .allowsHitTesting(false)
        }
        .padding(3)
        .modifier(PanelGlassStyle(palette: palette, cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.tileBorder, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// 外观从真实 AppKit 视图读取；popover 中 SwiftUI 的 colorScheme 曾与窗口外观不一致。
/// 覆盖原生弹窗全部轮廓，箭头与正文来自同一层玻璃 / 颜色。
struct PanelWindowSurface: View {
    @ObservedObject var preferences: Preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transparency: Double {
        Preferences.normalizedPanelTransparency(preferences.panelTransparency)
    }
    private var usesClearGlass: Bool { transparency >= 0.65 }

    var body: some View {
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                ZStack {
                    Rectangle().fill(.thickMaterial)
                        .opacity(pow(max(0, (0.45 - transparency) / 0.45), 2) * 0.85)
                }
                .glassEffect(usesClearGlass ? Glass.clear : Glass.regular, in: Rectangle())
            } else {
                PanelMaterial().overlay {
                    PanelPalette(transparency: reduceTransparency ? 0 : transparency)
                        .surface.opacity(reduceTransparency ? 1 : 0.22 * (1 - transparency))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: usesClearGlass)
    }
}

private struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PanelMaterialView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private final class PanelMaterialView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 迷你曲线：百分比固定量程，网速跟随峰值；上传使用虚线以便区分两条趋势。
struct Sparkline: View {
    let series: [[Double]]
    let colors: [Color]
    let upperBound: Double?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let bound = resolvedBound
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height - 0.5))
                    path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                }
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                if let first = series.first, first.count > 1 {
                    areaPath(first, in: size, bound: bound)
                        .fill(LinearGradient(colors: [colors.first?.opacity(0.12) ?? .clear, .clear],
                                             startPoint: .top, endPoint: .bottom))
                }
                ForEach(Array(series.enumerated()), id: \.offset) { index, values in
                    linePath(values, in: size, bound: bound)
                        .stroke(colors.isEmpty ? .clear : colors[min(index, colors.count - 1)],
                                style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                   lineJoin: .round, dash: index == 0 ? [] : [3, 2]))
                }
            }
        }
    }

    private var resolvedBound: Double {
        if let upperBound, upperBound > 0 { return upperBound }
        let peak = series.flatMap { $0 }.filter { $0.isFinite }.max() ?? 0
        return max(peak * 1.2, 1024)
    }
    private func points(_ values: [Double], in size: CGSize, bound: Double) -> [CGPoint] {
        let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { index, value in
            let normalized = value.isFinite ? min(max(value / bound, 0), 1) : 0
            return CGPoint(x: CGFloat(index) * step,
                           y: size.height - CGFloat(normalized) * max(size.height - 2, 0) - 1)
        }
    }
    private func linePath(_ values: [Double], in size: CGSize, bound: Double) -> Path {
        var path = Path()
        let pts = points(values, in: size, bound: bound)
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.6, y: first.y)) }
        else { for point in pts.dropFirst() { path.addLine(to: point) } }
        return path
    }
    private func areaPath(_ values: [Double], in size: CGSize, bound: Double) -> Path {
        var path = linePath(values, in: size, bound: bound)
        let pts = points(values, in: size, bound: bound)
        guard let first = pts.first, let last = pts.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.addLine(to: CGPoint(x: first.x, y: size.height))
        path.closeSubpath()
        return path
    }
}

extension NSColor {
    var swiftUIColor: Color { Color(nsColor: self) }
}
