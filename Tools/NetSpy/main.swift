import Darwin
import Foundation

// 打印每块网卡的收发计数与速率，用于核对统计口径
struct Iface { let name: String; let rx: UInt64; let tx: UInt64 }

func snapshot() -> [Iface] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var length: size_t = 0
    guard sysctl(&mib, 6, nil, &length, nil, 0) >= 0, length > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: length)
    guard sysctl(&mib, 6, &buffer, &length, nil, 0) >= 0 else { return [] }

    var result: [Iface] = []
    buffer.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= Int(length) {
            let header = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self).pointee
            let messageLength = Int(header.ifm_msglen)
            guard messageLength > 0 else { break }
            if Int32(header.ifm_type) == RTM_IFINFO2 {
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                let index = header.ifm_index
                let message = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self).pointee
                if if_indextoname(UInt32(index), &name) != nil {
                    result.append(Iface(
                        name: String(cString: name),
                        rx: UInt64(message.ifm_data.ifi_ibytes),
                        tx: UInt64(message.ifm_data.ifi_obytes)
                    ))
                }
            }
            offset += messageLength
        }
    }
    return result
}

func bytes(_ v: Double) -> String {
    let units = ["B", "K", "M", "G", "T"]
    var value = max(v, 0); var i = 0
    while value >= 1000, i < units.count - 1 { value /= 1000; i += 1 }
    return String(format: value < 10 ? "%.2f%@" : "%.0f%@", value, units[i])
}

let first = snapshot()
Thread.sleep(forTimeInterval: Double(CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 3) : 3))
let second = snapshot()

var totals: [String: (UInt64, UInt64)] = [:]
for iface in first { totals[iface.name] = (iface.rx, iface.tx) }

print(String(format: "%-10@ %14@ %14@ %14@ %14@", "接口" as NSString, "收(累计)" as NSString, "发(累计)" as NSString, "下行" as NSString, "上行" as NSString))
var sumDown = 0.0, sumUp = 0.0, sumRx = 0.0, sumTx = 0.0
for iface in second {
    let old = totals[iface.name] ?? (0, 0)
    let down = iface.rx >= old.0 ? Double(iface.rx - old.0) / Double(CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 3) : 3) : 0
    let up = iface.tx >= old.1 ? Double(iface.tx - old.1) / Double(CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 3) : 3) : 0
    let active = down > 1 || up > 1 || iface.rx > 0 || iface.tx > 0
    if active {
        print(String(format: "%-10@ %14@ %14@ %14@ %14@",
                     iface.name as NSString,
                     bytes(Double(iface.rx)) as NSString,
                     bytes(Double(iface.tx)) as NSString,
                     (bytes(down) + "/s") as NSString,
                     (bytes(up) + "/s") as NSString))
    }
    if iface.name.hasPrefix("en") {
        sumDown += down; sumUp += up; sumRx += Double(iface.rx); sumTx += Double(iface.tx)
    }
}
print("---")
print("程序统计口径(en* 合计): 累计收 \(bytes(sumRx)) / 发 \(bytes(sumTx))   下行 \(bytes(sumDown))/s   上行 \(bytes(sumUp))/s")
