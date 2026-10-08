import SwiftUI
import Foundation

private typealias DeviceState<Value> = SwiftUI.State<Value>

/// 彩蛋只改变绘制效果；机器信息栏始终按原有内容测量尺寸。
struct DeviceInformationCard: View {
    let modelName: String
    let processorDescription: String
    let memoryDescription: String
    let palette: PanelPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @DeviceState private var charge = 0
    @DeviceState private var lastTap: TimeInterval?
    @DeviceState private var comboStartedAt: TimeInterval?
    @DeviceState private var cooldownUntil: TimeInterval = 0
    @DeviceState private var tapGeneration = 0
    @DeviceState private var celebrationGeneration = 0
    @DeviceState private var isCelebrating = false

    private struct TapPose {
        var scale: CGFloat = 1
        var haloScale: CGFloat = 1
        var haloOpacity: Double = 0
    }

    private struct CelebrationPose {
        var lift: CGFloat = 0
        var starProgress: CGFloat = 0
        var starOpacity: Double = 0
    }

    var body: some View {
        Button(action: receiveTap) { cardContent }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: charge)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isCelebrating)
            .accessibilityLabel("设备信息，\(modelName)，\(processorDescription)，\(memoryDescription)")
            .accessibilityValue(isCelebrating ? "今天也在努力运行" : (charge > 0 ? "充能 \(charge) / 6" : ""))
            .accessibilityIdentifier("panel.device")
            // SwiftUI 在视图消失或下一次点击时取消等待，只保留当前这一轮。
            .task(id: tapGeneration) {
                guard charge > 0, !isCelebrating else { return }
                do { try await Task.sleep(nanoseconds: 1_200_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                charge = 0
                lastTap = nil
                comboStartedAt = nil
            }
            .task(id: celebrationGeneration) {
                guard isCelebrating else { return }
                do { try await Task.sleep(nanoseconds: 1_800_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                isCelebrating = false
                charge = 0
                lastTap = nil
                comboStartedAt = nil
            }
            .onDisappear {
                charge = 0
                lastTap = nil
                comboStartedAt = nil
                cooldownUntil = 0
                isCelebrating = false
            }
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 8) {
            deviceIcon
                .frame(width: 17)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(modelName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.primary)
                Text(processorDescription)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondary)
                Text(memoryDescription)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondary)
                    .opacity(isCelebrating ? 0 : 1)
                    .overlay(alignment: .leading) {
                        Text("今天也在努力运行 ✦")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(palette.accent)
                            .fixedSize()
                            .opacity(isCelebrating ? 1 : 0)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.tile))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.accent.opacity(isCelebrating ? 0.30 : Double(charge) * 0.025),
                              lineWidth: 0.75)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var deviceIcon: some View {
        // Animator 内容闭包为 Sendable，捕获环境值快照而非隔离的视图状态。
        let motionReduced = reduceMotion
        let accent = palette.accent
        return Image(systemName: modelName.localizedCaseInsensitiveContains("book") ? "laptopcomputer" : "desktopcomputer")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(charge > 0 ? palette.accent : palette.secondary)
            .keyframeAnimator(initialValue: TapPose(), trigger: tapGeneration) { icon, pose in
                icon
                    .scaleEffect(motionReduced ? 1 : pose.scale)
                    .overlay {
                        Circle()
                            .strokeBorder(accent, lineWidth: 0.7)
                            .frame(width: 22, height: 22)
                            .scaleEffect(pose.haloScale)
                            .opacity(motionReduced ? 0 : pose.haloOpacity)
                            .allowsHitTesting(false)
                    }
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.94, duration: 0.04)
                    CubicKeyframe(1.07, duration: 0.07)
                    CubicKeyframe(1, duration: 0.12)
                }
                KeyframeTrack(\.haloScale) {
                    MoveKeyframe(0.8)
                    LinearKeyframe(1.5, duration: 0.23)
                }
                KeyframeTrack(\.haloOpacity) {
                    MoveKeyframe(0.32)
                    LinearKeyframe(0, duration: 0.23)
                }
            }
            .keyframeAnimator(initialValue: CelebrationPose(), trigger: celebrationGeneration) { icon, pose in
                icon
                    .offset(y: motionReduced ? 0 : pose.lift)
                    .overlay {
                        if !motionReduced {
                            DeviceCelebrationStars(progress: pose.starProgress, color: accent)
                                .opacity(pose.starOpacity)
                        }
                    }
            } keyframes: { _ in
                KeyframeTrack(\.lift) {
                    CubicKeyframe(-4, duration: 0.12)
                    CubicKeyframe(0.7, duration: 0.14)
                    CubicKeyframe(0, duration: 0.14)
                }
                KeyframeTrack(\.starProgress) {
                    MoveKeyframe(0)
                    CubicKeyframe(1, duration: 0.65)
                }
                KeyframeTrack(\.starOpacity) {
                    MoveKeyframe(0)
                    LinearKeyframe(0.85, duration: 0.10)
                    LinearKeyframe(0, duration: 0.55)
                }
            }
            .overlay(alignment: .top) {
                HStack(spacing: 2) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(palette.accent)
                            .frame(width: 3, height: 3)
                            .opacity(charge >= (index + 1) * 2 ? 0.85 : 0.12)
                    }
                }
                .opacity(charge > 0 ? 1 : 0)
                .offset(y: 22)
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }

    private func receiveTap() {
        // 使用单调时钟；冷却期间仍有点击回弹，但不会堆叠庆祝。
        let now = ProcessInfo.processInfo.systemUptime
        tapGeneration &+= 1
        guard !isCelebrating, now >= cooldownUntil else { return }
        if lastTap == nil || now - (lastTap ?? now) > 1.2 ||
            now - (comboStartedAt ?? now) > 3.2 {
            charge = 0
            comboStartedAt = now
        }
        lastTap = now
        charge += 1
        if charge >= 6 {
            isCelebrating = true
            celebrationGeneration &+= 1
            cooldownUntil = now + 2.4
        }
    }
}

private struct DeviceCelebrationStars: View {
    let progress: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            star(size: 6, x: -8 - progress * 3, y: -5 - progress * 5)
            star(size: 5, x: 10 + progress * 2, y: -7 - progress * 5)
            star(size: 4, x: -8 - progress * 2, y: 7 + progress * 3)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func star(size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .scaleEffect(0.65 + progress * 0.35)
            .rotationEffect(.degrees(Double(progress) * 18))
            .offset(x: x, y: y)
    }
}
