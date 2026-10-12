import AppKit
import Darwin
import Foundation
import ImageIO
import ServiceManagement
import SwiftUI

// 只替换内存压力读取结果；不触发系统警告、不改内核状态。
enum MemoryPressureFixture {
    static var enabled = false
    static var level: Int32 = 1
    static var fail = false
    static var size = MemoryLayout<Int32>.size
}
func sysctlbyname(_ name: UnsafePointer<CChar>, _ old: UnsafeMutableRawPointer?,
                  _ size: UnsafeMutablePointer<Int>?, _ new: UnsafeMutableRawPointer?,
                  _ newSize: Int) -> Int32 {
    if MemoryPressureFixture.enabled, String(cString: name) == "kern.memorystatus_vm_pressure_level" {
        if MemoryPressureFixture.fail { errno = ENOENT; return -1 }
        old?.storeBytes(of: MemoryPressureFixture.level, as: Int32.self)
        size?.pointee = MemoryPressureFixture.size
        return 0
    }
    return Darwin.sysctlbyname(name, old, size, new, newSize)
}

// Shadow only this module's sysctl calls. All non-process fixtures forward to Darwin.
// No kernel state is changed. This verifies the original ProcessMonitor implementation.
enum ProcessFixture {
    static var enabled = false
    static var count = 23
    static var growOnFill = false
    static var fail = false
    static var fillCalls = 0
}
func sysctl(_ mib: UnsafeMutablePointer<Int32>?, _ mibCount: UInt32,
            _ old: UnsafeMutableRawPointer?, _ size: UnsafeMutablePointer<Int>?,
            _ new: UnsafeMutableRawPointer?, _ newSize: Int) -> Int32 {
    if ProcessFixture.enabled, let mib, mibCount >= 3,
       mib[0] == CTL_KERN, mib[1] == KERN_PROC, mib[2] == KERN_PROC_ALL, let size {
        if ProcessFixture.fail { errno = EIO; return -1 }
        let stride = MemoryLayout<kinfo_proc>.stride
        guard let old else { size.pointee = (ProcessFixture.count + 5) * stride; return 0 }
        ProcessFixture.fillCalls += 1
        if ProcessFixture.growOnFill {
            ProcessFixture.growOnFill = false
            ProcessFixture.count += 10
            size.pointee = ProcessFixture.count * stride
            errno = ENOMEM
            return -1
        }
        let actual = ProcessFixture.count * stride
        guard size.pointee >= actual else { size.pointee = actual; errno = ENOMEM; return -1 }
        old.initializeMemory(as: UInt8.self, repeating: 0, count: actual)
        size.pointee = actual
        return 0
    }
    return Darwin.sysctl(mib, mibCount, old, size, new, newSize)
}

@main struct RegressionTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        passed += 1
        print("PASS: \(message)")
    }
    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.00001 }

    static func memoryPressure() {
        MemoryPressureFixture.enabled = true
        defer {
            MemoryPressureFixture.enabled = false
            MemoryPressureFixture.fail = false
            MemoryPressureFixture.size = MemoryLayout<Int32>.size
        }
        let monitor = SystemMonitor()
        for (level, expected) in [(Int32(1), MemoryPressure.normal), (2, .warning), (4, .critical)] {
            MemoryPressureFixture.level = level
            check(MemoryMonitor.readPressure() == expected, "memory pressure: system level \(level) maps to \(expected.title)")
            monitor.sampleOnce()
            check(monitor.snapshot.memoryPressure == expected, "memory pressure: sampler publishes \(expected.title)")
        }
        for level in [Int32(0), 3, 5, 6, 7, -1] {
            MemoryPressureFixture.level = level
            check(MemoryMonitor.readPressure() == .unknown, "memory pressure: unknown system level \(level) is not inferred")
        }
        MemoryPressureFixture.level = 4
        MemoryPressureFixture.fail = true
        monitor.sampleOnce()
        check(monitor.snapshot.memoryPressure == .unknown, "memory pressure: read failure clears previous critical status")
        MemoryPressureFixture.fail = false
        MemoryPressureFixture.size = 2
        check(MemoryMonitor.readPressure() == .unknown, "memory pressure: malformed payload size is rejected")
        MemoryPressureFixture.size = MemoryLayout<Int32>.size
        MemoryPressureFixture.level = 1
        monitor.sampleOnce()
        check(monitor.snapshot.memoryPressure == .normal, "memory pressure: valid normal status recovers after failed read")

        let palette = PanelPalette(transparency: 0.71)
        check(palette.memoryColor(.normal) == palette.readingPrimary && palette.memoryColor(.unknown) == palette.readingPrimary,
              "memory pressure: panel uses neutral text for normal/unknown")
        check(palette.memoryColor(.warning) == palette.readingWarning && palette.memoryColor(.critical) == palette.readingCritical,
              "memory pressure: panel warning/critical colors follow system state")
        check(StatusItemController.memoryTint(for: .normal) == .labelColor && StatusItemController.memoryTint(for: .unknown) == .labelColor,
              "memory pressure: menu bar uses neutral text for normal/unknown")
        check(StatusItemController.memoryTint(for: .warning) == .systemOrange && StatusItemController.memoryTint(for: .critical) == .systemRed,
              "memory pressure: menu bar warning/critical colors follow system state")
        check(StatusItemController.tint(for: 0.79) == .labelColor && StatusItemController.tint(for: 0.80) == .systemOrange &&
              StatusItemController.tint(for: 0.92) == .systemRed,
              "CPU: existing 80/92 percent warning thresholds remain unchanged")

        let suite = "SysPulse.Regression.MemoryPressure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.showCPU = false
        preferences.showGPU = false
        preferences.showNetwork = false
        preferences.showMemory = true
        var snapshot = MetricsSnapshot()
        func image(_ fraction: Double, _ pressure: MemoryPressure, _ density: MenuBarDensity,
                   _ appearance: NSAppearance, effect: MenuBarEffect = .off) -> NSImage {
            snapshot.memoryFraction = fraction
            snapshot.memoryPressure = pressure
            return MenuBarImage.render(snapshot: snapshot, preferences: preferences,
                                       appearance: appearance, density: density, effect: effect, effectElapsed: 0)!
        }
        func bytes(_ image: NSImage) -> Data { image.tiffRepresentation! }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            for density in [MenuBarDensity.full, .compact, .minimal] {
                let highNormal = image(0.99, .normal, density, appearance)
                let highUnknown = image(0.99, .unknown, density, appearance)
                let highWarning = image(0.99, .warning, density, appearance)
                let highCritical = image(0.99, .critical, density, appearance)
                check(bytes(highNormal) == bytes(highUnknown) && bytes(highNormal) != bytes(highWarning) &&
                      bytes(highWarning) != bytes(highCritical),
                      "memory rendering \(name.rawValue)/\(density): 99% is neutral unless system pressure warns")
                let lowNormal = image(0.40, .normal, density, appearance)
                let lowCritical = image(0.40, .critical, density, appearance)
                check(bytes(lowNormal) != bytes(lowCritical),
                      "memory rendering \(name.rawValue)/\(density): critical pressure warns even at 40% usage")
                check(highNormal.size == highWarning.size && highWarning.size == highCritical.size &&
                      lowNormal.size == lowCritical.size,
                      "memory rendering \(name.rawValue)/\(density): pressure changes preserve layout geometry")
                let rainbowNormal = image(0.99, .normal, density, appearance, effect: .iridescent)
                let rainbowCritical = image(0.99, .critical, density, appearance, effect: .iridescent)
                check(rainbowNormal.size == rainbowCritical.size && bytes(rainbowNormal) != bytes(rainbowCritical),
                      "memory rendering \(name.rawValue)/\(density): star glass preserves geometry and system pressure warning colors")
            }
        }
        snapshot.memoryPressure = .critical
        check(MenuBarImage.tooltip(snapshot: snapshot).contains("压力：严重"), "memory pressure: tooltip communicates critical state")
        snapshot.memoryPressure = .unknown
        check(MenuBarImage.tooltip(snapshot: snapshot).contains("压力：未知"), "memory pressure: tooltip communicates unknown state")
    }

    static func metricColors() {
        let palette = PanelPalette(transparency: 0.71)
        for (fraction, panelColor, menuColor) in [
            (0.0, palette.readingPrimary, NSColor.labelColor),
            (0.80, palette.readingPrimary, NSColor.labelColor),
            (0.9199, palette.readingPrimary, NSColor.labelColor),
            (0.92, palette.readingWarning, NSColor.systemYellow),
            (0.9699, palette.readingWarning, NSColor.systemYellow),
            (0.97, palette.readingCritical, NSColor.systemRed),
            (1.0, palette.readingCritical, NSColor.systemRed)
        ] {
            for pressure in [MemoryPressure.normal, .warning, .critical, .unknown] {
                check(palette.readingColor(.gpu, fraction: fraction, memoryPressure: pressure) == panelColor,
                      "GPU panel: \(fraction * 100)% uses its own 92/97 thresholds with \(pressure) memory pressure")
            }
            check(StatusItemController.gpuTint(for: fraction) == menuColor,
                  "GPU menu bar: \(fraction * 100)% uses its own 92/97 thresholds")
        }
        check(palette.readingColor(.gpu, fraction: nil, memoryPressure: .normal) == palette.secondary,
              "GPU panel: missing data retains its secondary text color")
        check(palette.readingColor(.cpu, fraction: 0.80, memoryPressure: .normal) == palette.readingWarning &&
              palette.readingColor(.cpu, fraction: 0.92, memoryPressure: .normal) == palette.readingCritical,
              "CPU panel: warning thresholds remain independent of GPU changes")
        check(palette.readingColor(.memory, fraction: 0.99, memoryPressure: .normal) == palette.readingPrimary &&
              palette.readingColor(.memory, fraction: 0.99, memoryPressure: .unknown) == palette.readingPrimary,
              "memory panel: 99% usage with normal or unknown pressure stays neutral")
        check(palette.readingColor(.memory, fraction: 0.40, memoryPressure: .warning) == palette.readingWarning &&
              palette.readingColor(.memory, fraction: 0.40, memoryPressure: .critical) == palette.readingCritical,
              "memory panel: low utilization does not mask system warning or critical pressure")

        let suite = "SysPulse.Regression.MetricColors.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.showMemory = false
        preferences.showNetwork = false
        func render(gpu: Bool, usage: Double, density: MenuBarDensity, appearance: NSAppearance) -> NSImage {
            preferences.showGPU = gpu
            preferences.showCPU = !gpu
            var snapshot = MetricsSnapshot()
            snapshot.gpuUsage = usage * 100
            snapshot.cpuUsage = usage
            snapshot.memoryPressure = .critical
            return MenuBarImage.render(snapshot: snapshot, preferences: preferences, appearance: appearance,
                                       density: density, effect: .off)!
        }
        // Plain text is achromatic; optional hue checks distinguish yellow from red glyphs.
        func coloredPixels(_ image: NSImage, yellow: Bool? = nil) -> Int {
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.1 else { continue }
                    let maximum = max(max(color.redComponent, color.greenComponent), color.blueComponent)
                    let minimum = min(min(color.redComponent, color.greenComponent), color.blueComponent)
                    guard maximum - minimum > 0.12 else { continue }
                    if let yellow {
                        let matches = yellow
                            ? color.greenComponent > color.redComponent * 0.65 && color.greenComponent > color.blueComponent * 1.5
                            : color.redComponent > color.greenComponent * 1.5 && color.redComponent > color.blueComponent * 1.5
                        if matches { count += 1 }
                    } else {
                        count += 1
                    }
                }
            }
            return count
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            for density in [MenuBarDensity.full, .compact, .minimal] {
                let gpu80 = render(gpu: true, usage: 0.80, density: density, appearance: appearance)
                let gpuBelow92 = render(gpu: true, usage: 0.9199, density: density, appearance: appearance)
                let gpu92 = render(gpu: true, usage: 0.92, density: density, appearance: appearance)
                let gpuBelow97 = render(gpu: true, usage: 0.9699, density: density, appearance: appearance)
                let gpu97 = render(gpu: true, usage: 0.97, density: density, appearance: appearance)
                let gpu100 = render(gpu: true, usage: 1.0, density: density, appearance: appearance)
                check(coloredPixels(gpu80) == 0 && coloredPixels(gpuBelow92) == 0,
                      "GPU rendering \(name.rawValue)/\(density): below 92% stays neutral")
                let yellowCount = coloredPixels(gpu92, yellow: true)
                let yellowRedFringe = coloredPixels(gpu92, yellow: false)
                let redCount = coloredPixels(gpu97, yellow: false)
                let redYellowFringe = coloredPixels(gpu97, yellow: true)
                print("GPU-HUE \(name.rawValue)/\(density): yellow=\(yellowCount), red fringe=\(yellowRedFringe); red=\(redCount), yellow fringe=\(redYellowFringe)")
                check(yellowCount > max(yellowRedFringe * 5, 0) && coloredPixels(gpuBelow97, yellow: true) > 0,
                      "GPU rendering \(name.rawValue)/\(density): 92% to below 97% shows yellow warning")
                check(redCount > max(redYellowFringe * 5, 0) && coloredPixels(gpu100, yellow: false) > 0,
                      "GPU rendering \(name.rawValue)/\(density): 97% and above shows critical warning")
                check([gpuBelow92, gpu92, gpuBelow97, gpu97, gpu100].allSatisfy { $0.size == gpu80.size },
                      "GPU rendering \(name.rawValue)/\(density): warning changes preserve width")
                check(coloredPixels(render(gpu: false, usage: 0.80, density: density, appearance: appearance)) > 0,
                      "CPU rendering \(name.rawValue)/\(density): 80% still has its warning color")
                check(coloredPixels(render(gpu: false, usage: 1.0, density: density, appearance: appearance)) > 0,
                      "CPU rendering \(name.rawValue)/\(density): 100% still has its critical color")
            }
        }
    }

    static func network() {
        let a = NetworkInterfaceID(index: 1, name: "en0", linkAddress: [1, 2])
        let b = NetworkInterfaceID(index: 2, name: "en1", linkAddress: [3, 4])
        func bytes(_ rx: UInt64, _ tx: UInt64 = 0,
                   _ width: NetworkInterfaceCounters.Width = .automatic) -> NetworkInterfaceCounters {
            NetworkInterfaceCounters(received: rx, sent: tx, width: width)
        }
        var wrap = NetworkAccumulator()
        wrap.ingest([a: bytes(4294967280), b: bytes(100)], at: 1000)
        wrap.ingest([a: bytes(16), b: bytes(120)], at: 1002)
        check(wrap.totalDown == 52 && close(wrap.downSpeed, 26), "network: independent wrap adds 52B, not 4GiB")

        var both = NetworkAccumulator()
        both.ingest([a: bytes(4294967280), b: bytes(4294967280)], at: 1000)
        both.ingest([a: bytes(16), b: bytes(16)], at: 1002)
        check(both.totalDown == 64, "network: two independent wraps add 64B")

        var plug = NetworkAccumulator()
        plug.ingest([a: bytes(1000), b: bytes(2000)], at: 1000)
        plug.ingest([a: bytes(1000)], at: 1002)
        check(plug.totalDown == 0, "network: unplug does not add phantom bytes")
        plug.ingest([a: bytes(1000), b: bytes(2147483648)], at: 1004)
        check(plug.totalDown == 0, "network: newly attached interface establishes baseline")
        plug.ingest([a: bytes(1000), b: bytes(2147483668)], at: 1006)
        check(plug.totalDown == 20, "network: attached interface counts only subsequent traffic")

        var replaced = NetworkAccumulator()
        replaced.ingest([a: bytes(1000)], at: 1000)
        let changed = NetworkInterfaceID(index: 1, name: "en0", linkAddress: [9, 9])
        replaced.ingest([changed: bytes(1000000)], at: 1002)
        check(replaced.totalDown == 0, "network: reused index with changed hardware starts a new baseline")

        var reset = NetworkAccumulator()
        reset.ingest([a: bytes(1000000, 2000)], at: 1000)
        reset.ingest([a: bytes(100, 2200)], at: 1002)
        check(reset.totalDown == 0 && reset.totalUp == 200, "network: non-boundary reset discards only reset direction")

        var short = NetworkAccumulator()
        short.ingest([a: bytes(1000)], at: 1000)
        check(!short.ingest([a: bytes(1100)], at: 1000.01), "clock: short interval is rejected")
        short.ingest([a: bytes(1200)], at: 1000.1)
        check(short.totalDown == 200 && close(short.downSpeed, 2000), "clock: short interval preserves bytes and time baseline")
        check(!short.ingest([a: bytes(1500)], at: 999), "clock: backward input is rejected without moving baseline")
        short.ingest([a: bytes(1600)], at: 1002.1)
        check(short.totalDown == 600, "clock: next valid interval includes all unaccounted bytes")
        check(!short.ingest([a: bytes(2000)], at: .nan), "clock: nonfinite time is rejected")

        var gap = NetworkAccumulator()
        gap.ingest([a: bytes(1000, 1000, .bits32)], at: 1000)
        gap.ingest([a: bytes(2000, 2000, .bits32)], at: 1040)
        check(gap.totalDown == 0 && gap.totalUp == 0, "network: unobservable 32bit long gap rebaselines conservatively")
        gap.ingest([a: bytes(2100, 2200, .bits32)], at: 1042)
        check(gap.totalDown == 100 && gap.totalUp == 200, "network: sampling resumes from long-gap baseline")

        var wide = NetworkAccumulator()
        wide.ingest([a: bytes(5000000000, 6000000000)], at: 1000)
        wide.ingest([a: bytes(5000001000, 6000002000)], at: 1040)
        check(wide.totalDown == 1000 && wide.totalUp == 2000, "network: known 64bit counters remain accurate across long gap")
        wide.ingest([a: bytes(9000001000, 6000002000)], at: 1042)
        check(wide.totalDown == 4000001000, "network: valid fast 64bit increments are not truncated or capped")
        wide.ingest([a: bytes(100, 100)], at: 1044)
        check(wide.totalDown == 4000001000, "network: remembered 64bit counter reset is not a 32bit wrap")
    }

    static func networkParser() {
        func interface(_ index: UInt16, _ name: String, _ rx: UInt64,
                       precedingAddress: Bool = false, includeLink: Bool = true) -> [UInt8] {
            var header = if_msghdr2()
            header.ifm_version = UInt8(RTM_VERSION)
            header.ifm_type = UInt8(RTM_IFINFO2)
            header.ifm_index = index
            header.ifm_data.ifi_ibytes = rx
            header.ifm_data.ifi_obytes = 123
            var addresses: [UInt8] = []
            if includeLink {
                header.ifm_addrs = RTA_IFP
                if precedingAddress {
                    header.ifm_addrs |= RTA_DST
                    addresses += [16, UInt8(AF_INET)] + [UInt8](repeating: 0, count: 14)
                }
                let text = Array(name.utf8)
                let mac: [UInt8] = [1, 2, 3, 4, 5, 6]
                let size = 8 + text.count + mac.count
                var link: [UInt8] = [UInt8(size), UInt8(AF_LINK), UInt8(index & 255), UInt8(index >> 8), 6,
                                    UInt8(text.count), UInt8(mac.count), 0]
                link += text + mac
                while link.count % 4 != 0 { link.append(0) }
                addresses += link
            }
            header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size + addresses.count)
            return withUnsafeBytes(of: &header) { Array($0) } + addresses
        }
        let shortAddress: [UInt8] = [4, 0, UInt8(RTM_VERSION), UInt8(RTM_NEWADDR)]
        let messages = shortAddress + interface(1, "en0", 456) + shortAddress + interface(2, "lo0", 999)
        let parsed = messages.withUnsafeBytes { NetworkMonitor.parseCounters($0, length: $0.count) }
        check(parsed?.count == 1 && parsed?.first?.value.received == 456 && parsed?.first?.key.linkAddress.count == 6,
              "network parser: skips short NEWADDR messages and filters nonphysical interfaces")
        let preceding = interface(1, "en0", 789, precedingAddress: true)
        let second = preceding.withUnsafeBytes { NetworkMonitor.parseCounters($0, length: $0.count) }
        check(second?.first?.value.received == 789, "network parser: resolves IFP after earlier address bitmap entries")
        let fallback = interface(1, "", 42, includeLink: false)
        let third = fallback.withUnsafeBytes { NetworkMonitor.parseCounters($0, length: $0.count, resolveName: { _ in "en0" }) }
        check(third?.first?.value.received == 42, "network parser: missing link address uses current-sample name fallback")
        let truncated = Array(messages.dropLast())
        let invalid = truncated.withUnsafeBytes { NetworkMonitor.parseCounters($0, length: $0.count) }
        check(invalid == nil, "network parser: malformed snapshot is rejected, not zeroed")

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        let queried = Darwin.sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0)
        check(queried == 0 && size > 0, "network parser: real kernel route snapshot is available")
        var buffer = [UInt8](repeating: 0, count: size)
        let filled = buffer.withUnsafeMutableBytes { Darwin.sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        check(filled == 0, "network parser: real kernel route snapshot fills successfully")
        let real = buffer.withUnsafeBytes { NetworkMonitor.parseCounters($0, length: size, resolveName: { index in
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
            return if_indextoname(UInt32(index), &name) == nil ? nil : String(cString: name)
        }) }
        check(real != nil, "network parser: real multi-message kernel snapshot parses successfully")
        print("NOTE: real physical interfaces: \(real!.keys.map { $0.name }.sorted())")
    }

    static func gpu() {
        check(GPUMonitor.readUtilization(from: [:]) == nil, "GPU readiness: an empty statistics dictionary is not supported usage")
        check(GPUMonitor.readUtilization(from: ["Device Utilization %": 0]) == 0, "GPU readiness: zero utilization is valid")
        check(GPUMonitor.readUtilization(from: ["Device Utilization %": Double.nan]) == nil,
              "GPU readiness: nonfinite utilization is rejected")
        check(GPUMonitor.readUtilization(from: ["Device Utilization %": -1, "GPU Activity(%)": 12]) == 12,
              "GPU readiness: invalid primary counter can use a supported fallback")
        check(GPUMonitor.readUtilization(from: ["Device Utilization %": 150]) == 100,
              "GPU readiness: percentages are bounded for history and rendering")
        var snapshot = MetricsSnapshot()
        let pending = StatusItemController.gpuWidthState(for: snapshot, showGPU: true)
        check(!pending.hasSegment && !pending.isTrustworthy, "GPU width: missing pending data is not trusted")
        snapshot.gpuUsage = 0
        let ready = StatusItemController.gpuWidthState(for: snapshot, showGPU: true)
        check(ready.hasSegment && ready.isTrustworthy, "GPU width: actual zero usage is a present segment")
        snapshot.gpuUsage = nil
        snapshot.gpuUnavailable = true
        let unavailable = StatusItemController.gpuWidthState(for: snapshot, showGPU: true)
        check(!unavailable.hasSegment && unavailable.isTrustworthy, "GPU width: confirmed unsupported device can measure GPU-free widths")
        snapshot.gpuUnavailable = false
        let hidden = StatusItemController.gpuWidthState(for: snapshot, showGPU: false)
        check(!hidden.hasSegment && hidden.isTrustworthy, "GPU width: hidden GPU does not block layout")

        let prefs = Preferences.shared
        check(prefs.showCPU && prefs.showGPU && prefs.showNetwork && prefs.showMemory,
              "test process has isolated default metric preferences")
        let missing = MenuBarImage.render(snapshot: snapshot, preferences: prefs,
                                         appearance: NSAppearance(named: .aqua), density: .full)!.size.width
        snapshot.gpuUsage = 80
        let present = MenuBarImage.render(snapshot: snapshot, preferences: prefs,
                                         appearance: NSAppearance(named: .aqua), density: .full)!.size.width
        check(present > missing, "GPU width: recovery actually changes rendered shape")

        let monitor = SystemMonitor()
        monitor.sampleOnce()
        let expected = (monitor.snapshot.gpuUsage ?? 0) / 100
        check(close(monitor.gpuHistory.last!, expected), "GPU history: latest original sample is normalized to 0...1")
        check(monitor.gpuHistory.count == 60, "GPU history: fixed history capacity is preserved")
        if monitor.snapshot.gpuUsage == nil { print("NOTE: live GPU counter unavailable; history assertion used nil→0 fallback.") }
    }

    static func displayPreferences() {
        let suiteName = "SysPulse.Regression.DisplayPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        check(close(prefs.panelTransparency, 0.71) && prefs.showNetwork && prefs.showCPU &&
              prefs.showGPU && prefs.showMemory && prefs.refreshInterval == 2 &&
              prefs.menuBarLayout == .auto && prefs.menuBarEffect == .diffuse,
              "display preferences: fresh isolated suite has captured display defaults")
        // 已存旧默认值和其他有效配置均应保留，不被新默认值覆盖。
        prefs.refreshInterval = 1
        prefs.panelTransparency = 0.30
        prefs.menuBarEffect = .off
        let oldDefaults = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
        check(oldDefaults.refreshInterval == 1 && close(oldDefaults.panelTransparency, 0.30) &&
              oldDefaults.menuBarEffect == .off,
              "display preferences: stored previous defaults remain unchanged")
        prefs.showNetwork = false
        prefs.showCPU = false
        prefs.showGPU = false
        prefs.showMemory = false
        prefs.refreshInterval = 5
        prefs.panelTransparency = 0.52
        prefs.menuBarLayout = .compact
        prefs.menuBarEffect = .glow
        let custom = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
        check(!custom.showNetwork && !custom.showCPU && !custom.showGPU && !custom.showMemory &&
              custom.refreshInterval == 5 && close(custom.panelTransparency, 0.52) &&
              custom.menuBarLayout == .compact && custom.menuBarEffect == .glow,
              "display preferences: existing glow and other custom display settings remain unchanged")
        // 原有范围内的存值与新增高通透值都应原样持久化、重载。
        for value in [0.30, 0.52, 0.70, 0.95, 1.0] {
            prefs.panelTransparency = value
            let reloaded = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
            check(close(defaults.double(forKey: Preferences.Keys.panelTransparency), value) &&
                  close(reloaded.panelTransparency, value),
                  "display preferences: transparency \(value) persists and reloads")
        }
        check(MenuBarEffect.allCases.map { $0.rawValue } == ["off", "glow", "diffuse", "iridescent"],
              "display preferences: all four background choices retain independent stored IDs")
        check(MenuBarEffect.allCases.map { $0.title } == ["无背景", "流光", "光晕", "星点"],
              "display preferences: existing backgrounds remain available alongside liquid glass")
        for effect in [MenuBarEffect.off, .glow, .diffuse, .iridescent] {
            defaults.set(effect.rawValue, forKey: Preferences.Keys.menuBarEffect)
            let reloaded = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
            check(reloaded.menuBarEffect == effect &&
                  defaults.string(forKey: Preferences.Keys.menuBarEffect) == effect.rawValue,
                  "display preferences: stored \(effect.rawValue) reloads without changing the selected background")
            prefs.menuBarEffect = effect
            check(prefs.menuBarEffect == effect &&
                  defaults.string(forKey: Preferences.Keys.menuBarEffect) == effect.rawValue,
                  "display preferences: assigning \(effect.rawValue) preserves and stores that independent choice")
        }
        prefs.menuBarEffect = .iridescent
        let iridescent = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
        check(defaults.string(forKey: Preferences.Keys.menuBarEffect) == "iridescent" &&
              iridescent.menuBarEffect == .iridescent,
              "display preferences: iridescent effect persists and reloads in isolated suite")
        defaults.set("breathe", forKey: Preferences.Keys.menuBarEffect)
        let migrated = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
        check(migrated.menuBarEffect == .iridescent &&
              defaults.string(forKey: Preferences.Keys.menuBarEffect) == "iridescent",
              "display preferences: retired breathe choice migrates to iridescent and persists")

        for (invalid, expected) in [(Double.nan, 0.71), (Double.infinity, 0.71),
                                    (-Double.infinity, 0.71), (-0.2, 0.0), (1.2, 1.0)] {
            defaults.set(invalid, forKey: Preferences.Keys.panelTransparency)
            let repaired = Preferences(defaults: defaults)
            check(close(repaired.panelTransparency, expected) &&
                  close(defaults.double(forKey: Preferences.Keys.panelTransparency), expected) &&
                  close(Preferences.normalizedPanelTransparency(invalid), expected),
                  "display preferences: invalid stored transparency \(invalid) normalizes to \(expected)")
        }
        prefs.panelTransparency = .nan
        check(close(prefs.panelTransparency, 0.71) &&
              close(defaults.double(forKey: Preferences.Keys.panelTransparency), 0.71),
              "display preferences: nonfinite assignment persists safe default")
        prefs.panelTransparency = 2
        check(close(prefs.panelTransparency, 1.0) &&
              close(defaults.double(forKey: Preferences.Keys.panelTransparency), 1.0),
              "display preferences: out-of-range assignment is clamped in memory and storage")

        prefs.showNetwork = false
        prefs.showCPU = false
        prefs.showGPU = false
        prefs.showMemory = false
        prefs.refreshInterval = 5
        prefs.menuBarLayout = .minimal
        prefs.menuBarEffect = .off
        defaults.set("keep", forKey: "unrelatedPreference")
        let service = SMAppService.mainApp
        let loginCalls = (service.registerCalls, service.unregisterCalls)
        let loginStatus = service.status
        prefs.resetDisplaySettings()
        check(prefs.showNetwork && prefs.showCPU && prefs.showGPU && prefs.showMemory &&
              prefs.refreshInterval == 2 && prefs.menuBarLayout == .auto &&
              prefs.menuBarEffect == .diffuse && close(prefs.panelTransparency, 0.71),
              "display preferences: reset updates every display value in memory")
        let reset = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
        check(reset.showNetwork && reset.showCPU && reset.showGPU && reset.showMemory &&
              reset.refreshInterval == 2 && reset.menuBarLayout == .auto &&
              reset.menuBarEffect == .diffuse && close(reset.panelTransparency, 0.71) &&
              defaults.string(forKey: "unrelatedPreference") == "keep",
              "display preferences: reset persists captured defaults and preserves unrelated preferences")
        check(service.registerCalls == loginCalls.0 && service.unregisterCalls == loginCalls.1 &&
              service.status == loginStatus,
              "display preferences: reset does not change login item")
        defaults.set("unrecognized-layout", forKey: Preferences.Keys.menuBarLayout)
        defaults.set("unrecognized-effect", forKey: Preferences.Keys.menuBarEffect)
        let unknown = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
        check(unknown.menuBarLayout == .auto && unknown.menuBarEffect == .diffuse,
              "display preferences: unknown enums fall back to current captured defaults")
        for legacyGlow in [false, true] {
            defaults.set(legacyGlow, forKey: Preferences.Keys.legacyMenuBarGlow)
            let legacy = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
            let expected: MenuBarEffect = legacyGlow ? .glow : .off
            check(legacy.menuBarEffect == expected &&
                  defaults.string(forKey: Preferences.Keys.menuBarEffect) == expected.rawValue &&
                  defaults.object(forKey: Preferences.Keys.legacyMenuBarGlow) == nil,
                  "display preferences: legacy glow \(legacyGlow) still migrates without adopting new default")
        }
        defaults.removePersistentDomain(forName: suiteName)
        check(defaults.persistentDomain(forName: suiteName)?.isEmpty != false,
              "display preferences: isolated suite is cleaned up")
    }

    static func login() {
        let service = SMAppService.mainApp
        let login = LaunchAtLogin.shared
        service.reset(.requiresApproval)
        check(login.set(false) == nil && service.unregisterCalls == 1 && service.status == .notRegistered,
              "login: requiresApproval is actually unregistered")
        service.reset(.enabled)
        check(login.set(false) == nil && service.unregisterCalls == 1 && !login.isEnabled,
              "login: enabled item remains removable")
        service.reset(.notRegistered)
        check(login.set(false) == nil && service.unregisterCalls == 0,
              "login: disabling unregistered item is idempotent")
        service.reset(.requiresApproval)
        service.failUnregister = true
        check(login.set(false) != nil && login.errorMessage != nil && service.status == .requiresApproval,
              "login: unregister failure is visible and does not claim registration removal")
        service.reset(.notRegistered)
        check(login.set(true) == nil && service.registerCalls == 1 && login.isEnabled,
              "login: enabling still registers the item")
    }

    static func hostReferences() {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        func refs() -> mach_port_urefs_t {
            var count: mach_port_urefs_t = 0
            precondition(mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &count) == KERN_SUCCESS)
            return count
        }
        let cpu = CPUMonitor()
        let memory = MemoryMonitor()
        let before = refs()
        for _ in 0..<1000 { cpu.sample(); memory.sample() }
        let after = refs()
        check(before == after, "host rights: 1000 CPU/memory sample pairs do not grow send references (\(before)→\(after))")
    }

    static func processCount() {
        ProcessFixture.enabled = true
        defer { ProcessFixture.enabled = false }
        ProcessFixture.count = 23
        ProcessFixture.fillCalls = 0
        check(ProcessMonitor.count() == 23 && ProcessFixture.fillCalls == 1,
              "process count: uses 23 filled records, not 28 estimated slots")
        ProcessFixture.count = 23
        ProcessFixture.growOnFill = true
        ProcessFixture.fillCalls = 0
        check(ProcessMonitor.count() == 33 && ProcessFixture.fillCalls == 2,
              "process count: retries table growth and uses final returned length")
        ProcessFixture.fail = true
        check(ProcessMonitor.count() == 0, "process count: failed read returns fallback")
        ProcessFixture.fail = false
    }

    static func starGlass() {
        let suite = "SysPulse.Regression.StarGlass.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        var snapshot = MetricsSnapshot()
        snapshot.cpuUsage = 0.35
        snapshot.gpuUsage = 42
        snapshot.memoryFraction = 0.61
        snapshot.downSpeed = 2_400_000
        snapshot.upSpeed = 320_000
        let previewDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/star-glass-preview", isDirectory: true)
        do { try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true) }
        catch { fatalError("Cannot create star glass preview directory: \(error)") }

        func bitmap(_ image: NSImage, background: NSColor = .clear) -> NSBitmapImageRep {
            let w = Int(image.size.width * 2), h = Int(image.size.height * 2)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: w * 4, bitsPerPixel: 32)!
            rep.bitmapData!.initialize(repeating: 0, count: w * h * 4)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
            background.setFill()
            let rect = NSRect(x: 0, y: 0, width: w, height: h)
            rect.fill(using: .copy)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        func raster(_ image: NSImage, background: NSColor = .clear) -> [UInt8] {
            let rep = bitmap(image, background: background)
            return Array(UnsafeBufferPointer(start: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh))
        }
        func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
            guard a.count == b.count else { return 255 }
            return zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        }
        func luminance(_ pixels: [UInt8], at offset: Int) -> Double {
            func linear(_ byte: UInt8) -> Double {
                let value = Double(byte) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(pixels[offset]) + 0.7152 * linear(pixels[offset + 1]) +
                0.0722 * linear(pixels[offset + 2])
        }
        func export(_ image: NSImage, name: String, background: NSColor) {
            guard let png = bitmap(image, background: background).representation(using: .png, properties: [:]) else {
                fatalError("Cannot encode star glass preview \(name)")
            }
            do { try png.write(to: previewDirectory.appendingPathComponent(name + ".png")) }
            catch { fatalError("Cannot write star glass preview \(name): \(error)") }
        }
        func exportAnimation(name: String, background: NSColor, render: (Double) -> NSImage) {
            let url = previewDirectory.appendingPathComponent(name + ".gif")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 120, nil) else {
                fatalError("Cannot create drifting star preview \(name)")
            }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let properties = [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: 0.1, kCGImagePropertyGIFUnclampedDelayTime: 0.1]] as CFDictionary
            for frame in 0..<120 {
                guard let cgImage = bitmap(render(Double(frame) / 10), background: background).cgImage else {
                    fatalError("Cannot rasterize drifting star preview \(name), frame \(frame)")
                }
                CGImageDestinationAddImage(destination, cgImage, properties)
            }
            guard CGImageDestinationFinalize(destination) else { fatalError("Cannot finish drifting star preview \(name)") }
        }
        let times: [Double?] = [0, 0.1, 1, 5, 18, 100, -18, Double.greatestFiniteMagnitude,
                                nil, .nan, .infinity, -.infinity]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let dark = name == .darkAqua
            let appearance = NSAppearance(named: name)!
            let backdrop = NSColor(calibratedWhite: dark ? 0.12 : 0.93, alpha: 1)
            for density in [MenuBarDensity.full, .compact, .minimal] {
                func image(_ elapsed: Double?, includesBackground: Bool = true,
                           effect: MenuBarEffect = .iridescent) -> NSImage {
                    MenuBarImage.render(snapshot: snapshot, preferences: preferences,
                                        appearance: appearance, density: density, effect: effect,
                                        effectElapsed: elapsed, includesBackground: includesBackground)!
                }
                let foreground = image(0, includesBackground: false)
                let glyphs = raster(foreground)
                let label = "\(name.rawValue)/\(density)"
                let width = Int(foreground.size.width * 2), height = Int(foreground.size.height * 2)
                let pixelCount = width * height
                let occupiedGlyphs = stride(from: 0, to: glyphs.count, by: 4).filter { glyphs[$0 + 3] > 0 }
                let coreGlyphs = occupiedGlyphs.filter { glyphs[$0 + 3] >= 200 }
                check(occupiedGlyphs.count > 20 && occupiedGlyphs.count < pixelCount / 2 && coreGlyphs.count > 20,
                      "star glass \(label): adaptive foreground retains solid readable strokes and transparent blank space")
                check(times.allSatisfy { raster(image($0, includesBackground: false)) == glyphs },
                      "star glass \(label): foreground pixels stay identical for all finite, absent and nonfinite times")
                let textOnBackdrop = raster(foreground, background: backdrop)
                let emptyOnBackdrop = raster(NSImage(size: foreground.size), background: backdrop)
                let plainContrast = coreGlyphs.reduce(0.0) { sum, offset in
                    let a = luminance(textOnBackdrop, at: offset), b = luminance(emptyOnBackdrop, at: offset)
                    return sum + (max(a, b) + 0.05) / (min(a, b) + 0.05)
                } / Double(coreGlyphs.count)
                check(plainContrast >= 4.5,
                      "star glass \(label): adaptive foreground retains matching-backdrop core-stroke contrast")
                guard let glass = MenuBarImage.background(size: foreground.size, appearance: appearance,
                    effect: .iridescent, elapsed: 0, foreground: foreground),
                      let liquid = MenuBarImage.background(size: foreground.size, appearance: appearance,
                    effect: .iridescent, elapsed: 0, foreground: foreground, includesStars: false),
                      let pureWater = MenuBarImage.background(size: foreground.size, appearance: appearance,
                    effect: .iridescent, elapsed: 0, foreground: foreground, includesStars: false, includesSilks: false)
                else { fatalError("star glass \(label): background unavailable") }
                // Keep silk in the particle baseline so long strands never count as stars.
                let glassPixels = raster(glass), liquidPixels = raster(liquid), waterPixels = raster(pureWater)
                let occupied = stride(from: 0, to: glassPixels.count, by: 4).filter { glassPixels[$0 + 3] > 0 }
                let corners = [0, width - 1, (height - 1) * width, height * width - 1]
                check(glass.size == foreground.size && occupied.count > pixelCount / 2 &&
                      occupied.filter { glassPixels[$0 + 3] < 250 }.count > occupied.count * 9 / 10 &&
                      corners.allSatisfy { glassPixels[$0 * 4 + 3] == 0 },
                      "star glass \(label): liquid fills a translucent capsule with clear rounded corners")
                var colorful = 0, warmLiquid = 0
                var lows = [Double](repeating: 1, count: 3), highs = [Double](repeating: 0, count: 3)
                for offset in stride(from: 0, to: waterPixels.count, by: 4) where waterPixels[offset + 3] > 30 {
                    let alpha = Double(waterPixels[offset + 3])
                    let channels = (0..<3).map { Double(waterPixels[offset + $0]) / alpha }
                    let spread = channels.max()! - channels.min()!
                    if spread > 0.10 { colorful += 1 }
                    if spread > 0.10 && channels[0] > channels[2] + 0.03 { warmLiquid += 1 }
                    for channel in 0..<3 {
                        lows[channel] = min(lows[channel], channels[channel])
                        highs[channel] = max(highs[channel], channels[channel])
                    }
                }
                check(colorful > occupied.count / 4 && warmLiquid == 0 &&
                      zip(lows, highs).contains { $1 - $0 > 0.04 },
                      "star glass \(label): liquid retains a clean cool-water color and depth without a warm wash")
                // Inspect actual unmasked output: text legitimately cuts strands into short pieces.
                let unmaskedWater = raster(MenuBarImage.background(size: foreground.size, appearance: appearance,
                    effect: .iridescent, elapsed: 0, includesStars: false, includesSilks: false)!)
                let unmaskedSilks = raster(MenuBarImage.background(size: foreground.size, appearance: appearance,
                    effect: .iridescent, elapsed: 0, includesStars: false)!)
                var silkPixels = Set<Int>(), goldSilk = 0, coloredSilk = 0
                for pixel in 0..<pixelCount {
                    let offset = pixel * 4
                    let change = (0..<4).map { abs(Int(unmaskedSilks[offset + $0]) - Int(unmaskedWater[offset + $0])) }.max()!
                    if change > 3 { silkPixels.insert(pixel) }
                    let baseAlpha = Double(unmaskedWater[offset + 3]) / 255
                    let alpha = (Double(unmaskedSilks[offset + 3]) / 255 - baseAlpha) / max(0.001, 1 - baseAlpha)
                    if alpha > 0.04 {
                        let tint = (0..<3).map { channel in
                            (Double(unmaskedSilks[offset + channel]) / 255 -
                             Double(unmaskedWater[offset + channel]) / 255 * (1 - alpha)) / alpha
                        }
                        if tint[0] > 0.80 && tint[1] > 0.60 && tint[2] < 0.70 { goldSilk += 1 }
                        if tint[2] > tint[0] + 0.15 ||
                           (tint[0] > tint[1] + 0.15 && tint[2] > tint[1] + 0.10) { coloredSilk += 1 }
                    }
                }
                var silkUnseen = silkPixels, strandBounds: [(Int, Int)] = []
                while let first = silkUnseen.first {
                    silkUnseen.remove(first)
                    var queue = [first], index = 0
                    while index < queue.count {
                        let pixel = queue[index], x = pixel % width, y = pixel / width
                        index += 1
                        for dy in -1...1 {
                            for dx in -1...1 where dx != 0 || dy != 0 {
                                let nx = x + dx, ny = y + dy
                                if nx >= 0 && nx < width && ny >= 0 && ny < height {
                                    let neighbor = ny * width + nx
                                    if silkUnseen.remove(neighbor) != nil { queue.append(neighbor) }
                                }
                            }
                        }
                    }
                    let xs = queue.map { $0 % width }, ys = queue.map { $0 / width }
                    strandBounds.append((xs.max()! - xs.min()! + 1, ys.max()! - ys.min()! + 1))
                }
                let elongatedBounds = strandBounds.filter { $0.0 >= width / 12 && $0.0 >= $0.1 * 4 }
                // Neighboring colors can meet after relocation; connected-region count is not strand count.
                let elongatedSpan = elongatedBounds.reduce(0) { $0 + $1.0 }
                print("SILK PIXELS \(label): changed=\(silkPixels.count), gold=\(goldSilk), colored=\(coloredSilk), elongated=\(elongatedBounds.count), span=\(elongatedSpan), bounds=\(strandBounds)")
                check(silkPixels.count > 20 && elongatedSpan >= width / 2 && goldSilk > 2 && coloredSilk > 2,
                      "star glass \(label): silk-only output adds actual slender gold and colored strands to pure water")
                let waterAlpha = stride(from: 3, to: waterPixels.count, by: 4).map { Int(waterPixels[$0]) }
                check(waterPixels == unmaskedWater && waterAlpha.max()! <= (dark ? 57 : 46),
                      "star glass \(label): isolated water keeps its low opacity and is not cut by the decoration mask")
                for stars in [false, true] {
                    for silks in [false, true] {
                        let selected = MenuBarImage.background(size: foreground.size, appearance: appearance,
                            effect: .iridescent, elapsed: 0, foreground: foreground,
                            includesStars: stars, includesSilks: silks)!
                        let direct = NSImage(size: foreground.size, flipped: false) { _ in
                            MenuBarImage.drawEffect(size: foreground.size, appearance: appearance,
                                effect: .iridescent, elapsed: 0, foreground: foreground,
                                includesStars: stars, includesSilks: silks)
                            return true
                        }
                        check(raster(selected) == raster(direct),
                              "star glass \(label): independent stars=\(stars) silks=\(silks) switches match direct drawing")
                    }
                }
                let composite = image(0)
                let manual = NSImage(size: foreground.size, flipped: false) { _ in
                    let rect = NSRect(origin: .zero, size: foreground.size)
                    glass.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                    foreground.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                    return true
                }
                check(composite.size == foreground.size && maxDifference(raster(composite), raster(manual)) <= 3,
                      "star glass \(label): default rendering matches masked stars followed by stable foreground")
                let composed = raster(composite, background: backdrop), surface = raster(glass, background: backdrop)
                let contrast = coreGlyphs.reduce(0.0) { sum, offset in
                    let a = luminance(composed, at: offset), b = luminance(surface, at: offset)
                    return sum + (max(a, b) + 0.05) / (min(a, b) + 0.05)
                } / Double(coreGlyphs.count)
                print("STAR GLASS CONTRAST \(label): mean=\(contrast)")
                check(contrast >= 3, "star glass \(label): foreground remains readable over liquid and stars")
                check(times.allSatisfy { elapsed in
                    let background = MenuBarImage.background(size: foreground.size, appearance: appearance,
                        effect: .iridescent, elapsed: elapsed, foreground: foreground, includesStars: false)!
                    return raster(background) == liquidPixels
                }, "star glass \(label): silk-only water retains exact color and transparency at every time without flashes or moving strands")
                check(times.allSatisfy { elapsed in
                    let background = MenuBarImage.background(size: foreground.size, appearance: appearance,
                        effect: .iridescent, elapsed: elapsed, foreground: foreground,
                        includesStars: false, includesSilks: false)!
                    return raster(background) == waterPixels
                }, "star glass \(label): pure water remains exactly time-invariant independently of both decorations")
                let invalidTimes: [Double?] = [nil, .nan, .infinity, -.infinity]
                check(invalidTimes.allSatisfy { elapsed in
                    let background = MenuBarImage.background(size: foreground.size, appearance: appearance,
                        effect: .iridescent, elapsed: elapsed, foreground: foreground)!
                    return raster(image(elapsed)) == raster(composite) && raster(background) == glassPixels
                }, "star glass \(label): absent and nonfinite particle times normalize to the valid time-zero rendering")
                let driftTimes = [5.0, 10.0, 17.0]
                check(driftTimes.allSatisfy { elapsed in
                    let pixels = raster(MenuBarImage.background(size: foreground.size, appearance: appearance,
                        effect: .iridescent, elapsed: elapsed, foreground: foreground)!)
                    let changed = (0..<pixelCount).filter { pixel in
                        (0..<3).contains { abs(Int(pixels[pixel * 4 + $0]) - Int(glassPixels[pixel * 4 + $0])) > 5 }
                    }.count
                    return image(elapsed).size == composite.size && changed > 10
                }, "star glass \(label): fine stars change actual rendered positions over seconds while geometry stays fixed")
                var independentBackgrounds: [[UInt8]] = []
                for effect in [MenuBarEffect.glow, .diffuse] {
                    let first = MenuBarImage.background(size: foreground.size, appearance: appearance,
                        effect: effect, elapsed: 0, foreground: foreground)!
                    let later = MenuBarImage.background(size: foreground.size, appearance: appearance,
                        effect: effect, elapsed: 5, foreground: foreground)!
                    let firstPixels = raster(first), laterPixels = raster(later)
                    independentBackgrounds.append(firstPixels)
                    let changed = (0..<pixelCount).filter { pixel in
                        (0..<3).contains { abs(Int(firstPixels[pixel * 4 + $0]) - Int(laterPixels[pixel * 4 + $0])) > 5 }
                    }.count
                    check(first.size == foreground.size && later.size == foreground.size && changed > pixelCount / 100,
                          "background \(label)/\(effect.rawValue): its own animation changes a meaningful area without changing geometry")
                    check(maxDifference(firstPixels, glassPixels) > 10,
                          "background \(label)/\(effect.rawValue): restored mode has distinct pixels from liquid star glass")
                    check(raster(image(0, includesBackground: false, effect: effect)) == glyphs &&
                          raster(image(5, includesBackground: false, effect: effect)) == glyphs,
                          "background \(label)/\(effect.rawValue): foreground keeps the same cacheable pixels across mode and time")
                    let direct = NSImage(size: foreground.size, flipped: false) { _ in
                        MenuBarImage.drawEffect(size: foreground.size, appearance: appearance,
                            effect: effect, elapsed: 0, foreground: foreground)
                        return true
                    }
                    check(raster(direct) == firstPixels,
                          "background \(label)/\(effect.rawValue): direct drawing and background API produce the same geometry and pixels")
                    let composedMode = NSImage(size: foreground.size, flipped: false) { _ in
                        let rect = NSRect(origin: .zero, size: foreground.size)
                        first.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                        foreground.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                        return true
                    }
                    check(maxDifference(raster(image(0, effect: effect)), raster(composedMode)) <= 3,
                          "background \(label)/\(effect.rawValue): default rendering composes its independent background below ordinary text")
                }
                check(maxDifference(independentBackgrounds[0], independentBackgrounds[1]) > 10,
                      "background \(label): glow and diffuse remain visually distinct from one another")
                check(MenuBarImage.background(size: foreground.size, appearance: appearance,
                                             effect: .off, elapsed: 0, foreground: foreground) == nil &&
                      raster(image(0, effect: .off)) == glyphs,
                      "star glass \(label): off preserves foreground and removes the glass background")

                // Independently dilate the actual 2x glyph coverage by a one-point round guard.
                // The comparison isolates stars; no production mask or star geometry is reused.
                var protectedPixels = Set<Int>()
                for offset in occupiedGlyphs where glyphs[offset + 3] > 12 {
                    let pixel = offset / 4, x = pixel % width, y = pixel / width
                    for dy in -2...2 {
                        for dx in -2...2 where dx * dx + dy * dy <= 4 {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0 && nx < width && ny >= 0 && ny < height { protectedPixels.insert(ny * width + nx) }
                        }
                    }
                }
                func delta(_ a: [UInt8], _ b: [UInt8], _ pixel: Int) -> Int {
                    (0..<4).map { abs(Int(a[pixel * 4 + $0]) - Int(b[pixel * 4 + $0])) }.max()!
                }
                let silkLeakage = protectedPixels.map { delta(liquidPixels, waterPixels, $0) }.max() ?? 0
                let removedSilks = protectedPixels.filter { delta(unmaskedSilks, unmaskedWater, $0) > 3 }.count
                let visibleSilks = (0..<pixelCount).filter { delta(liquidPixels, waterPixels, $0) > 3 }.count
                print("SILK MASK \(label): leakage=\(silkLeakage), removed=\(removedSilks), visible=\(visibleSilks)")
                check(silkLeakage == 0 && visibleSilks > 20,
                      "star glass \(label): actual visible silk leaves the independent one-point glyph guard unchanged")
                for elapsed in [0.0, 5.0, 10.0, 17.0] {
                    let current = MenuBarImage.background(size: foreground.size, appearance: appearance,
                        effect: .iridescent, elapsed: elapsed, foreground: foreground)!
                    let currentPixels = raster(current)
                    let unguarded = raster(MenuBarImage.background(size: foreground.size, appearance: appearance,
                        effect: .iridescent, elapsed: elapsed)!)
                    let leakage = protectedPixels.map { delta(currentPixels, liquidPixels, $0) }.max() ?? 0
                    let removedCandidates = protectedPixels.filter { delta(unguarded, unmaskedSilks, $0) > 3 }.count
                    let combinedLeakage = protectedPixels.map { delta(currentPixels, waterPixels, $0) }.max() ?? 0
                    print("STAR MASK \(label) time \(elapsed): guarded=\(protectedPixels.count), leakage=\(leakage), combinedLeakage=\(combinedLeakage), removed=\(removedCandidates)")
                    check(combinedLeakage == 0,
                          "star glass \(label) time \(elapsed): combined silk and stars leave pure-water RGBA exactly unchanged under the glyph guard")
                    check(leakage <= 3,
                          "star glass \(label) time \(elapsed): drifting stars leave one-point padded glyph coverage unchanged")
                    check(removedCandidates > 5 && maxDifference(currentPixels, unguarded) > 3,
                          "star glass \(label) time \(elapsed): glyph guard removes actual overlapping particle candidates")
                    let composed = raster(image(elapsed), background: backdrop)
                    let surface = raster(current, background: backdrop)
                    let mean = coreGlyphs.reduce(0.0) { sum, offset in
                        let a = luminance(composed, at: offset), b = luminance(surface, at: offset)
                        return sum + (max(a, b) + 0.05) / (min(a, b) + 0.05)
                    } / Double(coreGlyphs.count)
                    check(mean >= 3,
                          "star glass \(label) time \(elapsed): drifting star positions preserve foreground contrast")
                    let manualPhase = NSImage(size: foreground.size, flipped: false) { _ in
                        let rect = NSRect(origin: .zero, size: foreground.size)
                        current.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                        foreground.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                        return true
                    }
                    check(maxDifference(raster(image(elapsed)), raster(manualPhase)) <= 3,
                          "star glass \(label) time \(elapsed): default composition uses the same moving guarded stars")
                }
                let liquidOnBackdrop = raster(liquid, background: backdrop)
                var starPixels = Set<Int>(), golden = 0, silver = 0
                for pixel in 0..<pixelCount {
                    let offset = pixel * 4
                    let gains = (0..<3).map { Int(surface[offset + $0]) - Int(liquidOnBackdrop[offset + $0]) }
                    if gains.max()! > 3 && luminance(surface, at: offset) > luminance(liquidOnBackdrop, at: offset) + 0.001 {
                        starPixels.insert(pixel)
                        let baseAlpha = Double(liquidPixels[offset + 3]) / 255
                        let combinedAlpha = Double(glassPixels[offset + 3]) / 255
                        let particleAlpha = (combinedAlpha - baseAlpha) / max(0.001, 1 - baseAlpha)
                        if particleAlpha > 0.04 {
                            let tint = (0..<3).map { channel in
                                (Double(glassPixels[offset + channel]) / 255 -
                                 Double(liquidPixels[offset + channel]) / 255 * (1 - particleAlpha)) / particleAlpha
                            }
                            if tint[0] > 0.80 && tint[1] > 0.60 && tint[2] < 0.70 { golden += 1 }
                            if tint.min()! > 0.80 && tint.max()! - tint.min()! < 0.18 { silver += 1 }
                        }
                    }
                }
                var unseen = starPixels, sizes: [Int] = []
                while let first = unseen.first {
                    unseen.remove(first)
                    var queue = [first], index = 0
                    while index < queue.count {
                        let pixel = queue[index], x = pixel % width, y = pixel / width
                        index += 1
                        for dy in -1...1 {
                            for dx in -1...1 where dx != 0 || dy != 0 {
                                let nx = x + dx, ny = y + dy
                                if nx >= 0 && nx < width && ny >= 0 && ny < height {
                                    let neighbor = ny * width + nx
                                    if unseen.remove(neighbor) != nil { queue.append(neighbor) }
                                }
                            }
                        }
                    }
                    sizes.append(queue.count)
                }
                let fine = sizes.filter { $0 <= 16 }.count
                print("STAR SPECKS \(label): components=\(sizes.count), fine=\(fine), largest=\(sizes.max() ?? 0), pixels=\(starPixels.count), golden=\(golden), silver=\(silver)")
                fflush(stdout)
                check(sizes.count >= max(20, pixelCount / 600) && fine * 10 >= sizes.count * 9 &&
                      starPixels.count < pixelCount / 8,
                      "star glass \(label): many distinct fine star specks occupy a small fraction of the glass")
                check(golden > 2 && silver > 2,
                      "star glass \(label): specks include both soft gold and silver-white reflections")
                export(composite, name: "\(dark ? "dark" : "light")-\(density)", background: backdrop)
                if density != .minimal {
                    exportAnimation(name: "\(dark ? "dark" : "light")-\(density)-drifting", background: backdrop) { image($0) }
                }
            }
        }
        print("Liquid star glass production previews: \(previewDirectory.path)")
    }

    static func starBitmapFrames() {
        let size = NSSize(width: 107, height: 18.5)
        func foreground() -> NSImage {
            NSImage(size: size, flipped: false) { _ in
                NSAttributedString(string: "CPU 42", attributes: [.font: NSFont.systemFont(ofSize: 11)])
                    .draw(at: NSPoint(x: 3, y: 2))
                return true
            }
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            for scale in [CGFloat(1), 2, 3] {
                let glyph = foreground()
                let context = NSGraphicsContext.current
                func frame(_ time: Double?, foreground: NSImage? = nil,
                           stars: Bool = true, silks: Bool = true) -> NSImage {
                    MenuBarImage.background(size: size, appearance: appearance, effect: .iridescent,
                        elapsed: time, foreground: foreground ?? glyph, includesStars: stars,
                        includesSilks: silks, backingScale: scale)!
                }
                let frozen = frame(0)
                let bitmap = frozen.representations.first as? NSBitmapImageRep
                let label = "star bitmap \(name.rawValue)/\(scale)x"
                check(bitmap != nil && frozen.representations.count == 1 && !frozen.isTemplate,
                      "\(label): eagerly owns one non-template bitmap")
                check(bitmap?.pixelsWide == Int(ceil(size.width * scale)) &&
                      bitmap?.pixelsHigh == Int(ceil(size.height * scale)) && frozen.size == size,
                      "\(label): native pixels follow backing scale and preserve logical size")
                check(frame(0) === frozen, "\(label): stationary frames reuse the same image")
                check([nil, Double.nan, Double.infinity, -Double.infinity].allSatisfy { frame($0) === frozen },
                      "\(label): absent and invalid times reuse valid time-zero pixels")
                let moving = frame(1.2)
                let later = frame(8.7)
                check(moving !== frozen && later !== moving && moving.tiffRepresentation != later.tiffRepresentation,
                      "\(label): animated frames continue moving independently of frozen cache")
                check(frame(0) === frozen, "\(label): animation does not corrupt the stationary frame")
                let otherGlyph = foreground()
                check(frame(0, foreground: otherGlyph) !== frozen,
                      "\(label): a new foreground invalidates the protected stationary background")
                let withoutStars = frame(0, stars: false)
                check(frame(0, stars: false) === withoutStars && frame(0) !== withoutStars,
                      "\(label): particle switches invalidate and then reuse the correct frame")
                let withoutSilks = frame(0, silks: false)
                check(frame(0, silks: false) === withoutSilks && frame(0) !== withoutSilks,
                      "\(label): silk switches invalidate and then reuse the correct frame")
                let otherAppearance = NSAppearance(named: name == .aqua ? .darkAqua : .aqua)!
                let restored = frame(0)
                let recolored = MenuBarImage.background(size: size, appearance: otherAppearance,
                    effect: .iridescent, elapsed: 0, foreground: glyph, backingScale: scale)!
                check(recolored !== restored && recolored.tiffRepresentation != restored.tiffRepresentation,
                      "\(label): changing appearance invalidates the frozen colors")
                let rescaled = MenuBarImage.background(size: size, appearance: otherAppearance,
                    effect: .iridescent, elapsed: 0, foreground: glyph, backingScale: scale + 1)!
                check(rescaled !== recolored &&
                      (rescaled.representations.first as? NSBitmapImageRep)?.pixelsWide == Int(ceil(size.width * (scale + 1))),
                      "\(label): changing backing scale invalidates native pixel dimensions")
                check(NSGraphicsContext.current === context,
                      "\(label): eager rendering restores the caller graphics context")
            }
        }
    }

    static func installationIdentity() {
        func canonical(_ path: String) -> Bool {
            SingleInstance.isCanonicalInstallation(URL(fileURLWithPath: path))
        }
        check(canonical("/Applications/SysPulse.app"), "installation: canonical bundle is the formal app")
        check(canonical("/Applications/../Applications/SysPulse.app"), "installation: equivalent canonical path is accepted")
        check(!canonical("/Applications/SysPulse copy.app"), "installation: renamed copy is not the formal app")
        check(!canonical("/Applications/Utilities/SysPulse.app"), "installation: nested Applications copy is not formal")
        check(!canonical("/Volumes/SysPulse 1.0.2/SysPulse.app"), "installation: mounted download is not formal")
        check(!canonical("/Applications-other/SysPulse.app"), "installation: path prefix does not grant formal identity")
    }

    static func main() {
        precondition(Bundle.main.bundleIdentifier != "com.local.syspulse",
                     "Regression tests must run as a raw isolated executable, never the installed app.")
        if CommandLine.arguments.contains("--menu-effects-only") {
            displayPreferences()
            starGlass()
            starBitmapFrames()
            print("\n\(passed) focused menu effect assertions passed.")
            return
        }
        if CommandLine.arguments.contains("--metric-colors-only") {
            metricColors()
            print("\n\(passed) focused metric color assertions passed.")
            return
        }
        memoryPressure()
        metricColors()
        network()
        networkParser()
        gpu()
        displayPreferences()
        login()
        hostReferences()
        processCount()
        starGlass()
        starBitmapFrames()
        installationIdentity()
        panelContentSizing()
        print("\n\(passed) regression assertions passed. No GUI app installation or real login-item changes.")
    }
}
