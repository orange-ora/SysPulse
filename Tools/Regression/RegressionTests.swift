import AppKit
import Darwin
import Foundation
import ServiceManagement

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

    static func pixels(_ elapsed: Double) -> [UInt8] {
        let w = 215, h = 19
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: w * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        MenuBarImage.drawEffect(size: NSSize(width: w, height: h), effect: .glow, elapsed: elapsed)
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

    static func main() {
        precondition(Bundle.main.bundleIdentifier != "com.local.syspulse",
                     "Regression tests must run as a raw isolated executable, never the installed app.")
        network()
        networkParser()
        gpu()
        login()
        hostReferences()
        processCount()
        glow()
        print("\n\(passed) regression assertions passed. No GUI app installation or real login-item changes.")
    }
}
