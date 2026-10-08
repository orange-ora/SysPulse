import AppKit
import Darwin
import Foundation
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
        check(palette.memoryColor(.normal) == palette.primary && palette.memoryColor(.unknown) == palette.primary,
              "memory pressure: panel uses neutral text for normal/unknown")
        check(palette.memoryColor(.warning) == palette.warning && palette.memoryColor(.critical) == palette.critical,
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
                check(bytes(rainbowNormal) == bytes(rainbowCritical),
                      "memory rendering \(name.rawValue)/\(density): iridescent retains its chosen cold colors")
            }
        }
        snapshot.memoryPressure = .critical
        check(MenuBarImage.tooltip(snapshot: snapshot).contains("压力：严重"), "memory pressure: tooltip communicates critical state")
        snapshot.memoryPressure = .unknown
        check(MenuBarImage.tooltip(snapshot: snapshot).contains("压力：未知"), "memory pressure: tooltip communicates unknown state")
    }

    static func metricColors() {
        let palette = PanelPalette(transparency: 0.71)
        for fraction in [0.79, 0.80, 0.92, 1.0] {
            check(palette.readingColor(.gpu, fraction: fraction, memoryPressure: .critical) == palette.primary,
                  "GPU panel: \(fraction * 100)% stays neutral independently of memory pressure")
        }
        check(palette.readingColor(.gpu, fraction: nil, memoryPressure: .normal) == palette.secondary,
              "GPU panel: missing data retains its secondary text color")
        check(palette.readingColor(.cpu, fraction: 0.80, memoryPressure: .normal) == palette.warning &&
              palette.readingColor(.cpu, fraction: 0.92, memoryPressure: .normal) == palette.critical,
              "CPU panel: warning thresholds remain independent of GPU changes")
        check(palette.readingColor(.memory, fraction: 0.99, memoryPressure: .normal) == palette.primary &&
              palette.readingColor(.memory, fraction: 0.99, memoryPressure: .unknown) == palette.primary,
              "memory panel: 99% usage with normal or unknown pressure stays neutral")
        check(palette.readingColor(.memory, fraction: 0.40, memoryPressure: .warning) == palette.warning &&
              palette.readingColor(.memory, fraction: 0.40, memoryPressure: .critical) == palette.critical,
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
        // Plain text is achromatic; orange/red glyph pixels verify actual renderer output.
        func coloredPixels(_ image: NSImage) -> Int {
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.1 else { continue }
                    let maximum = max(max(color.redComponent, color.greenComponent), color.blueComponent)
                    let minimum = min(min(color.redComponent, color.greenComponent), color.blueComponent)
                    if maximum - minimum > 0.12 { count += 1 }
                }
            }
            return count
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            for density in [MenuBarDensity.full, .compact, .minimal] {
                let gpu80 = render(gpu: true, usage: 0.80, density: density, appearance: appearance)
                let gpu100 = render(gpu: true, usage: 1.0, density: density, appearance: appearance)
                check(coloredPixels(gpu80) == 0, "GPU rendering \(name.rawValue)/\(density): 80% has no warning color")
                check(coloredPixels(gpu100) == 0, "GPU rendering \(name.rawValue)/\(density): 100% has no warning color")
                check(gpu80.size == gpu100.size, "GPU rendering \(name.rawValue)/\(density): full utilization preserves width")
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
              "display preferences: existing valid custom display settings remain unchanged")
        // 原有范围内的存值与新增高通透值都应原样持久化、重载。
        for value in [0.30, 0.52, 0.70, 0.95, 1.0] {
            prefs.panelTransparency = value
            let reloaded = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
            check(close(defaults.double(forKey: Preferences.Keys.panelTransparency), value) &&
                  close(reloaded.panelTransparency, value),
                  "display preferences: transparency \(value) persists and reloads")
        }
        check(MenuBarEffect.allCases.map { $0.rawValue } == ["off", "glow", "diffuse", "iridescent"],
              "display preferences: effect raw values retain stored compatibility")
        check(MenuBarEffect.allCases.map { $0.title } == ["无光效", "流光", "光晕", "炫彩"],
              "display preferences: effect titles match current UI labels")
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

    static func pixels(_ elapsed: Double, effect: MenuBarEffect = .glow) -> [UInt8] {
        let w = 215, h = 19
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: w * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        MenuBarImage.drawEffect(size: NSSize(width: w, height: h), effect: effect, elapsed: elapsed)
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: rep.bitmapData!, count: w * h * 4))
    }
    static func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0.0
        for i in a.indices where i % 4 != 3 { sum += abs(Double(a[i]) - Double(b[i])) }
        return sum / Double(a.count / 4 * 3) / 255
    }
    static func glow() {
        let seam = distance(pixels(11.999999), pixels(12))
        check(seam < 0.001, "glow: infinitesimal 12s boundary color change is continuous (\(seam))")
        let normal = distance(pixels(11.8), pixels(11.9))
        let boundary = distance(pixels(11.9), pixels(12))
        check(boundary < 0.03 && boundary < max(normal * 3, 0.01),
              "glow: regular frame across boundary has no large color jump")
        let later = distance(pixels(23.999999), pixels(24))
        check(later < 0.001, "glow: subsequent cycle boundary is also continuous")
    }

    static func iridescent() {
        let suite = "SysPulse.Regression.Iridescent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        var snapshot = MetricsSnapshot()
        snapshot.cpuUsage = 0.35
        snapshot.gpuUsage = 42
        snapshot.memoryFraction = 0.61
        snapshot.downSpeed = 2_400_000
        snapshot.upSpeed = 320_000
        func raster(_ image: NSImage, background: NSColor = .clear) -> [UInt8] {
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
            return Array(UnsafeBufferPointer(start: rep.bitmapData!, count: w * h * 4))
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for density in [MenuBarDensity.full, .compact, .minimal] {
                func image(_ elapsed: Double?) -> NSImage {
                    MenuBarImage.render(snapshot: snapshot, preferences: preferences,
                        appearance: NSAppearance(named: name), density: density,
                        effect: .iridescent, effectElapsed: elapsed)!
                }
                let firstImage = image(0), movingImage = image(3), nextImage = image(5)
                let first = raster(firstImage), moving = raster(movingImage), next = raster(nextImage)
                let label = "\(name.rawValue)/\(density)"
                let width = Int(firstImage.size.width * 2), height = Int(firstImage.size.height * 2)
                var occupied = 0, colorful = 0, warm = 0, animated = 0
                var stableAlpha = true, transparentEdges = true
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = (y * width + x) * 4
                        let alpha = first[offset + 3]
                        if alpha > 0 { occupied += 1 }
                        stableAlpha = stableAlpha && alpha == moving[offset + 3]
                        if x < 2 || x >= width - 2 {
                            transparentEdges = transparentEdges && alpha == 0 && moving[offset + 3] == 0
                        }
                        if alpha > 160 {
                            let red = Int(first[offset]), green = Int(first[offset + 1]), blue = Int(first[offset + 2])
                            if max(red, green, blue) - min(red, green, blue) > 15 { colorful += 1 }
                            if red > green + 2 && red > blue + 2 { warm += 1 }
                            let change = (0..<3).reduce(0) { $0 + abs(Int(first[offset + $1]) - Int(moving[offset + $1])) }
                            if change > 15 { animated += 1 }
                        }
                    }
                }
                check(occupied > 0 && occupied < width * height / 2 && transparentEdges,
                      "iridescent \(label): only glyphs have alpha, surrounding blank space stays transparent")
                check(colorful > 20 && warm == 0,
                      "iridescent \(label): glyph colors remain blue/cyan/violet with no warm red or orange dominance")
                check(animated > 5 && stableAlpha,
                      "iridescent \(label): local pearl shine moves while the glyph alpha mask remains unchanged")
                check(firstImage.size == movingImage.size && firstImage.size == nextImage.size &&
                      distance(first, next) < 0.001 && distance(raster(image(4.999999)), next) < 0.001,
                      "iridescent \(label): image size and five-second boundary remain stable")
                check(distance(first, raster(image(nil))) < 0.001 && distance(first, raster(image(.infinity))) < 0.001,
                      "iridescent \(label): absent or nonfinite phase draws a valid static glyph effect")
                let background = NSColor(calibratedRed: 0.2, green: 0.1, blue: 0.3, alpha: 1)
                let composited = raster(movingImage, background: background)
                let reference = raster(NSImage(size: firstImage.size), background: background)
                let untouched = stride(from: 0, to: first.count, by: 4).allSatisfy { offset in
                    guard first[offset + 3] == 0 else { return true }
                    return Array(composited[offset..<(offset + 4)]) == Array(reference[offset..<(offset + 4)])
                }
                check(untouched, "iridescent \(label): isolated sourceIn leaves the existing destination unchanged outside glyphs")
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
        memoryPressure()
        metricColors()
        network()
        networkParser()
        gpu()
        displayPreferences()
        login()
        hostReferences()
        processCount()
        glow()
        iridescent()
        installationIdentity()
        panelContentSizing()
        print("\n\(passed) regression assertions passed. No GUI app installation or real login-item changes.")
    }
}
