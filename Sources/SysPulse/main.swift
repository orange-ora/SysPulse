import AppKit
import Foundation



// `--dump` 用于在没有图形界面的情况下验证采集是否正常。
if CommandLine.arguments.contains("--dump") {
    DumpMode.run()
    exit(0)
}

// 命令行开关开机自启，方便脚本化安装（面板里的「启动」菜单是同一套逻辑）。
if CommandLine.arguments.contains("--enable-login-item") || CommandLine.arguments.contains("--disable-login-item") {
    let enable = CommandLine.arguments.contains("--enable-login-item")
    let login = LaunchAtLogin.shared
    if let error = login.set(enable) {
        FileHandle.standardError.write(Data(("设置失败：" + error + "\n").utf8))
        exit(1)
    }
    print("开机自启已" + (login.isEnabled ? "开启" : "关闭"))
    exit(0)
}

if CommandLine.arguments.contains("--login-item-status") {
    print("开机自启：" + (LaunchAtLogin.shared.isEnabled ? "已开启" : "未开启"))
    exit(0)
}

// 单实例 + 优先使用「应用程序」里那份（见 SingleInstance.swift）
SingleInstance.enforce()

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
