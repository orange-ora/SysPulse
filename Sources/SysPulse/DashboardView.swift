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

    init(monitor: SystemMonitor, preferences: Preferences,
         initialPage: DashboardPage = .overview, initialDetail: DashboardDetail? = nil,
         usesWindowSurface: Bool = false, naturalSizeDidChange: ((CGSize) -> Void)? = nil) {
        self.monitor = monitor
        self.preferences = preferences
        self.usesWindowSurface = usesWindowSurface
        self.naturalSizeDidChange = naturalSizeDidChange
        _page = State(initialValue: initialPage)
        _selectedDetail = State(initialValue: initialDetail)
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
                .modifier(PanelReadingPlate(palette: palette))
                .modifier(PointerCardHover(cornerRadius: 12, borderTint: palette.accent,
                                           borderOpacity: 0.80, edgeLift: 6))
            metricGrid
            if let detail = selectedDetail {
                detailPanel(detail)
            }
            deviceInformationPanel
            metricToggles.modifier(PanelReadingPlate(palette: palette))
            menuBarEffects.modifier(PanelReadingPlate(palette: palette)).padding(.top, 6)
            separator
            footer
                .modifier(PanelReadingPlate(palette: palette))
                .padding(.vertical, 6)
                .modifier(PointerCardHover(cornerRadius: 12, borderTint: palette.accent,
                                           borderOpacity: 0.80, edgeLift: 9))
                .padding(.vertical, -6)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.accent)
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
            Button { page = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelPressButtonStyle())
            .foregroundStyle(palette.secondary)
            .help("显示与外观")
            .accessibilityLabel("打开显示与外观设置")
            .accessibilityIdentifier("panel.settings")
        }
        .padding(.vertical, 3)
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
            .background(tileBackground(kind, selected: selectedDetail == kind))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PointerCardButtonStyle(tint: palette.metricTint(kind)))
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
            .background(tileBackground(.network, selected: selectedDetail == .network))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PointerCardButtonStyle(tint: palette.metricTint(.network)))
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

    private func tileBackground(_ kind: DashboardDetail, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(palette.tile)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.metricTint(kind).opacity(selected ? 0.10 : 0.055))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? palette.metricTint(kind).opacity(0.45) : palette.tileBorder,
                                  lineWidth: selected ? 1 : 0.5)
            }
    }

    private func toggleDetail(_ detail: DashboardDetail) {
        selectedDetail = selectedDetail == detail ? nil : detail
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
                Text(detailDescription(kind))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { selectedDetail = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(PanelPressButtonStyle())
            .foregroundStyle(palette.secondary)
            .accessibilityLabel("收起明细")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileBackground(kind, selected: false))
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
        .modifier(PointerCardHover())
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

    private func controlBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(selected ? palette.controlGreen.opacity(0.28) : palette.tile)
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
            .background(controlBackground(selected: isOn.wrappedValue))
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelControlButtonStyle(tint: palette.controlGreen, selected: isOn.wrappedValue))
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
            Button { page = .settings } label: {
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
                Label("退出", systemImage: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(PanelPressButtonStyle())
            .foregroundStyle(palette.warning)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 7) {
                Button { page = .overview } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 23, height: 24)
                        .contentShape(Rectangle())
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
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.secondary)
                Slider(value: $preferences.panelTransparency, in: 0...1, step: 0.01)
                    .accessibilityLabel("玻璃通透")
                    .accessibilityValue("\(Int((transparency * 100).rounded()))%")
                    .accessibilityIdentifier("panel.transparency")
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
                    .toggleStyle(.switch)
                    .controlSize(.small)
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(palette.tile))
            }
            .buttonStyle(PointerCardButtonStyle(tint: palette.accent, cornerRadius: 8, edgeLift: 9))
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

/// 中性清透磨砂；四项指标分别使用青绿、紫罗兰、赭金与湖蓝。
struct PanelPalette {
    let transparency: Double
    var surface: Color { Color(red: 235 / 255, green: 238 / 255, blue: 240 / 255) }
    var softWhite: Color { Color(red: 245 / 255, green: 247 / 255, blue: 249 / 255) }
    var primary: Color { Color(red: 54 / 255, green: 51 / 255, blue: 47 / 255) }
    var secondary: Color { Color(red: 119 / 255, green: 107 / 255, blue: 93 / 255) }
    var accent: Color { Color(red: 179 / 255, green: 128 / 255, blue: 67 / 255) }
    var selectedText: Color { Color(red: 133 / 255, green: 83 / 255, blue: 33 / 255) }
    var controlGreen: Color { Color(red: 55 / 255, green: 203 / 255, blue: 105 / 255) }
    var controlGreenText: Color { Color(red: 29 / 255, green: 112 / 255, blue: 60 / 255) }
    var warning: Color { Color(red: 165 / 255, green: 99 / 255, blue: 25 / 255) }
    var critical: Color { Color(red: 181 / 255, green: 57 / 255, blue: 47 / 255) }
    var readingPlate: Color { softWhite.opacity(0.60 * pow(transparency, 4)) }
    var tile: Color { softWhite.opacity(0.36 + 0.28 * transparency) }
    var tileBorder: Color { Color.white.opacity(0.36) }
    var divider: Color { selectedText.opacity(0.14) }
    func metricTint(_ kind: DashboardDetail) -> Color {
        switch kind {
        case .cpu: return Color(red: 51 / 255, green: 127 / 255, blue: 111 / 255)
        case .gpu: return Color(red: 126 / 255, green: 99 / 255, blue: 165 / 255)
        case .memory: return Color(red: 166 / 255, green: 120 / 255, blue: 47 / 255)
        case .network: return Color(red: 53 / 255, green: 123 / 255, blue: 157 / 255)
        }
    }
    func readingColor(_ kind: DashboardDetail, fraction: Double?, memoryPressure: MemoryPressure) -> Color {
        guard let fraction else { return secondary }
        switch kind {
        case .cpu: return metricColor(fraction)
        case .gpu: return primary // 满载可能是正常工作，不按占用率告警。
        case .memory: return memoryColor(memoryPressure)
        case .network: return primary
        }
    }
    func memoryColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal, .unknown: return primary
        case .warning: return warning
        case .critical: return critical
        }
    }
    func metricColor(_ fraction: Double) -> Color {
        fraction >= 0.92 ? critical : fraction >= 0.80 ? warning : primary
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

/// 在固定布局外层追踪鼠标，避免倾斜后边缘反复触发进出，并让内部按钮接收点击。
private struct PointerCardHover: ViewModifier {
    var cornerRadius: CGFloat = 10
    var borderTint: Color = .white
    var borderOpacity: Double = 0.80
    var edgeLift: Double = 9
    var isPressed = false
    var scalesOnPress = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @PanelState private var isHovered = false
    @PanelState private var position = CGPoint.zero
    @PanelState private var cardSize = CGSize.zero

    /// 按目标抬起幅度和实际宽高换算角度，保持四方向对称。
    private func tilt(_ coordinate: CGFloat, span: CGFloat) -> Double {
        guard !reduceMotion, !isPressed, span > 0 else { return 0 }
        return atan2(Double(coordinate) * edgeLift, Double(span) * 0.5)
    }

    private var highlightCenter: UnitPoint {
        reduceMotion ? .center : UnitPoint(x: 0.5 + position.x * 0.5, y: 0.5 + position.y * 0.5)
    }

    func body(content: Content) -> some View {
        ZStack {
            content
                .background {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(RadialGradient(colors: [.white.opacity(0.55), .white.opacity(0.14), .clear],
                                                 center: highlightCenter, startRadius: 0,
                                                 endRadius: max(geometry.size.width * 0.42, geometry.size.height)))
                            .opacity(isHovered ? 1 : 0)
                    }
                    .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(RadialGradient(
                            colors: [borderTint.opacity(borderOpacity), borderTint.opacity(0.08)],
                            center: highlightCenter, startRadius: 0,
                            endRadius: max(1, max(cardSize.width, cardSize.height) * 0.65)),
                            lineWidth: 0.75)
                        .opacity(isHovered ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .rotation3DEffect(.radians(tilt(position.y, span: cardSize.height)),
                                  axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.5)
                .rotation3DEffect(.radians(tilt(-position.x, span: cardSize.width)),
                                  axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
                .scaleEffect(reduceMotion || !isPressed || !scalesOnPress ? 1 : 0.985)
                .brightness(isPressed ? 0.015 : 0)
                .animation(reduceMotion ? nil :
                    .interactiveSpring(response: 0.22, dampingFraction: 1, blendDuration: 0), value: position)
                .animation(.easeOut(duration: reduceMotion ? 0.10 : isHovered ? 0.16 : 0.26), value: isHovered)
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
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                guard cardSize.width > 0, cardSize.height > 0 else { return }
                if !isHovered { isHovered = true }
                if !reduceMotion {
                    position = CGPoint(
                        x: min(max(point.x / cardSize.width, 0), 1) * 2 - 1,
                        y: min(max(point.y / cardSize.height, 0), 1) * 2 - 1)
                }
            case .ended:
                isHovered = false
                position = .zero
            }
        }
        .onDisappear {
            isHovered = false
            position = .zero
        }
    }
}

/// 指标卡片的命中区域保持原尺寸，视觉反馈只作用于内部绘制。
private struct PointerCardButtonStyle: ButtonStyle {
    let tint: Color
    var cornerRadius: CGFloat = 12
    var edgeLift: Double = 9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PointerCardHover(cornerRadius: cornerRadius, borderTint: tint,
                                       borderOpacity: 0.80, edgeLift: edgeLift,
                                       isPressed: configuration.isPressed))
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

/// 紧凑控件共用位置感知悬浮；布局固定，分段选中底板继续独立滑动。
private struct PanelControlButtonStyle: ButtonStyle {
    let tint: Color
    let selected: Bool
    var scalesContent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PointerCardHover(cornerRadius: 6, borderTint: tint,
                                       borderOpacity: selected ? 0.80 : 0.60, edgeLift: 3,
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
                        .fill(palette.accent.opacity(0.23))
                        .frame(width: slotWidth, height: geometry.size.height)
                        .offset(x: CGFloat(selectedIndex) * (slotWidth + 3))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.23, extraBounce: 0), value: selection)
                }
            }
            .allowsHitTesting(false)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.tile))
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
