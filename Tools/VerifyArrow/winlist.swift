// 第三方观测工具：列出 SysPulse 在 WindowServer 里的所有窗口及其真实 frame。
// 坐标系：CGWindowList 的 bounds 原点是**左上角**（y 向下），单位是点。
import Cocoa

let args = CommandLine.arguments
let wantPid: pid_t? = args.count > 1 ? pid_t(args[1]) : nil

guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("无法读取窗口列表\n".data(using: .utf8)!)
    exit(1)
}

for w in list {
    guard let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
    if let want = wantPid, pid != want { continue }
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let name = w[kCGWindowName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    let wid = w[kCGWindowNumber as String] as? Int ?? -1
    let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
          let x = b["X"] as? Double, let y = b["Y"] as? Double,
          let width = b["Width"] as? Double, let height = b["Height"] as? Double else { continue }
    if width < 1 || height < 1 { continue }
    // 注意：数值必须紧贴等号（不能写成 `x= 1056.00`）。键值对之间夹空格的话，
    // 下游脚本按空白分词会把值拆成独立 token，解析不到——这个坑排查了很久。
    print(String(format: "pid=%d win=%d layer=%d alpha=%.2f x=%.2f y=%.2f w=%.2f h=%.2f cx=%.2f cy=%.2f owner=%@ name=%@",
                 pid, wid, layer, alpha, x, y, width, height, x + width / 2, y + height / 2, owner, name))
}
